import Foundation

func loadPackages(at path: String) throws -> [URL] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode([URL].self, from: data)
}

func savePackages(_ packages: [URL], to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    let data = try encoder.encode(packages)
    try data.write(to: URL(fileURLWithPath: path))   
}

func loadDenyList() throws -> [URL] {
    struct Item: Decodable { var packageUrl: URL }
    let data = try Data(contentsOf: URL(fileURLWithPath: "denyList.json"))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode([Item].self, from: data).map(\.packageUrl)
}

func main() throws {
    guard let body = ProcessInfo.processInfo.environment["GH_BODY"] else {
        print("Body (GH_BODY) not set")
        exit(1)
    }
    
    var packages = try loadPackages(at: "packages.json")
    
    for line in body.split(whereSeparator: \.isWhitespace) {
        guard let url = URL(string: String(line)) else { continue }
        
        guard url.host?.lowercased() == "github.com" else {
            print("Invalid url:", url)
            print("Only packages hosted on github.com are currently supported.")
            exit(1)
        }
        
        if !packages.contains(url) {
            packages.append(url)
            print("+ \(url)")
        }
    }
    
    let denyList = Set(try loadDenyList().map { $0.absoluteString.lowercased() })
    let filtered = packages
        .filter { !denyList.contains($0.absoluteString.lowercased()) }
        .sorted { $0.absoluteString.lowercased() < $1.absoluteString.lowercased() }
    try savePackages(filtered, to: "packages.json")
}

try main()
