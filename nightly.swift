#!/usr/bin/env swift

import Foundation

print("INFO: Running...")

let fileManager = FileManager.default
let decoder = JSONDecoder()

/// When run via GitHub Actions, requests to GitHub can happen so quickly that we hit a hidden rate limit. As such we introduce a throttle so if the requests happen
/// too quickly then we take a break. (Time in seconds)
let requestThrottleDelay: TimeInterval = 1

let timeoutIntervalForRequest = 3000.0
let timeoutIntervalForResource = 6000.0
let httpMaximumConnectionsPerHost = 10
let processTimeout = 50.0

let rawGitHubBaseURL = URLComponents(string: "https://raw.githubusercontent.com")!

// We have a special Personal Access Token (PAT) which is used to increase our rate limit allowance up to 5,000 to enable
// us to process every package.
let patToken = ProcessInfo.processInfo.environment["GH_API_TOKEN_BASE64"]?.trimmingCharacters(in: .whitespacesAndNewlines)

print(patToken?.count ?? -1)

if patToken == nil {
    print("Warning: Using anonymous authentication -- you will quickly run into rate limiting issues\n")
}

let config: URLSessionConfiguration = .default
config.timeoutIntervalForRequest = timeoutIntervalForRequest
config.timeoutIntervalForResource = timeoutIntervalForResource
config.httpMaximumConnectionsPerHost = httpMaximumConnectionsPerHost

let session = URLSession(configuration: config)

enum SourceHost: String {
    case GitHub = "github.com"
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
    case rateLimitExceeded(Int)
    case packageDoesNotExist(String)
    case dumpTimedOut
    case unknownError(Error)
    case repoIsFork
    case outdatedToolsVersion
    
    var localizedDescription: String {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .timedOut:
            return "Request Timed Out"
        case .noData:
            return "No Data Received"
        case .dumpTimedOut:
            return "Dump Timed Out"
        case .networkingError(let error), .decoderError(let error), .fileSystemError(let error), .unknownError(let error):
            return error.localizedDescription
        case .unknownGitHost(let host):
            return "Unknown URL host: \(host ?? "nil")"
        case .badPackageDump(let output):
            return "Bad Package Dump -- \(output ?? "No Output")"
        case .missingProducts:
            return "Missing Products"
        case .rateLimitExceeded(let limit):
            return "Rate Limit of \(limit) Exceeded"
        case .packageDoesNotExist(let url):
            return "Package Does Not Exist: \(url)"
        case .repoIsFork:
            // A decision has been made that the index as a whole should support forks, but not as part of dependency analysis.
            //
            // This is because there's an unhealthy amount of forks with a single patch to simply make the dependency work with their library,
            // thse are often unmaintained and don't delivery huge amounts of value.
            return "Forks are not added as part of dependency analysis"
        case .outdatedToolsVersion:
            return "Repo is using an outdated package format"
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
    
    var request = URLRequest(url: apiURL)
    
    if let token = patToken, apiURL.host?.contains(SourceHost.GitHub.rawValue) == true {
        request.addValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }
    
    let task = session.dataTask(with: request) { (data, response, error) in
        
        let httpResponse = response as? HTTPURLResponse
        
        if let limit = httpResponse?.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init),
           let remaining = httpResponse?.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
           remaining == 0 {
            taskError = .rateLimitExceeded(limit)
        } else if httpResponse?.statusCode == 404 {
            taskError = .packageDoesNotExist(apiURL.absoluteString)
        } else if let error = error {
            taskError = .networkingError(error)
        }
        
        if let dataUnwrapped = data, httpResponse?.statusCode != 200 {
            print(String(data: dataUnwrapped, encoding: .utf8) ?? "No Data")
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

class RedirectFollower: NSObject, URLSessionDataDelegate {
    
    var lastURL: URL?
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lastURL = request.url ?? lastURL
        completionHandler(request)
    }
    
}

enum RedirectResult {
    case unchanged
    case notFound
    case rateLimitHit
    case unknownError(Error)
    case redirected(URL)
}

extension URL {
    
    func normalised() -> URL {
        URL(string: removingGitExtension().absoluteString.lowercased())!
    }
    
    func removingGitExtension() -> URL {
        if absoluteString.hasSuffix(".git") {
            let lastPath = lastPathComponent.components(separatedBy: ".").dropLast().joined(separator: ".")
            return self.deletingLastPathComponent().appendingPathComponent(lastPath)
        }
        
        return self
    }
    
    func followingRedirects() -> RedirectResult {
        let semaphore = DispatchSemaphore(value: 0)
        
        let follower = RedirectFollower()
        let session = URLSession(configuration: .default, delegate: follower, delegateQueue: nil)
        var result: RedirectResult?
        
        let task = session.dataTask(with: self) { (data, response, error) in
            
            if let error = error {
                result = .unknownError(error)
            }
            
            if let lastURL = follower.lastURL, self.removingGitExtension().absoluteString != lastURL.absoluteString {
                result = .redirected(lastURL)
            }
            
            let httpResponse = response as? HTTPURLResponse
            
            if let statusCode = httpResponse?.statusCode {
                switch statusCode {
                case 404:
                    result = .notFound
                    
                case 429:
                    result = .rateLimitHit
                    
                case 200:
                    break
                    
                default:
                    // We got a status code which was neither 200 nor 404. We won't do anything with this for now, but
                    // we'll print it to make it easier to debug and find any patterns.
                    print("INFO: \(self.absoluteString) - Received a \(statusCode) status code")
                }
            }
            
            semaphore.signal()
        }
        
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        
        return result ?? .unchanged
    }
    
}

extension Array where Element == URL {
    
    func removingDuplicatesAndSort() -> [URL] {
        var normalisedList = Set<URL>()
        return compactMap { url in
            
            let normalisedURL = url.normalised()
            if normalisedList.contains(normalisedURL) {
                return nil
            }
            
            normalisedList.insert(normalisedURL)
            return url
        }.sorted(by: {
            $0.absoluteString.lowercased() < $1.absoluteString.lowercased()
        })
    }
    
    mutating func replace(_ url: Element, with new: Element) -> Bool {
        guard let index = firstIndex(of: url) else {
            return false
        }
        
        self[index] = new
        return true
    }
    
    mutating func remove(_ url: Element) -> Bool {
        guard let index = firstIndex(of: url) else {
            return false
        }
        
        self.remove(at: index)
        return true
    }
    
    func containsSameElements(as other: [Element]) -> Bool {
        return self.count == other.count &&
               self.map(\.absoluteString).sorted() == other.map(\.absoluteString).sorted()
    }
    
}

// https://developer.github.com/v3/repos/#get-a-repository
struct Repository: Decodable {
    let default_branch: String
    let stargazers_count: Int
    let html_url: URL
    let fork: Bool
}

struct Product: Decodable {
    let name: String
}

struct Dependency: Decodable, Hashable {
    let name: String
    let url: URL
}

struct Package: Decodable {
    let name: String
    let products: [Product]
    let dependencies: [Dependency]
}

struct SwiftPackage: Decodable {
    let package: Package
    let repo: Repository
}

class PackageFetcher {
    
    let repoOwner: String
    let repoName: String
    
    init(repoURL: URL) throws {
        let components = repoURL.removingGitExtension().path.components(separatedBy: "/")
        
        guard components.count == 3 else {
            throw ValidatorError.invalidURL(repoURL.path)
        }
        
        repoOwner = components[1]
        repoName = components[2]
    }
    
    func fetch() -> Result<SwiftPackage, ValidatorError> {
        do {
            let repo = try fetchRepository().get()
            let packageURL = try getPackageSwiftURL(repository: repo).get()
            let packageLocalURL = try downloadPackageSwift(url: packageURL).get()
            let packageData = try dumpPackage(atURL: packageLocalURL).get()
            let package = try JSONDecoder().decode(Package.self, from: packageData)
            
            return .success(SwiftPackage(package: package, repo: repo))
        } catch let error as ValidatorError {
            return .failure(error)
        } catch {
            return .failure(.unknownError(error))
        }
    }
    
    private func fetchRepository() -> Result<Repository, ValidatorError> {
        downloadJSONSync(url: "https://api.github.com/repos/\(repoOwner)/\(repoName)")
    }
    
    private func getPackageSwiftURL(repository: Repository) -> Result<URL, ValidatorError> {
        var rawURLComponents = rawGitHubBaseURL
        rawURLComponents.path = ["", repoOwner, repoName, repository.default_branch, "Package.swift"].joined(separator: "/")
        
        guard let packageURL = rawURLComponents.url else {
            return .failure(.invalidURL(rawURLComponents.path))
        }
        
        return .success(packageURL)
    }
    
    private func downloadPackageSwift(url: URL) -> Result<URL, ValidatorError> {
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
    
    private func dumpPackageProcessAt(_ packageDirectoryURL: URL, outputTo pipe: Pipe, errorsTo errorPipe: Pipe) -> Process {
        let process = Process()
        process.launchPath = "/usr/bin/swift"
        process.arguments = ["package", "dump-package"]
        process.currentDirectoryURL = packageDirectoryURL
        process.standardOutput = pipe
        process.standardError = errorPipe
        return process
    }

    private func dumpPackage(atURL url: URL) -> Result<Data, ValidatorError> {
        let semaphore = DispatchSemaphore(value: 0)
        let pipe = Pipe()
        let errorPipe = Pipe()
        let process = dumpPackageProcessAt(url, outputTo: pipe, errorsTo: errorPipe)
        var result: Result<Data, ValidatorError>?
        
        process.terminationHandler = { process in
            
            guard process.terminationStatus == 0 else {
                if process.terminationStatus == 15 {
                    result = .failure(.dumpTimedOut)
                } else {
                    let errorDump = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    
                    if errorDump?.contains("using Swift tools version 3.1.0 which is no longer supported") == true {
                        result = .failure(.outdatedToolsVersion)
                    } else {
                        result = .failure(.badPackageDump(errorDump))
                    }
                }
                
                semaphore.signal()
                return
            }
            
            result = .success(pipe.fileHandleForReading.readDataToEndOfFile())
            semaphore.signal()
        }
        
        process.launch()
        
        _ = semaphore.wait(timeout: .now() + processTimeout)
        
        if process.isRunning {
            process.terminate()
        }
        
        return result ?? .failure(.timedOut)
    }
    
}

// MARK: - Running Code

// Get the current directory
let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)

// Get the packages.json
let packagesURL = currentDirectory.appendingPathComponent("packages.json")
let originalPackageData = try Data(contentsOf: packagesURL)
let originalPackages = try decoder.decode([URL].self, from: originalPackageData)
print("Found \(originalPackages.count) packages")

// Remove Duplicates
var filteredPackages = originalPackages.removingDuplicatesAndSort()

if filteredPackages.count != originalPackages.count {
    print("CHANGE: Packages JSON already contained duplicate URLs, these have been removed.")
}

// Follow Redirects and Remove 404s
//
// We will attempt to load the HTML URL (the URL minus the .git extension) and follow any redirects that occur.
// If we 404 (Not Found) then we remove the URL from the package list. If the URL we end up on is not the same as the
// one we have listed then we replace it with the new URL to keep our list as accurate as possible.
do {
    let tempStorage = filteredPackages
    var lastRequestDate = Date()
    tempStorage.forEach { url in
        
        let timeSinceLastRequest = abs(lastRequestDate.timeIntervalSinceNow)
        if timeSinceLastRequest < requestThrottleDelay {
            //usleep(1000000 * useconds_t(requestThrottleDelay - timeSinceLastRequest))
        }
        
        lastRequestDate = Date()
        var recursiveCount = 0
        
        func process(packageURL: URL) {
            let result = packageURL.followingRedirects()
            
            switch result {
            case .notFound:
                guard filteredPackages.remove(packageURL) else {
                    print("ERROR: Failed to remove \(packagesURL.path) (404)")
                    return
                }
                
                print("CHANGE: Removed \(packageURL.path) as it returned a 404")
                
            case .redirected(let newURL):
                let newURLWithSuffix = newURL.appendingPathExtension("git")
                
                guard filteredPackages.replace(packageURL, with: newURLWithSuffix) else {
                    print("ERROR: Failed to replace \(packageURL.path) with \(newURLWithSuffix.path)")
                    return
                }
                
                print("CHANGE: Replaced \(packageURL.path) with \(newURLWithSuffix.path)")
                
            case .rateLimitHit:
                recursiveCount += 1
                
                if recursiveCount <= 3 {
                    print("INFO: Retrying \(packageURL.path) due to rate limits, sleeping first.")
                    sleep(30)
                    process(packageURL: packageURL)
                } else {
                    print("INFO: Failed to process \(packageURL.path) due to rate limits.")
                    sleep(15)
                }
                
            case .unknownError(let error):
                print("ERROR: Unknown error for URL: \(packageURL.path) - \(error.localizedDescription)")
                
            case .unchanged:
                break
            }
        }
        
        //process(packageURL: url)
    }
}

// Dependency Analysis
//
// We will cycle through every package, validate that we can download and dump it's Package.swift and then extract a list
// of every dependency it has. We will then cycle through each of those dependencies and validate those.
//
// The goal of this step is to identify dependenices of known packages which are themselves unknown to our list increasing
// our coverage.

do {
    var allDependencies = Set<Dependency>()
    filteredPackages.forEach { url in
        do {
            let fetcher = try PackageFetcher(repoURL: url)
            let package = try fetcher.fetch().get()
            
            package.package.dependencies.forEach { allDependencies.insert($0) }
        } catch {
            print("ERROR: Failed to obtain package information for \(url.path)")
            print(error)
        }
    }
    
    let normalisedURLs = filteredPackages.map { $0.normalised() }
    let uniqueDependencies = allDependencies.filter { normalisedURLs.contains($0.url.normalised()) == false }
    print("INFO: Found \(allDependencies.count) dependencies from \(filteredPackages.count) packages. \(uniqueDependencies.count) are unique.")
    
    uniqueDependencies.forEach { dependency in
        do {
            let fetcher = try PackageFetcher(repoURL: dependency.url)
            let package = try fetcher.fetch().get()
            
            if package.package.products.isEmpty {
                throw ValidatorError.missingProducts
            }
            
            if package.repo.fork {
                throw ValidatorError.repoIsFork
            }
            
            // Passed validation, let's add it to the array of URLs
            filteredPackages.append(package.repo.html_url.appendingPathExtension("git"))
            print("CHANGE: Added \(package.repo.html_url.path)")
        } catch {
            print("ERROR: Dependency (\(dependency.url.path)) did not pass validation:")
            print(error)
        }
    }
}

// Remove Duplicates (Final)
//
// There's a possibility with the redirects being removed that we've now made some duplicates, let's remove them.
do {
    let tempStorage = filteredPackages
    filteredPackages = filteredPackages.removingDuplicatesAndSort()
    
    if tempStorage.count != filteredPackages.count {
        print("CHANGE: Removed \(tempStorage.count - filteredPackages.count) duplicate URLs")
    }
}

// Detect Changes
//
// We compare the newly updated list to the original packages list we downloaded. If they're the exact same then we can
// safely stop now.
if filteredPackages.containsSameElements(as: originalPackages) {
    print("No Changes Made")
    exit(EXIT_SUCCESS)
}

// Save Backup
//
// To mitigate against data-loss we store a backup of the packages.json before we override it with our changes.
let backupLocation = currentDirectory.appendingPathComponent("packages.backup.json")
try? originalPackageData.write(to: backupLocation)

// Save New Changes
do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [ .prettyPrinted ]
    let data = try encoder.encode(filteredPackages)
    let string = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
    let unescapedData = string.data(using: .utf8)!
    try unescapedData.write(to: packagesURL)
    print("INFO: packages.json has been updated")
}

exit(EXIT_SUCCESS)
