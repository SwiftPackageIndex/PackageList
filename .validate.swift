#!/usr/bin/env swift

import Foundation

let rawGitHubBaseURL = URLComponents(string: "https://raw.githubusercontent.com")!

let existingPackageListURL = rawGitHubBaseURL.url!.appendingPathComponent("SwiftPackageIndex/PackageList/main/packages.json")

let timeoutIntervalForRequest = 3000.0
let timeoutIntervalForResource = 6000.0
let httpMaximumConnectionsPerHost = 10

let config: URLSessionConfiguration = .default
config.timeoutIntervalForRequest = timeoutIntervalForRequest
config.timeoutIntervalForResource = timeoutIntervalForResource
config.httpMaximumConnectionsPerHost = httpMaximumConnectionsPerHost

let session = URLSession(configuration: config)

// MARK: - Definitions

enum SourceHost: String {
    case GitHub = "github.com"
}

struct Repository: Decodable {
    let default_branch: String
}

struct Product: Decodable {
    let name: String
}

struct Package: Decodable {
    let name: String
    let products: [Product]
}

// MARK: - Error

enum ValidatorError: Error {
    case invalidURL(String)
    case timedOut
    case noData
    case networkingError(Error)
    case decoderError(Error)
    case unknownGitHost(String?)
    case fileSystemError(Error)
    case badPackageDump(String?)
    case missingProducts
    
    var localizedDescription: String {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .timedOut:
            return "Request Timed Out"
        case .noData:
            return "No Data Received"
        case .networkingError(let error), .decoderError(let error), .fileSystemError(let error):
            return error.localizedDescription
        case .unknownGitHost(let host):
            return "Unknown URL host: \(host ?? "nil")"
        case .badPackageDump(let output):
            return "Bad Package Dump -- \(output ?? "No Output")"
        case .missingProducts:
            return "Missing Products"
        }
    }
}

// MARK: - Networking

func downloadSync(url: String, timeout: Int = 10) -> Result<Data, ValidatorError> {
    let semaphore = DispatchSemaphore(value: 0)
    
    guard let apiURL = URL(string: url) else {
        return .failure(.invalidURL(url))
    }
    
    var payload: Data?
    var taskError: ValidatorError?
    
    let task = session.dataTask(with: apiURL) { (data, _, error) in
        
        if let error = error {
            taskError = .networkingError(error)
        }
        
        payload = data
        semaphore.signal()
        
    }
    
    task.resume()
    
    switch semaphore.wait(timeout: .now() + .seconds(timeout)) {
    case .timedOut:
        return .failure(.timedOut)
    case .success where payload == nil:
        return .failure(taskError ?? .noData)
    case .success:
        return .success(payload!)
    }
}

func downloadJSONSync<Payload: Decodable>(url: String, timeout: Int = 10) -> Result<Payload, ValidatorError> {
    let decoder = JSONDecoder()
    let result = downloadSync(url: url, timeout: timeout)
    
    switch result {
    case .failure(let error):
        return .failure(error)
        
    case .success(let data):
        do {
            return .success(try decoder.decode(Payload.self, from: data))
        } catch {
            return .failure(.decoderError(error))
        }
    }
}

// MARK: - Verification

func getDefaultBranch(userName: String, repositoryName: String) -> Result<String, ValidatorError> {
    let result: Result<Repository, ValidatorError> = downloadJSONSync(url: "https://api.github.com/repos/\(userName)/\(repositoryName)")
    return result.map(\.default_branch)
}

func getPackageSwiftURL(url: URL) -> Result<URL, ValidatorError> {
    
    guard let host = url.host.flatMap(SourceHost.init(rawValue:)) else {
        return .failure(.unknownGitHost(url.host))
    }
    
    switch host {
    case .GitHub:
        let repositoryName = url.deletingPathExtension().lastPathComponent
        let userName = url.deletingLastPathComponent().lastPathComponent
        let defaultBranch = (try? getDefaultBranch(userName: userName, repositoryName: repositoryName).get()) ?? "master"
        var rawURLComponents = rawGitHubBaseURL
        rawURLComponents.path = ["", userName, repositoryName, defaultBranch, "Package.swift"].joined(separator: "/")
        
        guard let packageURL = rawURLComponents.url else {
            return .failure(.invalidURL(url.absoluteString))
        }
        
        return .success(packageURL)
    }
    
}

func downloadPackage(url: URL) -> Result<URL, ValidatorError> {
    
    switch downloadSync(url: url.absoluteString) {
    case .failure(let error):
        return .failure(error)
        
    case .success(let packageData):
        
        let fileManager = FileManager.default
        let outputDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        do {
            try fileManager.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: false, attributes: nil)
            try packageData.write(to: outputDirectoryURL.appendingPathComponent("Package.swift"), options: .atomic)
            return .success(outputDirectoryURL)
        } catch {
            return .failure(.fileSystemError(error))
        }
    }
}

func dumpPackageProcessAt(_ packageDirectoryURL: URL, outputTo pipe: Pipe, errorsTo errorPipe: Pipe) -> Process {
    let process = Process()
    process.launchPath = "/usr/bin/swift"
    process.arguments = ["package", "dump-package"]
    process.currentDirectoryURL = packageDirectoryURL
    process.standardOutput = pipe
    process.standardError = errorPipe
    return process
}

func dumpPackage(atURL url: URL, completion: @escaping (Result<Data, ValidatorError>) -> Void) {
    let pipe = Pipe()
    let errorPipe = Pipe()
    let process = dumpPackageProcessAt(url, outputTo: pipe, errorsTo: errorPipe)
    
    process.terminationHandler = { process in
        
        guard process.terminationStatus == 0 else {
            let errorDump = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            completion(.failure(.badPackageDump(errorDump)))
            return
        }
        
        completion(.success(pipe.fileHandleForReading.readDataToEndOfFile()))
    }
    
    process.launch()
}

func verifyPackage(url: URL, completion: @escaping (Error?) -> Void) {
    do {
        let packageURL = try getPackageSwiftURL(url: url).get()
        let localPackageURL = try downloadPackage(url: packageURL).get()
        
        dumpPackage(atURL: localPackageURL) { result in
            switch result {
            case .failure(let error):
                completion(error)
            case .success(let data):
                let decoder = JSONDecoder()
                
                do {
                    let package = try decoder.decode(Package.self, from: data)
                    
                    guard package.products.isEmpty == false else {
                        completion(ValidatorError.missingProducts)
                        return
                    }
                    
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
    } catch {
        completion(error)
    }
}

// MARK: - Helpers

extension Array where Element == URL {
    
    func findDuplicates(of url: URL) -> Array<(offset: Int, element: URL)> {
        let normalise: (URL) -> String = { url in
            var normalisedString = url.absoluteString.lowercased()
                
            if normalisedString.hasSuffix(".git") {
                normalisedString = normalisedString.components(separatedBy: ".").dropLast().joined(separator: ".")
            }
            
            return normalisedString
        }
        
        let normalisedSubject = normalise(url)
        
        return enumerated().filter { tuple in
            normalise(tuple.element) == normalisedSubject
        }
    }
    
}

// MARK: - Running Code

func url(packagesFromDirectories directoryURLs: [URL], andArguments arguments: [String]) -> URL? {
    let possiblePackageURLs = arguments.dropFirst().compactMap { URL(fileURLWithPath: $0) } + directoryURLs.map { $0.appendingPathComponent("packages.json") }
    return possiblePackageURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) })
}

let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let packagesJsonURL = url(packagesFromDirectories: [currentDirectoryURL, URL(fileURLWithPath: #file).deletingLastPathComponent()], andArguments: CommandLine.arguments)!

// 1. Download existing package list
var existingPackageList: [URL] = {
    do {
        return try downloadJSONSync(url: existingPackageListURL.absoluteString).get()
    } catch {
        print("[Error] Failed to download existing package list from GitHub")
        print(error)
        exit(EXIT_FAILURE)
    }
}()

// 2. Load local package list
var backupLocalPackageList: Data?
var localPackageList: [URL] = {
    do {
        let decoder = JSONDecoder()
        let data = try Data(contentsOf: packagesJsonURL)
        backupLocalPackageList = data
        return try decoder.decode([URL].self, from: data)
    } catch {
        print("[Error] Failed to load local package list")
        print(error)
        exit(EXIT_FAILURE)
    }
}()

// 3. Calculate Differences
let difference = localPackageList.difference(from: existingPackageList)
var newURLsToValidate = [URL]()

difference.forEach { change in
    switch change {
    case .insert(_, let url, _):
        print("+ \(url)")
        newURLsToValidate.append(url)
    case .remove(_, let url, _):
        print("- \(url)")
    }
}

// 4. Validate URLs
var errorsFound = Set<String>()
newURLsToValidate.forEach { url in

    // URL must not be duplicated
    let duplicates = localPackageList.findDuplicates(of: url)
    
    if duplicates.count > 1 {
        duplicates.map(\.offset).reversed().dropLast().forEach { offset in
            localPackageList.remove(at: offset)
        }
        
        errorsFound.insert("The packages.json file contained duplicate rows")
    }
    
    // URL must end in .git
    if url.pathExtension != "git" {
        if let offset = localPackageList.firstIndex(of: url) {
            localPackageList[offset] = url.appendingPathExtension("git")
            
            errorsFound.insert("One or more packages URLs were missing .git extensions")
        }
    }

}

// 5. Validate order of JSON
let localPackageListSorted = localPackageList.sorted {
    $0.absoluteString.lowercased() < $1.absoluteString.lowercased()
}

let unsortedUrls = zip(localPackageList, localPackageListSorted).enumerated().filter { $0.element.0 != $0.element.1 }.map {
    ($0.offset, $0.element.0)
}

if unsortedUrls.isEmpty == false {
    errorsFound.insert("The packages.json file was incorrectly sorted")
}

// 6. Report any problems
// We've automatically fixed them so no need to stop the script - but users should be aware that we've overriden the file

if errorsFound.isEmpty == false {
    
    // Write the backup package list to disk to prevent users from losing data
    let backupURL = packagesJsonURL.deletingLastPathComponent().appendingPathComponent("packages.backup.json")
    try! backupLocalPackageList?.write(to: backupURL)
    
    // Write the new local package list to disk
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    
    let data = try! encoder.encode(localPackageListSorted)
    let str = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
    let unescapedData = str.data(using: .utf8)!
    try! unescapedData.write(to: packagesJsonURL)
    
    let errorMessage = errorsFound.map { "* \($0)" }.joined(separator: "\n")
    
    print("""

    *******************************************************************************
    ** IMPORTANT ******************************************************************

    During validation, problem(s) were found:

    \(errorMessage)

    These problems have been automatically fixed, but you'll need to commit the
    changes that this script has made before creating the pull request.

    Thanks!

    *******************************************************************************
    """)
}

// 7. Validate Package

let group = DispatchGroup()
let concurrentQueue = DispatchQueue(label: "swiftpm-verification", qos: .utility, attributes: .concurrent)
var count = 0
var packageResults = [URL: Error]()

newURLsToValidate.enumerated().forEach { (offset, url) in
    group.enter()

    concurrentQueue.async {
        verifyPackage(url: url) { error in
            if let error = error {
                packageResults[url] = error
            }
            group.leave()
        }
    }
}

group.notify(queue: .main) {
    if packageResults.isEmpty {
        print("\n\(newURLsToValidate.count) package(s) passed")
        exit(EXIT_SUCCESS)
    }
    
    packageResults.forEach { url, error in
        if let error = error as? ValidatorError {
            print("🚨 \(url.absoluteString): \(error.localizedDescription)")
        } else {
            print("🚨 \(url.absoluteString): \(error)")
        }
    }
    
    print("\n\(packageResults.count) package(s) failed")
    
    exit(EXIT_FAILURE)
}

RunLoop.main.run()
