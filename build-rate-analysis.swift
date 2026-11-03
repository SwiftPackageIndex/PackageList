#!/usr/bin/swift sh

import Foundation
import ShellOut   // @JohnSundell

let packageList = "packages.json"
let calendar = Calendar(identifier: .gregorian)
let fmt = DateFormatter()
fmt.dateFormat = "yyyy-MM-dd"
fmt.timeZone = .init(abbreviation: "UTC")

let oct25 = "2025-10-01"
let oct26 = "2026-10-01"

func fname(_ date: String) -> String { "packages-\(date).json" }

func copyLists() throws {
    for dateString in [oct25, oct26] {
        if FileManager.default.fileExists(atPath: fname(dateString)) { continue }
        
        try shellOut(to: "git checkout main")
        print("Updating to latest main...")
        try shellOut(to: "git pull")
        
        let date = fmt.date(from: dateString)!
        let rev = try shellOut(to: #"git rev-list -n 1 --before="\#(date)" main"#)
        guard !rev.isEmpty else {
            print("no rev for \(date)")
            continue
        }
        
        try shellOut(to: "git checkout \(rev)")
        print("Copying \(packageList) -> \(fname(dateString))...")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: packageList),
            to: URL(fileURLWithPath: fname(dateString))
        )
    }
}

extension String {
    static let gitSuffix = ".git"
    
    var droppingGitExtension: String {
        if lowercased().hasSuffix(String.gitSuffix) {
            return String(dropLast(String.gitSuffix.count))
        }
        return self
    }

    var directoryName: String? {
        guard let url = URL(string: self) else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        let trunk = url.path
            .replacingOccurrences(of: "/", with: "-")
            .lowercased()
            .droppingGitExtension
        guard !trunk.isEmpty else { return nil }
        return trunk.hasPrefix("-")
            ? host + trunk
            : host + "-" + trunk
    }
}

let checkoutDir = "checkouts"
if !FileManager.default.fileExists(atPath: checkoutDir) {
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: checkoutDir), withIntermediateDirectories: true)
}

func checkoutPackages(in list: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: fname(list)))
    let packages = try JSONDecoder().decode([String].self, from: data)
    print("Packages: ", packages.count)
    for (idx, p) in packages.enumerated() {
        guard let dirname = p.directoryName else {
            print("Invalid directory name for package \(p)")
            continue
        }
        let targetdir = "\(checkoutDir)/\(dirname)"
        if FileManager.default.fileExists(atPath: targetdir) {
            print("Skipping [\(idx)] \(targetdir), already exists...")
        } else {
            print("Cloning [\(idx)] \(p) into \(targetdir)...")
            do {
                try shellOut(to: "git clone \(p) \(targetdir)")
            } catch {
                print("Cloning failed: \(error)")
            }
        }
    }
}

func setupCheckouts(for list: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: fname(list)))
    let packages = try JSONDecoder().decode([String].self, from: data)
    print("Packages: ", packages.count)
    
    let listCheckoutDir = "checkouts-\(list)"
    if !FileManager.default.fileExists(atPath: listCheckoutDir) {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: listCheckoutDir), withIntermediateDirectories: true)
    }
    
    for (idx, p) in packages.enumerated() {
        guard let dirname = p.directoryName else {
            print("Invalid directory name for package \(p)")
            continue
        }
        let sourcedir = "../\(checkoutDir)/\(dirname)"
        let targetdir = "\(listCheckoutDir)/\(dirname)"
        if FileManager.default.fileExists(atPath: targetdir) {
            print("Skipping [\(idx)] \(targetdir), already exists...")
        } else {
            print("Linking [\(idx)] \(sourcedir) to \(targetdir)...")
            do {
                try shellOut(to: "ln -s \(sourcedir) \(dirname)", at: listCheckoutDir)
            } catch {
                print("Linking failed: \(error)")
            }
        }
    }
}


func printResults(for label: String, list: String, counts: [Int]) {
    let total = counts.reduce(0, +)
    print("\(label) sum     \(list):", total)
    print("\(label) average \(list):", Double(total) / Double(counts.count))
}


func reportCommitCount(for list: String, dates: (String, String)) throws {
    let listCheckoutDir = "checkouts-\(list)"
    let results = "commits-\(list).json"
    var counts = [String: Int]()
    if FileManager.default.fileExists(atPath: results) {
        let data = try Data(contentsOf: URL(fileURLWithPath: results))
        counts = try JSONDecoder().decode([String: Int].self, from: data)
    }
    for (idx, url) in try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: listCheckoutDir), includingPropertiesForKeys: nil).enumerated() {
        let dirname = url.lastPathComponent
        if counts[dirname] != nil { continue }
        let path = "\(listCheckoutDir)/\(dirname)"
        do {
            let count = Int(try shellOut(to: "git rev-list --count HEAD --since=\(dates.0) --before=\(dates.1)", at: path))
            if let count {
                print(idx, dirname, count)
                counts[dirname] = count
                if idx % 100 == 0 {
                    let data = try JSONEncoder().encode(counts)
                    try data.write(to: URL(fileURLWithPath: results))
                }
            }
        } catch { }
    }
    printResults(for: "Commits", list: list, counts: Array(counts.values))
}


func parseReleaseDate(for line: String) -> Date? {
    // refs/tags/release.985070 2026-08-12 15:53:26 +0200
    // refs/tags/5.0.2 2026-08-17 16:03:35 +0200
    let parts = line.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    return fmt.date(from: String(parts[1]))
}


func reportReleaseCount(for list: String, dates: (String, String)) throws {
    let listCheckoutDir = "checkouts-\(list)"
    let results = "releases-\(list).json"
    let startDate = fmt.date(from: dates.0)!
    let endDate = fmt.date(from: dates.1)!
    var counts = [String: Int]()
    if FileManager.default.fileExists(atPath: results) {
        let data = try Data(contentsOf: URL(fileURLWithPath: results))
        counts = try JSONDecoder().decode([String: Int].self, from: data)
    }
    for (idx, url) in try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: listCheckoutDir), includingPropertiesForKeys: nil).enumerated() {
        let dirname = url.lastPathComponent
        if counts[dirname] != nil { continue }
        let path = "\(listCheckoutDir)/\(dirname)"
        do {
            let releases = try shellOut(to: "git for-each-ref --sort=creatordate --format '%(refname) %(creatordate:iso-local)' refs/tags", at: path)
                .split(separator: "\n")
            let releaseDates = releases.map(String.init).compactMap(parseReleaseDate)
                .filter { startDate <= $0 && $0 < endDate }

            let count = releaseDates.count
            print(idx, dirname, count)
            counts[dirname] = count
            if idx % 100 == 0 {
                let data = try JSONEncoder().encode(counts)
                try data.write(to: URL(fileURLWithPath: results))
            }
        } catch { }
    }
    printResults(for: "Releases", list: list, counts: Array(counts.values))
}

// try copyLists()
// try checkoutPackages(in: oct25)
// try checkoutPackages(in: oct26)

// try setupCheckouts(for: oct25)
// try setupCheckouts(for: oct26)

try reportCommitCount(for: oct25, dates: ("2025-09-01", "2025-10-01"))
try reportCommitCount(for: oct26, dates: ("2026-09-01", "2026-10-01"))

try reportReleaseCount(for: oct25, dates: ("2025-09-01", "2025-10-01"))
try reportReleaseCount(for: oct26, dates: ("2026-09-01", "2026-10-01"))
