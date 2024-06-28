import Foundation

func loadPackages(at path: String) throws -> [URL] {
    let data = try Data(contentsOf: URL(filePath: path))
    return try JSONDecoder().decode([URL].self, from: data)
}

func savePackages(_ packages: [URL], to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .prettyPrinted]
    let data = try encoder.encode(packages)
    try data.write(to: URL(filePath: path))   
}

func loadDenyList() throws -> [URL] {
    struct Item: Decodable { var packageUrl: URL }
    let data = try Data(contentsOf: URL(filePath: "denyList.json"))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode([Item].self, from: data).map(\.packageUrl)
}

func main() throws {
    guard let body = ProcessInfo.processInfo.environment["GH_BODY"] else {
        print("No body")
        exit(1)
    }
    
    var packages = try loadPackages(at: "packages.json")
    
    for line in body.split(whereSeparator: \.isWhitespace) {
        let line = String(line)
        guard let url = URL(string: line) else {
            print("Invalid url:", line)
            exit(1)
        }
        if !packages.contains(url) {
            packages.append(url)
            print("+ \(url).")
        }
    }
    
    let denyList = Set(try loadDenyList().map { $0.absoluteString.lowercased() })
    let result = packages
        .filter { !denyList.contains($0.absoluteString.lowercased()) }
        .sorted { $0.absoluteString.lowercased() < $1.absoluteString.lowercased() }
    try savePackages(result, to: "packages.json")
}

try main()
