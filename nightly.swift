#!/usr/bin/env swift

import Foundation

let fileManager = FileManager.default
let decoder = JSONDecoder()

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

extension URL {
    
    func removingGitExtension() -> URL {
        if absoluteString.hasSuffix(".git") {
            let lastPath = lastPathComponent.components(separatedBy: ".").dropLast().joined(separator: ".")
            return self.deletingLastPathComponent().appendingPathComponent(lastPath)
        }
        
        return self
    }
    
    func followingRedirects() -> URL? {
        let semaphore = DispatchSemaphore(value: 0)
        
        let follower = RedirectFollower()
        let session = URLSession(configuration: .default, delegate: follower, delegateQueue: nil)
        
        let task = session.dataTask(with: self) { (_, response, error) in
            semaphore.signal()
        }
        
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        
        if self.removingGitExtension().absoluteString == follower.lastURL?.absoluteString {
            return nil
        }
        
        return follower.lastURL
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

// Follow Redirects
do {
    print("Checking for redirects")
    
    let tempStorage = filteredPackages
    tempStorage.forEach { packageURL in
        guard let newURL = packageURL.followingRedirects()?.appendingPathExtension("git") else {
            // URL is no different, no further action needed
            return
        }
        
        guard filteredPackages.replace(packageURL, with: newURL) else {
            print("ERROR: Failed to replace \(packagesURL.path) with \(newURL.path)")
            return
        }
        
        print("CHANGE: Replaced \(packageURL.path) with \(newURL.path)")
    }
}

// Remove Duplicates (Final)
// There's a possibility with the redirects being removed that we've now made some duplicates, let's remove them.
do {
    let tempStorage = filteredPackages
    filteredPackages = filteredPackages.removingDuplicatesAndSort()
    
    if tempStorage.count != filteredPackages.count {
        print("CHANGE: Removed \(tempStorage.count - filteredPackages.count) duplicate URLs")
    }
}


// Detect Changes
if filteredPackages.containsSameElements(as: originalPackages) {
    print("No Changes Made")
    exit(EXIT_SUCCESS)
}

// Save Backup
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
