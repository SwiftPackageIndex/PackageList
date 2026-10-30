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

try copyLists()
// try checkoutPackages(in: oct25)
// try checkoutPackages(in: oct26)

try setupCheckouts(for: oct25)
try setupCheckouts(for: oct26)
