import Foundation

public struct Region: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var country: String
}

/// Reference lists bundled with TripCore (form drop-downs).
public enum Catalog {
    struct RegionFile: Decodable { let regions: [Region] }
    struct BikeFile: Decodable { let models: [String] }
    struct ColFile: Decodable { let cols: [ColInfo] }

    public static func regions() -> [Region] {
        (try? decode(RegionFile.self, "regions"))?.regions ?? []
    }

    public static func bikeModels() -> [String] {
        (try? decode(BikeFile.self, "bikes"))?.models ?? []
    }

    public static func cols() -> [ColInfo] {
        (try? decode(ColFile.self, "cols"))?.cols ?? []
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
