#!/usr/bin/env swift

import Foundation


// MARK: - Type declarations

enum AppError: Error {
    case syntaxError(String)

    var localizedDescription: String {
        switch self {
            case .syntaxError(let msg):
                return msg
        }
    }
}

enum RunMode {
    case processURL(URL)
    case processPackageList
}


// MARK: - Generic helpers


// MARK: - Redirect handling

class RedirectFollower: NSObject, URLSessionDataDelegate {
    var lastURL: URL?
    
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lastURL = request.url ?? lastURL
        completionHandler(request)
    }
}

extension URL {
    func followingRedirects(timeout: TimeInterval = 30) -> URL? {
        let semaphore = DispatchSemaphore(value: 0)
        
        let follower = RedirectFollower()
        let session = URLSession(configuration: .default, delegate: follower, delegateQueue: nil)
        
        let task = session.dataTask(with: self) { (_, response, error) in
            semaphore.signal()
        }
        
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        
        return follower.lastURL
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

func processURL(_ url: URL) {
    let resolvedURL = url.followingRedirects()
    print(resolvedURL!.absoluteString)
}

func processPackageList() {
    fatalError("not implemented")
}

func main(args: [String]) throws {
    switch try parseArgs(args) {
        case .processURL(let url):
            processURL(url)
        case .processPackageList:
            processPackageList()
    }
    exit(EXIT_SUCCESS)
}


// MARK: - Script specific extensions

extension String {
    func removingGitExtension() -> String {
        let suffix = ".git"
        if lowercased().hasSuffix(suffix) {
            return String(dropLast(suffix.count))
        }
        return self
    }
}

extension URL {
    func removingGitExtension() -> URL {
        guard absoluteString.hasSuffix(".git") else { return self }
        return URL(string: absoluteString.removingGitExtension())!
    }
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
