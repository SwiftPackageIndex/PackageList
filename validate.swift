#!/usr/bin/env swift

// Copyright 2018-2021 Dave Verwer, Sven A. Schmidt, and other contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
    case manifestNotFound(URL)
    case networkingError(Error)
    case notFound(URL)
    case outputIdentical
    case packageDumpError(String)
    case packageDumpTimeout
    case packageListChanged
    case packageMoved
    case rateLimitExceeded(URL, reportedLimit: Int)
    case syntaxError(String)

    var localizedDescription: String {
        switch self {
            case .invalidURL(let url):
                return "invalid url: \(url)"
            case .manifestNotFound(let url):
                return "no package manifest found at url: \(url)"
            case .networkingError(let error):
                return "networking error: \(error.localizedDescription)"
            case .notFound(let url):
                return "url not found (404): \(url)"
            case .outputIdentical:
                return "resulting package.json is unchanged. This typically means the package is already in the index."
            case .packageDumpError(let msg):
                return "package dump failed: \(msg)"
            case .packageDumpTimeout:
                return "timeout while running `swift package dump-package`"
            case .packageListChanged:
                return "package list was modified"
            case .packageMoved:
                return "package moved"
            case let .rateLimitExceeded(url, limit):
                return "rate limit of \(limit) exceeded while requesting url: \(url)"
            case .syntaxError(let msg):
                return msg
        }
    }
}

enum RunMode {
    case processURL(URL)
    case processPackageList
}

struct Package: Decodable {
    let name: String
}

// MARK: - Shell helpers

// Via Tim Condon

@discardableResult
func shell(_ args: String..., at path: URL, returnStdOut: Bool = false, returnStdErr: Bool = false, stdIn: Pipe? = nil) throws -> (status: Int32, stdout: Pipe, stderr: Pipe) {
    return try shell(args, at: path, returnStdOut: returnStdOut, returnStdErr: returnStdErr, stdIn: stdIn)
}

@discardableResult
func shell(_ args: [String], at path: URL, returnStdOut: Bool = false, returnStdErr: Bool = false, stdIn: Pipe? = nil) throws -> (status: Int32, stdout: Pipe, stderr: Pipe) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = args
    task.currentDirectoryURL = path
    let stdout = Pipe()
    let stderr = Pipe()
    if returnStdOut {
        task.standardOutput = stdout
    }
    if returnStdErr {
        task.standardError = stderr
    }
    if let stdIn = stdIn {
        task.standardInput = stdIn
    }
    try task.run()
    task.waitUntilExit()
    return (status: task.terminationStatus, stdout: stdout, stderr: stderr)
}

extension Pipe {
    func string() -> String? {
        let data = self.fileHandleForReading.readDataToEndOfFile()
        let result: String?
        if let string = String(data: data, encoding: String.Encoding.utf8) {
            result = string
        } else {
            result = nil
        }
        return result
    }
}

// Other helpers

extension Sequence {
    func mapAsync<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results = [T]()
        for element in self {
            try await results.append(transform(element))
        }
        return results
    }
}

// Ideally we'd be using Mutex from the Synchronization framework but it's causing
// JIT session error: Symbols not found: [ __tlsdesc_resolver, __aarch64_cas4_rel, __aarch64_cas4_acq ]
// errors on arm64 Linux (6.0.3-jammy).
@dynamicMemberLookup
public final class QueueIsolated<Value: Sendable>: @unchecked Sendable {
    private let _queue = DispatchQueue(label: "queue-isolated")

    private var _value: Value

    public init(_ value: Value) {
        self._value = value
    }

    public var value: Value {
        get { _queue.sync { self._value } }
    }

    public subscript<Subject>(dynamicMember keyPath: KeyPath<Value, Subject>) -> Subject {
        _queue.sync { self._value[keyPath: keyPath] }
    }

    public func withValue<T>(_ operation: (inout Value) throws -> T) rethrows -> T {
        try _queue.sync {
            var value = self._value
            defer { self._value = value }
            return try operation(&value)
        }
    }

    public func setValue(_ newValue: Value) {
        _queue.async { self._value = newValue }
    }
}

// MARK: - Redirect handling

final class RedirectFollower: NSObject, URLSessionDataDelegate {
    let lastURL: QueueIsolated<URL?> = .init(nil)
    init(initialURL: URL) {
        self.lastURL.setValue(initialURL)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url {
            lastURL.setValue(url)
        }
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

        return follower.lastURL.value
    }
}

// MARK: - Networking

func fetch(_ url: URL, timeout: TimeInterval = 10) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: timeout)

    if let token = Constants.githubToken {
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let session = URLSession(configuration: .default)
    
    do {
        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
    
        if let limit = httpResponse?.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init),
        let remaining = httpResponse?.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
        remaining == 0 {
            throw AppError.rateLimitExceeded(url, reportedLimit: limit)
        } else if httpResponse?.statusCode == 404 {
            throw AppError.notFound(url)
        }
        return data
    } catch {
        throw AppError.networkingError(error)
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

    func rtrim(_ characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
        String(
            reversed()
                .drop(while: { char in
                    CharacterSet(charactersIn: String(char)).isSubset(of: characterSet)
                })
                .reversed()
        )
    }

    func normalized() -> String {
        lowercased()
            .rtrim(.init(charactersIn: "/"))
            .addingGitExtension()
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
        absoluteString
            .lowercased()
            .rtrim(.init(charactersIn: "/"))
            .addingGitExtension()
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

func getDefaultBranch(owner: String, repository: String) async throws -> String {
    let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)")!
    let json = try await fetch(url)

    struct Repository: Decodable {
        let default_branch: String
    }

    return try JSONDecoder().decode(Repository.self, from: json).default_branch
}

struct RepoFile: Codable {
    var type: String
    var path: String
}

func parseOwnerRepo(from url: URL) -> (owner: String, repository: String) {
    let repository = (url.pathExtension.lowercased() == "git")
        ? url.deletingPathExtension().lastPathComponent
        : url.lastPathComponent
    let owner = url.deletingLastPathComponent().lastPathComponent
    return (owner, repository)
}

func listFilesInRepo(owner: String, repository: String, branch: String) async throws -> [RepoFile] {
    let apiURL = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/git/trees/\(branch)")!
    let json = try await fetch(apiURL)
    struct Response: Codable {
        var tree: [RepoFile]
    }
    do {
        return try JSONDecoder().decode(Response.self, from: json).tree
    } catch {
        print("failed to parse listFilesInRepo response:")
        print(String(decoding: json, as: UTF8.self))
        throw error
    }
}

func getManifestURLs(_ url: URL) async throws -> [URL] {
    let (owner, repository) = parseOwnerRepo(from: url)
    let branch = try await getDefaultBranch(owner: owner, repository: repository)
    let manifestFiles = try await listFilesInRepo(owner: owner, repository: repository, branch: branch)
      .filter { $0.type == "blob" }
      .filter { $0.path.hasPrefix("Package") }
      .filter { $0.path.hasSuffix(".swift") }
      .map(\.path)
      .sorted()
    guard !manifestFiles.isEmpty else { throw AppError.manifestNotFound(url) }
    return manifestFiles.map {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(branch)/\($0)")!
    }
}

func createTempDir() throws -> URL {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: false, attributes: nil)
    return tempDir
}

func runDumpPackage(at path: URL, timeout: TimeInterval = 20) throws -> Data {
    let (status, stdout, stderr) = try shell("swift", "package", "dump-package",
                                             at: path, returnStdOut: true, returnStdErr: true)

    switch status {
        case 0:
            return stdout.string().map { Data($0.utf8) } ?? Data()
        case 15:
            throw AppError.packageDumpTimeout
        default:
            let error = stderr.string() ?? "(nil)"
            throw AppError.packageDumpError(error)
    }
}

@discardableResult
func dumpPackage(url: URL) async throws -> Package {
    let tempDir = try createTempDir()
    
    for manifestURL in try await getManifestURLs(url) {
        let manifest = try await fetch(manifestURL)
        let fileURL = tempDir.appendingPathComponent(manifestURL.lastPathComponent)
        try manifest.write(to: fileURL)
    }

    let json = try runDumpPackage(at: tempDir)
    return try JSONDecoder().decode(Package.self, from: json)
}

func verifyURL(_ url: URL) async throws -> URL {
    print("verifying", url)
    guard let resolvedURL = url.followingRedirects() else { throw AppError.invalidURL(url) }
    try await dumpPackage(url: resolvedURL)
    return resolvedURL
}

func fetchGithubPackageList() async throws -> [URL] {
    let json = try await fetch(Constants.githubPackageListURL)
    return try JSONDecoder().decode([URL].self, from: json)
}

func processPackageList() async throws {
    print("Processing package list ...")
    let onlinePackageList = try await fetchGithubPackageList()
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

    let additions = try await localPackageList // use localPackageList to preserve original casing
        .filter { !normalizedOnlineList.contains($0.normalized()) }
        .mapAsync { try await verifyURL($0).appendingGitExtension() }
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

    do {
        let original = String(decoding: packageListData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let new = String(decoding: newListData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if original != new {
            if newList == onlinePackageList.map(\.absoluteString) {
                throw AppError.outputIdentical
            } else {
                print("⚠️  Changes have been made to 'packages.json'. Your original version has been")
                print("⚠️  copied to 'package.backup.json'. Please commit the updated file.")
                let backupURL = packageListFileURL.deletingLastPathComponent()
                    .appendingPathComponent("packages.backup.json")
                try packageListData.write(to: backupURL)
                try newListData.write(to: packageListFileURL)
                throw AppError.packageListChanged
            }
        }
    }
}

func main(args: [String]) async throws {
    if Constants.githubToken == nil {
        print("Warning: Using anonymous authentication -- may run into rate limiting issues\n")
    }

    switch try parseArgs(args) {
        case .processURL(let url):
            let resolvedURL = try await verifyURL(url)
            if resolvedURL.absoluteString != url.absoluteString {
                print("ℹ️  package moved: \(url) -> \(resolvedURL)")
                throw AppError.packageMoved
            }
        case .processPackageList:
            try await processPackageList()
    }
    print("✅ validation succeeded")
    exit(EXIT_SUCCESS)
}

// MARK: - main

do {
    try await main(args: CommandLine.arguments)
} catch {
    if let appError = error as? AppError {
        print("ERROR: \(appError.localizedDescription)")

        if ProcessInfo.processInfo.environment["CI"] == "true" {
            print("::set-output name=validateError::\(appError.localizedDescription)")

            if case .packageListChanged = appError {
                // For CI it's acceptable for the package list to change as we'll simply take the output of this script
                exit(EXIT_SUCCESS)
            }
        }
    } else {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            print("::set-output name=validateError::\(error)")
        }

        print("ERROR: \(error)")
    }
    exit(EXIT_FAILURE)
}
