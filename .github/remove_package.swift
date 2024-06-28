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
    let data = try Data(contentsOf: URL(fileURLWithPath: "denyList.json"))
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
        guard var url = URL(string: String(line)) else {
            print("Invalid url:", line)
            exit(1)
        }
        
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            print("Failed to parse URL components")
            exit(1)
        }
        
        if components.host?.lowercased() == "swiftpackageindex.com" {
            components.host = "github.com"
            url = components.url!
        }
        
        if !components.path.hasSuffix(".git") {
            components.path = components.path + ".git"
            url = components.url!
        } 

        urlsToDelete.append(url)
        print("- \(url)")
    }
    
    do {  // Remove urlsToDelete from packages.json
        let packages = try loadPackages(at: "packages.json")
        let denyList = Set(urlsToDelete.map { $0.absoluteString.lowercased() })
        let filtered = packages
            .filter { !denyList.contains($0.absoluteString.lowercased()) }
            .sorted { $0.absoluteString.lowercased() < $1.absoluteString.lowercased() }
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
    }
}

try main()
