import Foundation
import TripCore

/// What choosing a trip's dates needs, downloaded without the PC and kept in the cache for next time:
/// the seasonal closures and passes (GitHub data pack) and the weather of the past years (Open-Meteo archive).
enum SeasonData {
    private static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// The latest pack, else the stored one when GitHub cannot be reached.
    static func pack() async throws -> SeasonPack {
        let file = cache.appendingPathComponent("seasons-pack.json")
        let stored = try? JSONDecoder().decode(SeasonPack.self, from: Data(contentsOf: file))
        do {
            let manifest = try await DataPack.manifest()
            if let stored, stored.version == manifest.seasons.version { return stored }
            let data = try await DataPack.download(manifest.seasons)
            let pack = try JSONDecoder().decode(SeasonPack.self, from: data)
            try? data.write(to: file, options: .atomic)
            return pack
        } catch {
            if let stored { return stored }
            throw error
        }
    }

    /// The last years' daily weather at `spot`: cached six months, else one request (the free service limits the
    /// calls per minute: on « too many requests » it waits and asks again). nil when unavailable.
    static func climate(at spot: GeoPoint, today: CalendarDay) async -> Climate? {
        let dir = cache.appendingPathComponent("climate", isDirectory: true)
        let file = dir.appendingPathComponent(Climate.cacheName(spot))
        if let date = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date,
           Date().timeIntervalSince(date) < 180 * 86_400,
           let data = try? Data(contentsOf: file), let days = try? Climate.parseArchive(data), !days.isEmpty {
            return Climate(days)
        }
        guard let url = Climate.archiveRequest(spot, today: today) else { return nil }
        for attempt in 0..<3 {
            guard let answer = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 60)) else { return nil }
            let (data, response) = answer
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                guard let days = try? Climate.parseArchive(data), !days.isEmpty else { return nil }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                return Climate(days)
            case 429:
                try? await Task.sleep(for: .seconds(20 * (attempt + 1)))
            default:
                return nil
            }
        }
        return nil
    }
}
