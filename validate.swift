#!/usr/bin/env swift

import Foundation

// MARK: Configuration Values and Constants

// number of validations to run simultaneously
let semaphoreCount = 3

let timeoutIntervalForRequest = 3000.0
let timeoutIntervalForResource = 6000.0

// base url for github raw files
let rawURLComponentsBase = URLComponents(string: "https://raw.githubusercontent.com")!

// master package list to compare against
let masterPackageList = rawURLComponentsBase.url!.appendingPathComponent("daveverwer/SwiftPMLibrary/master/packages.json")

let logEveryCount = 10

let httpMaximumConnectionsPerHost = 10

let displayProgress = true

let processTimeout = 50.0

let helpText = """
usage: %@ <command> [path]

COMMANDS:
  all   validate all packages in JSON packages.json
  diff  validate all new packages in JSON packages.json
  mine  validate the Package of the current directoy

OPTIONS:
  path  to define the specific `packages.json` file or Swift package directory
"""
// MARK: Types


enum Command : String {
  case all
  case diff
  case mine
}

extension Command {
  static func fromArguments (_ arguments : [String]) -> Command? {
    for argument in arguments {
      if let command = Command(rawValue: argument) {
        return command
      }
    }
    return nil
  }
}

/**
 Simple Product structure from package dump
 */
struct Product: Codable {
  let name: String
}

/**
 Simple Package structure from package dump
 */
struct Package: Codable {
  let name: String
  let products: [Product]
}

/**
 List of git hosts for which we can pull single files
 */
enum GitHost: String {
  case GitHub = "github.com"
}

/**
 List of possible errors for each package
 */
enum PackageError: Error {
  case noResult
  case invalidURL(URL)
  case unsupportedHost(String)
  case readError(Error?)
  case badDump(String?)
  case decodingError(Error)
  case missingProducts
  case dumpTimeout


  var friendlyName : String {
    switch self {
    case .noResult:
      return "No Result"
    case .invalidURL(_):
      return "Invalid URL"
    case .unsupportedHost(_):
      return "Unsupported Host"
    case .readError(_):
      return "Download Failure"
    case .badDump(_):
      return "Invalid Dump"
    case .decodingError(_):
      return "Dump Decoding Error"
    case .missingProducts:
      return "No Products"
    case .dumpTimeout:
      return "Dump Timeout"
    }
  }
}

extension Result where Success == Void {
  init(_ error: Failure?) {
    if let error = error {
      self = .failure(error)
    } else {
      self = .success(Void())
    }
  }
}

// MARK: Functions

/**
 Based on repository url, find the raw url to the Package.swift file.
 - Parameter gitURL: Repository URL
 - Returns: raw git URL, if successful; other `invalidURL` if not proper git repo url or `unsupportedHost` if the host is not currently supported.
 */
func getPackageSwiftURL(for gitURL: URL) -> Result<URL, PackageError> {
  guard let hostString = gitURL.host else {
    return .failure(.invalidURL(gitURL))
  }

  guard let host = GitHost(rawValue: hostString) else {
    return .failure(.unsupportedHost(hostString))
  }

  switch host {
  case .GitHub:
    var rawURLComponents = rawURLComponentsBase
    let repositoryName = gitURL.deletingPathExtension().lastPathComponent
    let userName = gitURL.deletingLastPathComponent().lastPathComponent
    rawURLComponents.path = ["", userName, repositoryName, "master", "Package.swift"].joined(separator: "/")
    guard let packageSwiftURL = rawURLComponents.url else {
      return .failure(.invalidURL(gitURL))
    }
    return .success(packageSwiftURL)
  }
}

/**
 Downloads the given Package.swift file
 - Parameter packageSwiftURL: URL to Package.Swift
 - Parameter session: URLSession
 - Parameter callback: Completion callback. If successful, the resulting location of the downloaded Package.swift file; error otherwise.
 */
func download(_ packageSwiftURL: URL, withSession session: URLSession, _ callback: @escaping ((Result<URL, PackageError>) -> Void)) -> URLSessionDataTask {
  let task = session.dataTask(with: packageSwiftURL) { data, _, error in

    guard let data = data else {
      callback(.failure(.readError(error)))
      return
    }

    let outputDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    try! FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: false, attributes: nil)

    do {
      try data.write(to: outputDirURL.appendingPathComponent("Package.swift"), options: .atomic)
    } catch {
      callback(.failure(.readError(error)))
      return
    }
    callback(.success(outputDirURL))
  }
  task.resume()
  return task
}

/**
 Creates a `Process` for dump the package metadata.
 - Parameter packageDirectoryURL: File URL to Package
 - Parameter outputTo: standard output pipe
 - Parameter errorsTo: error pipe
 */
func dumpPackageProcessAt(_ packageDirectoryURL: URL, outputTo pipe: Pipe, errorsTo errorPipe: Pipe) -> Process {
  let process = Process()
  process.launchPath = "/usr/bin/swift"
  process.arguments = ["package", "dump-package"]
  process.currentDirectoryURL = packageDirectoryURL
  process.standardOutput = pipe
  process.standardError = errorPipe
  return process
}

/**
 Calls `swift package dump-package` and verify correct output with at least one product.
 - Parameter directoryURL: File URL to Package
 */
func verifyPackageDump(at directoryURL: URL, _ callback: @escaping ((PackageError?) -> Void)) {
  let pipe = Pipe()
  let errorPipe = Pipe()
  let process = dumpPackageProcessAt(directoryURL, outputTo: pipe, errorsTo: errorPipe)

  process.terminationHandler = {
    process in

    let package: Package

    guard process.terminationStatus == 0 else {
      let error : PackageError
      if process.terminationStatus == 15 {
        error = .dumpTimeout
      } else {
        error = .badDump(String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
      }
      callback(error)
      return
    }

    do {
      package = try decoder.decode(Package.self, from: pipe.fileHandleForReading.readDataToEndOfFile())
    } catch {
      callback(.decodingError(error))
      return
    }

    guard package.products.count > 0 else {
      callback(.missingProducts)
      return
    }
    callback(nil)
  }

  process.launch()


  DispatchQueue.main.asyncAfter(deadline: .now() + processTimeout) {
    if process.isRunning {
      process.terminate()
    }
  }
}

/**
 Verifies Swift package at repository URL.
 - Parameter gitURL: URL to git repository
 */
func verifyPackage(at gitURL: URL, withSession session: URLSession, _ callback: @escaping ((PackageError?) -> Void)) {
  let processSemaphore = DispatchSemaphore(value: semaphoreCount)
  let urlResult = getPackageSwiftURL(for: gitURL)
  let packageSwiftURL: URL
  switch urlResult {
  case let .success(url): packageSwiftURL = url
  case let .failure(error):
    callback(error)
    return
  }
  _ = download(packageSwiftURL, withSession: session) { result in
    let outputDirURL: URL

    switch result {
    case let .failure(error):
      callback(error)
      return
    case let .success(url):
      outputDirURL = url
    }
    processSemaphore.wait()
    verifyPackageDump(at: outputDirURL) {
      error in
      processSemaphore.signal()
      callback(error)
      return
    }
  }
}

/**
 Filters repositories based what is not listen in the master list.
 - Parameter packageUrls: current package urls
 - Parameter includingMaster: to not filter all repository url and just verify all package URLs
 */
func filterRepos(_ packageUrls: [URL], withSession session: URLSession, includingMaster: Bool, _ completion: @escaping ((Result<[URL], Error>) -> Void)) {
  guard !includingMaster else {
    completion(.success(packageUrls))
    return
  }

  session.dataTask(with: masterPackageList) { data, _, error in

    let allPackageURLs: [URL]
    guard let data = data else {
      completion(.failure(PackageError.noResult))
      return
    }

    if let error = error {
      completion(.failure(error))
      return
    }

    do {
      allPackageURLs = try decoder.decode([URL].self, from: data)
    } catch {
      completion(.failure(error))
      return
    }
    completion(.success([URL](Set<URL>(packageUrls).subtracting(allPackageURLs))))
  }.resume()
}

/**
 Iterate over all repositories in the packageUrls list .
 - Parameter packageUrls: current package urls
 - Parameter completion: Callback with a dictionary of each url with an error.
 */
func parseRepos(_ packageUrls: [URL], withSession session: URLSession, _ completion: @escaping (([URL: PackageError]) -> Void)) {
  let group = DispatchGroup()
  let logEachRepo = packageUrls.count < 8
  let concurrentQueue = DispatchQueue(label: "swiftpm-verification", qos: .utility, attributes: .concurrent)
  var count = 0
  var packageUnsetResults = [Result<Void, PackageError>?].init(repeating: nil, count: packageUrls.count)
  for (index, gitURL) in packageUrls.enumerated() {
    group.enter()
    concurrentQueue.async {
      if logEachRepo {
        print("Checking", [String](gitURL.pathComponents.suffix(2)).joined(separator:"/"), "...")
      }
      verifyPackage(at: gitURL, withSession: session) {
        error in
        packageUnsetResults[index] = Result<Void, PackageError>(error)

        if displayProgress && logEveryCount < packageUnsetResults.count {
          DispatchQueue.main.async {
            count += 1
            if count % (packageUnsetResults.count / logEveryCount) == 0 {
              print(".", terminator: "")
            }
          }
        } else if error == nil {
          print(gitURL, "passed")
        }
        group.leave()
      }
    }
  }

  group.notify(queue: .main) {
    var errors = [URL: PackageError]()
    zip(packageUrls, packageUnsetResults).forEach { args in
      let (url, unSetResult) = args
      let result = unSetResult ?? .failure(.noResult)
      guard case let .failure(error) = result else {
        return
      }
      errors[url] = error
    }

    completion(errors)
  }
}

/**
 Based on the directories passed and command line arguments, find the `packages.json` url.
 - Parameter directoryURLs: directory url to search for `packages.json` file
 - Parameter arguments: Command Line arguments which may contain a path to a `packages.json` file.
 */
func url(packagesFromDirectories directoryURLs: [URL], andArguments arguments: [String]) -> URL? {
  let possiblePackageURLs = arguments.dropFirst().compactMap { URL(fileURLWithPath: $0) } + directoryURLs.map { $0.appendingPathComponent("packages.json") }
  return possiblePackageURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) })
}

// MARK: Running Code

let decoder = JSONDecoder()

let config: URLSessionConfiguration = .default
config.timeoutIntervalForRequest = timeoutIntervalForRequest
config.timeoutIntervalForResource = timeoutIntervalForResource
config.httpMaximumConnectionsPerHost = httpMaximumConnectionsPerHost

let session = URLSession(configuration: config)

let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

// Find the "packages.json" file based on arguments, current directory, or the directory of the script
let packagesJsonURL = url(packagesFromDirectories: [currentDirectoryURL, URL(fileURLWithPath: #file).deletingLastPathComponent()], andArguments: CommandLine.arguments)

// parse the command argument subcommand
let commandArg = Command.fromArguments(CommandLine.arguments)

guard let command = commandArg else {
  print(String(format: helpText, CommandLine.arguments.first?.components(separatedBy: "/").last ?? "validate.sh"))
  exit(0)
}

if command == .mine {
  print("Validating Single Package.")
  let directoryURL = CommandLine.arguments.dropFirst().first.flatMap { URL(fileURLWithPath: $0, isDirectory: true) } ?? currentDirectoryURL
  verifyPackageDump(at: directoryURL) { error in
    if let error = error {
      print(error)
      exit(1)
    }
    print("Validation Succeeded.")
    exit(0)
  }
} else {
  // Based on arguments find the `package.json` file
  guard let url = packagesJsonURL else {
    print("Error: Unable to find packages.json to validate.")
    exit(1)
  }

  let data = try! Data(contentsOf: url)
  let packageUrls = try! decoder.decode([URL].self, from: data)

  // Make sure all urls contain the .git extension
  print("Checking all urls are valid.")
  let invalidUrls = packageUrls.filter { $0.pathExtension != "git" }

  guard invalidUrls.count == 0 else {
    print("Invalid URLs missing .git extension: \(invalidUrls)")
    exit(1)
  }

  // Make sure there are no dupes (no dupe variants w/ .git and w/o, no case differences)
  print("Checking for duplicate packages.")
  let urlCounts = Dictionary(grouping: packageUrls.enumerated()) {
    URL(string: $0.element.absoluteString.lowercased())!
  }.mapValues { $0.map { $0.offset } }.filter { $0.value.count > 1 }

  guard urlCounts.count == 0 else {
    print("Error: Duplicate URLs:\n\(urlCounts)")
    exit(1)
  }

  // Sort the array of urls
  print("Checking packages are sorted.")
  let sortedUrls = packageUrls.sorted {
    $0.absoluteString.lowercased() < $1.absoluteString.lowercased()
  }

  // Verify that there are no differences between the current JSON and the sorted JSON
  let unsortedUrls = zip(packageUrls, sortedUrls).enumerated().filter { $0.element.0 != $0.element.1 }.map {
    ($0.offset, $0.element.0)
  }

  guard unsortedUrls.count == 0 else {
    // If the sorting fails, save the sorted packages.json file
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let data = try! encoder.encode(sortedUrls)
    let str = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
    let unescapedData = str.data(using: .utf8)!
    let outputURL = url.deletingPathExtension().appendingPathExtension("sorted.json")
    try! unescapedData.write(to: outputURL)
    print("Error: Packages.json is not sorted correctly. Run this validation locally and replace packages.json with packages.sorted.json.")
    exit(1)
  }

  print("Checking each url for valid package dump.")

  filterRepos(packageUrls, withSession: session, includingMaster: command == .all) { result in
    let packageUrls: [URL]
    switch result {
    case let .failure(error):
      debugPrint(error)
      exit(1)
    case let .success(urls):
      packageUrls = urls
    }
    print("Checking \(packageUrls.count) Packages...")
    parseRepos(packageUrls, withSession: session) { errors in
      for (url, error) in errors {
        print(url, error)
      }
      if errors.count == 0 {
        print("Validation Succeeded.")
        exit(0)
      } else {
        print("Validation Failed")
        let errorReport = [String : [PackageError]].init(grouping: errors.values, by: { $0.friendlyName }).mapValues{ $0.count }
        for report in errorReport {
          print(report.value, report.key, separator: "\t")
        }
        print()
        print("\(errors.count) Packages Failed")
        exit(1)
      }

    }
  }

}

RunLoop.main.run()
