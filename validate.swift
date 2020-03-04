#!/usr/bin/env swift

import Combine
import Foundation

struct Product: Codable {
  let name: String
}

struct Package: Codable {
  let name: String
  let products: [Product]
}

enum GitHost: String {
  case GitHub = "github.com"
}

enum PackageError: Error {
  case invalidURL(URL)
  case unsupportedHost(String)
  case readError(Error?)
  case badDump(String?)
  case decodingError(Error)
  case missingProducts
}

// Find the "packages.json" file based on arguments, current directory, or the directory of the script
let argumentURL = CommandLine.arguments.dropFirst().first.flatMap(URL.init(fileURLWithPath:))
let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("packages.json")
let scriptDirectoryURL = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("packages.json")

let possibleURLs: [URL?] = [argumentURL, currentDirectoryURL, scriptDirectoryURL]

guard let url = possibleURLs.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
  print("Error: Unable to find packages.json to validate.")
  exit(1)
}

let decoder = JSONDecoder()
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
  print("Error: packages.json is not sorted: \(unsortedUrls)")
  // If the sorting fails, save the sorted packages.json file
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted]

  let data = try! encoder.encode(sortedUrls)
  let str = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
  let unescapedData = str.data(using: .utf8)!
  let outputURL = url.deletingPathExtension().appendingPathExtension("sorted.json")
  try! unescapedData.write(to: outputURL)
  print("Sorted packages.json has been saved to:\n \(outputURL.path)")
  exit(1)
}

let processSemaphore = DispatchSemaphore(value: 12)
let urlComponents = URLComponents(string: "https://raw.githubusercontent.com")!

let group = DispatchGroup()

let concurrentQueue = DispatchQueue(label: "swiftpm-verification", qos: .utility, attributes: .concurrent)

let config: URLSessionConfiguration = .default
config.timeoutIntervalForRequest = 30.0
config.timeoutIntervalForRequest = 60.0
let session = URLSession(configuration: config)
var packageUnsetResults = [Result<Void, PackageError>?].init(repeating: nil, count: packageUrls.count)
let total = packageUnsetResults.count
var previousCount = 0
let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { timer in
  let count = packageUnsetResults.compactMap { $0 }.count
  guard count < total else {
    timer.invalidate()
    return
  }
  print("\(total - count) remaining")
  if previousCount == count, total - count < 10 {
    let urlsRemaining = packageUnsetResults.enumerated().compactMap {
      $0.element == nil ? $0.offset : nil
    }.map {
      packageUrls[$0]
    }
    debugPrint(urlsRemaining)
    for _ in urlsRemaining {
      group.leave()
    }
  }
  previousCount = count
}

timer.tolerance = 5.0

func getPackageSwiftURL(for gitURL: URL) -> Result<URL, PackageError> {
  guard let hostString = gitURL.host else {
    return .failure(.invalidURL(gitURL))
  }

  guard let host = GitHost(rawValue: hostString) else {
    return .failure(.unsupportedHost(hostString))
  }

  switch host {
  case .GitHub:
    var rawURLComponents = urlComponents
    let repositoryName = gitURL.deletingPathExtension().lastPathComponent
    let userName = gitURL.deletingLastPathComponent().lastPathComponent
    rawURLComponents.path = ["", userName, repositoryName, "master", "Package.swift"].joined(separator: "/")
    guard let packageSwiftURL = rawURLComponents.url else {
      return .failure(.invalidURL(gitURL))
    }
    return .success(packageSwiftURL)
  }
}

func download(_ packageSwiftURL: URL, _ callback: @escaping ((Result<URL, PackageError>) -> Void)) -> URLSessionDataTask {
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

func verifyPackageDump(at outputDirURL: URL, _ callback: @escaping ((PackageError?) -> Void)) {
  let pipe = Pipe()
  let errorPipe = Pipe()
  let process = Process()
  process.launchPath = "/usr/bin/swift"
  process.arguments = ["package", "dump-package"]
  process.currentDirectoryURL = outputDirURL
  process.standardOutput = pipe
  process.standardError = errorPipe

  process.terminationHandler = {
    process in
    let package: Package

    guard process.terminationStatus == 0 else {
      callback(.badDump(String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)))
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
}

func verifyPackage(at gitURL: URL, _ callback: @escaping ((PackageError?) -> Void)) {
  let urlResult = getPackageSwiftURL(for: gitURL)
  let packageSwiftURL: URL
  switch urlResult {
  case let .success(url): packageSwiftURL = url
  case let .failure(error):
    callback(error)
    return
  }
  _ = download(packageSwiftURL) { result in
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

extension Result where Success == Void {
  init(_ error: Failure?) {
    if let error = error {
      self = .failure(error)
    } else {
      self = .success(Void())
    }
  }
}

print("Checking each url for valid package dump.")
for (index, gitURL) in packageUrls.enumerated() {
  group.enter()
  concurrentQueue.async {
    verifyPackage(at: gitURL) {
      error in
      packageUnsetResults[index] = Result<Void, PackageError>(error)
      group.leave()
    }
  }
}

group.notify(queue: .main) {
  timer.invalidate()
  let packageResults = packageUnsetResults.compactMap { $0 }
  assert(packageResults.count == packageUrls.count)
  let errors = zip(packageUrls, packageResults).compactMap { (args) -> (URL, PackageError)? in
    let (url, result) = args
    guard case let .failure(error) = result else {
      return nil
    }
    return (url, error)
  }
  for (url, error) in errors {
    print(url, error)
  }
  print("Validation Succeeded.")
  exit(0)
}

RunLoop.current.add(timer, forMode: .default)
RunLoop.current.run()
