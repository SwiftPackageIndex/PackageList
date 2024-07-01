import Foundation

func loadPackages(at path: String) throws -> [URL] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode([URL].self, from: data)
}

func savePackages(_ packages: [URL], to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .prettyPrinted]
    let data = try encoder.encode(packages)
    try data.write(to: URL(fileURLWithPath: path))   
}

struct PackageToDelete: Codable {
    var notes: String
    var packageUrl: URL
}

func loadDenyList() throws -> [PackageToDelete] {
    let data = try Data(contentsOf: URL(fileURLWithPath: "denylist.json"))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode([PackageToDelete].self, from: data)
}

func saveDenyList(_ packages: [PackageToDelete], to path: String) throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(packages)
    try data.write(to: URL(fileURLWithPath: path))   
}

extension URL {
    var normalized: Self? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        if components.scheme == "http" { components.scheme = "https" }
        if !components.path.hasSuffix(".git") { components.path = components.path + ".git" }
        if components.host?.lowercased() == "swiftpackageindex.com" { components.host = "github.com" }
        return components.url!
    }
}

func main() throws {
    guard let issueNumber = ProcessInfo.processInfo.environment["GH_ISSUE"] else {
        print("Issue number (GH_ISSUE) not set")
        exit(1)
    }
    guard let body = ProcessInfo.processInfo.environment["GH_BODY"] else {
        print("Body (GH_BODY) not set")
        exit(1)
    }
    
    var urlsToDelete = [URL]()
    
    for line in body.split(whereSeparator: \.isWhitespace) {
        guard let url = URL(string: String(line)),
              let scheme = url.scheme,
              scheme.starts(with: "http") else {
            continue
        }
        
        guard let normalizedUrl = url.normalized else {
            print("Failed to normalize URL")
            exit(1)
        }

        urlsToDelete.append(normalizedUrl)
        print("- \(normalizedUrl)")
    }
    
    do {  // Remove urlsToDelete from packages.json
        let packages = try loadPackages(at: "packages.json")
        let denyList = Set(urlsToDelete.map { $0.absoluteString.lowercased() })
        let filtered = packages
            .filter { !denyList.contains($0.absoluteString.lowercased()) }
            .sorted { $0.absoluteString.lowercased() < $1.absoluteString.lowercased() }
        if filtered.count != packages.count - urlsToDelete.count {
            print("Not all URLs requested to delete were found in packages.json.")
            exit(1)
        }
        try savePackages(filtered, to: "packages.json")
    }
    
    do {  // Add urlsToDelete to denyList.json
        let originalDenyList = try loadDenyList()
        let denyListUrls = Set(try loadDenyList().map { $0.packageUrl.absoluteString.lowercased() })
        // Only add urls that are new
        let urlsToAdd = urlsToDelete
            .filter { !denyListUrls.contains($0.absoluteString.lowercased()) }
            .sorted { $0.absoluteString.lowercased() < $1.absoluteString.lowercased() }
        let newItems = urlsToAdd.map {
            PackageToDelete(notes: "Requested in https://github.com/SwiftPackageIndex/PackageList/issues/\(issueNumber).",
                            packageUrl: $0)
        }
        try saveDenyList(originalDenyList + newItems, to: "denylist.json")
        for url in urlsToAdd {
            print("+ \(url) (denyList.json)")
        }
    }
}

try main()
