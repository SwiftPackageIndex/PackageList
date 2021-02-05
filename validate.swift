#!/usr/bin/env swift

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Constants

enum Constants {
    static let githubPackageListURL = URL(string: "https://raw.githubusercontent.com/SwiftPackageIndex/PackageList/main/packages.json")!
    static let githubToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
}

// MARK: - Type declarations

enum AppError: Error {
    case invalidURL(URL)
    case fetchTimeout(URL)
    case networkingError(Error)
    case noData(URL)
    case noProducts(URL)
    case notFound(URL)
    case packageDumpError(String)
    case packageDumpTimeout
    case packageListChanged
    case packageMoved
    case rateLimitExceeded(URL, reportedLimit: Int)
    case syntaxError(String)

    var localizedDescription: String {
        switch self {
            case .invalidURL(let url):
                return "invalid url: \(url.absoluteString)"
            case .fetchTimeout(let url):
                return "timeout while fetching url: \(url.absoluteString)"
            case .networkingError(let error):
                return "networking error: \(error.localizedDescription)"
            case .noData(let url):
                return "no data returned from url: \(url.absoluteString)"
            case .noProducts(let url):
                return "package has not products: \(url.absoluteString)"
            case .notFound(let url):
                return "url not found (404): \(url.absoluteString)"
            case .packageDumpError(let msg):
                return "package dump failed: \(msg)"
            case .packageDumpTimeout:
                return "timeout while running `swift package dump-package`"
            case .packageListChanged:
                return "package list was modified"
            case .packageMoved:
                return "package moved"
            case let .rateLimitExceeded(url, limit):
                return "rate limit of \(limit) exceeded while requesting url: \(url.absoluteString)"
            case .syntaxError(let msg):
                return msg
        }
    }
}

enum RunMode {
    case processURL(URL)
    case processPackageList
}

struct Product: Decodable {
    let name: String
}

struct Package: Decodable {
    let name: String
    let products: [Product]
}

// MARK: - Generic helpers

extension Pipe {
    convenience init(readabilityHandler: ((FileHandle) -> Void)?) {
        self.init()
        self.fileHandleForReading.readabilityHandler = readabilityHandler
    }
}

// MARK: - Redirect handling

class RedirectFollower: NSObject, URLSessionDataDelegate {
    var lastURL: URL?
    init(initialURL: URL) {
        self.lastURL = initialURL
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lastURL = request.url ?? lastURL
        // FIXME: port 404 and 429 handling from PackageList/Validator
        completionHandler(request)
    }
}

extension URL {
    func followingRedirects(timeout: TimeInterval = 30) -> URL? {
        let semaphore = DispatchSemaphore(value: 0)
        
        let follower = RedirectFollower(initialURL: self)
        let session = URLSession(configuration: .default, delegate: follower, delegateQueue: nil)
        
        let task = session.dataTask(with: self) { (_, response, error) in
            semaphore.signal()
        }
        
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        
        return follower.lastURL
    }
}

// MARK: - Networking

func fetch(_ url: URL, timeout: Int = 10) throws -> Data {
    var request = URLRequest(url: url)
    
    if let token = Constants.githubToken {
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    
    let semaphore = DispatchSemaphore(value: 0)
    
    var payload: Data?
    var taskError: AppError?
    
    let session = URLSession(configuration: .default)
    let task = session.dataTask(with: request) { (data, response, error) in
        let httpResponse = response as? HTTPURLResponse
        
        if let limit = httpResponse?.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init),
           let remaining = httpResponse?.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
           remaining == 0 {
            taskError = .rateLimitExceeded(url, reportedLimit: limit)
        } else if httpResponse?.statusCode == 404 {
            taskError = .notFound(url)
        } else if let error = error {
            taskError = .networkingError(error)
        }
        
        payload = data
        semaphore.signal()
    }
    
    task.resume()
    
    switch semaphore.wait(timeout: .now() + .seconds(timeout)) {
    case .timedOut:
        throw AppError.fetchTimeout(url)
    case .success where taskError != nil:
        throw taskError!
    case .success:
        guard let payload = payload else { throw AppError.noData(url) }
        return payload
    }
}

// MARK: - Script specific extensions

extension String {
    func addingGitExtension() -> String {
        hasSuffix(".git") ? self : self + ".git"
    }

    func removingGitExtension() -> String {
        let suffix = ".git"
        if lowercased().hasSuffix(suffix) {
            return String(dropLast(suffix.count))
        }
        return self
    }

    func normalized() -> String {
        lowercased().addingGitExtension()
    }
}

extension URL {
    func appendingGitExtension() -> URL {
        absoluteString.hasSuffix(".git") ? self : appendingPathExtension("git")
    }

    func removingGitExtension() -> URL {
        URL(string: absoluteString.removingGitExtension())!
    }

    func normalized() -> String {
        absoluteString.lowercased().addingGitExtension()
    }
}

extension Set where Element == URL {
    func normalized() -> Set<String> {
        Set<String>(map { $0.normalized() })
    }
}

extension Array where Element == URL {
    func normalized() -> Set<String> {
        Set<String>(map { $0.normalized() })
    }
}

extension Array where Element == String {
    func normalized() -> Set<String> {
        Set<String>(map { $0.normalized() })
    }
}

// MARK: - Script logic

func parseArgs(_ args: [String]) throws -> RunMode {
    guard args.count > 1 else { return .processPackageList }
    let urlString = args[1]
    guard
        urlString.starts(with: "https://"),
        let url = URL(string: urlString)
        else { throw AppError.syntaxError("not a valid url: \(urlString)") }
    return .processURL(url)
}

func getDefaultBranch(owner: String, repository: String) throws -> String {
    let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)")!
    let json = try fetch(url)

    struct Repository: Decodable {
        let default_branch: String
    }

    return try JSONDecoder().decode(Repository.self, from: json).default_branch
}

func getManifestURL(_ url: URL) throws -> URL {
    let repository = (url.pathExtension.lowercased() == "git")
        ? url.deletingPathExtension().lastPathComponent
        : url.lastPathComponent
    let owner = url.deletingLastPathComponent().lastPathComponent    
    let defaultBranch = try getDefaultBranch(owner: owner, repository: repository)
    return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(defaultBranch)/Package.swift")!
}

func createTempDir() throws -> URL {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: false, attributes: nil)
    return tempDir
}

func createDumpPackageProcess(at path: URL, standardOutput: Pipe, standardError: Pipe) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = ["package", "dump-package"]
    process.currentDirectoryURL = path
    process.standardOutput = standardOutput
    process.standardError = standardError
    return process
}

func runDumpPackage(at path: URL, timeout: TimeInterval = 20) throws -> Data {
    let queue = DispatchQueue(label: "process-pipe-read-queue")
    var stdout = Data()
    var stderr = Data()
    let stdoutPipe = Pipe { handler in
        queue.async { stdout.append(handler.availableData) }
    }
    let stderrPipe = Pipe { handler in
        queue.async { stderr.append(handler.availableData) }
    }

    let process = createDumpPackageProcess(at: path, standardOutput: stdoutPipe, standardError: stderrPipe)
    
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        if process.isRunning { process.terminate() }
    }
    try process.run()
    process.waitUntilExit()
    
    switch process.terminationStatus {
        case 0:
            return stdout
        case 15:
            throw AppError.packageDumpTimeout
        default:
            let error = String(data: stderr, encoding: .utf8) ?? "(nil)"
            throw AppError.packageDumpError(error)
    }
}

func dumpPackage(url: URL) throws -> Package {
    let manifestURL = try getManifestURL(url)
    let manifest = try fetch(manifestURL)
    
    let tempDir = try createTempDir()
    let fileURL = tempDir.appendingPathComponent("Package.swift")
    try manifest.write(to: fileURL)

    let json = try runDumpPackage(at: tempDir)
    return try JSONDecoder().decode(Package.self, from: json)
}

func verifyURL(_ url: URL) throws -> URL {
    guard let resolvedURL = url.followingRedirects() else { throw AppError.invalidURL(url) }
    let pkg = try dumpPackage(url: resolvedURL)
    guard !pkg.products.isEmpty else {
        throw AppError.noProducts(url)
    }
    return resolvedURL
}

func fetchGithubPackageList() throws -> [URL] {
    let json = try fetch(Constants.githubPackageListURL)
    return try JSONDecoder().decode([URL].self, from: json)
}

func processPackageList() throws {
    print("Processing package list ...")
    let onlinePackageList = try fetchGithubPackageList()
        .map { url -> URL in
            let updated = url.appendingGitExtension()
            if updated != url {
                print("→ \(url.lastPathComponent) -> \(updated.lastPathComponent)")
            }
            return updated
        }
    let packageListFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("packages.json")
    let packageListData = try Data(contentsOf: packageListFileURL)
    let localPackageList = try JSONDecoder().decode([URL].self, from: packageListData)

    let normalizedOnlineList = onlinePackageList.normalized()
    let normalizedLocalList = localPackageList.normalized()

    if localPackageList.count != normalizedLocalList.count {
        print("The packages.json file contained duplicate rows")
    }

    let additions = try localPackageList // use localPackageList to preserve original casing
        .filter { !normalizedOnlineList.contains($0.normalized()) }
        .map { try verifyURL($0).appendingGitExtension() }
        .filter {
            // filter again, in case a redirect happens to be in the list already
            !normalizedOnlineList.contains($0.normalized())
        }
        .map(\.absoluteString)

    let removals = onlinePackageList
        .filter { !normalizedLocalList.contains($0.normalized()) }
        .map(\.absoluteString)

    additions.forEach { print("+ \($0)") }
    removals.forEach { print("- \($0)") }

    let normalizedRemovals = removals.map { $0.normalized() }

    let newList = (
            onlinePackageList
                .map(\.absoluteString)
                .filter { !normalizedRemovals.contains($0.normalized()) }
                + additions
        )
        .sorted { $0.lowercased() < $1.lowercased() }
    let newListData: Data = try {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(newList)
    }()

    if packageListData != newListData {
        print("⚠️  Changes have been made to 'packages.json'. Your original version has been")
        print("⚠️  copied to 'package.backup.json'. Please commit the updated file.")
        let backupURL = packageListFileURL.deletingLastPathComponent()
            .appendingPathComponent("packages.backup.json")
        try packageListData.write(to: backupURL)
        try newListData.write(to: packageListFileURL)
        throw AppError.packageListChanged
    }
}

func main(args: [String]) throws {
    if Constants.githubToken == nil {
        print("Warning: Using anonymous authentication -- may run into rate limiting issues\n")
    }

    switch try parseArgs(args) {
        case .processURL(let url):
            let resolvedURL = try verifyURL(url)
            if resolvedURL.absoluteString != url.absoluteString {
                print("ℹ️  package moved: \(url) -> \(resolvedURL)")
                throw AppError.packageMoved
            }
        case .processPackageList:
            try processPackageList()
    }
    print("✅ validation succeeded")
    exit(EXIT_SUCCESS)
}

// MARK: - main

do {
    try main(args: CommandLine.arguments)
} catch {
    if let appError = error as? AppError {
        print("ERROR: \(appError.localizedDescription)")
    } else {
        print(error)
    }
    exit(EXIT_FAILURE)
}
RunLoop.main.run()
