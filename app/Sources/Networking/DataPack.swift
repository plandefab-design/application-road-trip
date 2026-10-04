import Foundation

/// Data published every day by GitHub for the iPhone (workflow data-pack.yml), downloaded without the PC:
/// the speed camera / hazard pack and the seasonal closures and passes. A small manifest gives each pack's version,
/// so a pack is downloaded only when it changed. Never used while riding.
enum DataPack {
    static let base = URL(string: "https://github.com/plandefab-design/application-road-trip/releases/download/data/")!

    struct Manifest: Decodable {
        struct Entry: Decodable {
            let file: String
            let version: String
        }
        let alerts: Entry
        let seasons: Entry
    }

    enum Failure: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .http(let code): "Données GitHub indisponibles (HTTP \(code))"
            }
        }
    }

    static func manifest() async throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: try await get("manifest.json", timeout: 15))
    }

    /// A pack's JSON (published as raw DEFLATE).
    static func download(_ entry: Manifest.Entry) async throws -> Data {
        let packed = try await get(entry.file, timeout: 60)
        return try (packed as NSData).decompressed(using: .zlib) as Data
    }

    private static func get(_ file: String, timeout: TimeInterval) async throws -> Data {
        // Release assets answer with a redirect to GitHub's storage, followed by URLSession.
        let request = URLRequest(url: base.appendingPathComponent(file), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.http(code) }
        return data
    }
}
