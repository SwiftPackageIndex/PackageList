#!/usr/bin/env swift

import Foundation

let fileManager = FileManager.default
let decoder = JSONDecoder()

/// When run via GitHub Actions, requests to GitHub can happen so quickly that we hit a hidden rate limit. As such we introduce a throttle so if the requests happen
/// too quickly then we take a break. (Time in seconds)
let requestThrottleDelay: TimeInterval = 0.5

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
    case unknownError(Error)
    case redirected(URL)
}

extension URL {
    
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
        Set(self).sorted(by: {
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
    var timeSinceLastRequest = Date()
    tempStorage.forEach { packageURL in
        
        if abs(timeSinceLastRequest.timeIntervalSinceNow) < requestThrottleDelay {
            usleep(1000000 * useconds_t(requestThrottleDelay))
        }
        
        timeSinceLastRequest = Date()
        
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
            
        case .unknownError(let error):
            print("ERROR: Unknown error for URL: \(packageURL.path) - \(error.localizedDescription)")
            
        case .unchanged:
            break
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
}

exit(EXIT_SUCCESS)
