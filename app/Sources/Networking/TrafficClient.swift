import Foundation
import TripCore

/// Live traffic source used while riding. Optional: failures only update the status line (CLAUDE.md rule 1).
protocol TrafficClient: Sendable {
    func incidents(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) async throws -> [TrafficIncident]
}

extension TrafficClient {
    /// Incidents on the route from `progress` over `length` metres (whole route by default), one request per
    /// 50 km piece, de-duplicated, nearest first.
    func alongRoute(_ route: Polyline, from progress: Double = 0, length: Double? = nil) async throws -> [IncidentAhead] {
        var found: [TrafficIncident] = []
        for b in TrafficIncidents.boxes(route: route, from: progress, length: length) {
            found += try await incidents(minLon: b.minLon, minLat: b.minLat, maxLon: b.maxLon, maxLat: b.maxLat)
        }
        var seen = Set<String>()
        found = found.filter { seen.insert($0.id).inserted }
        return TrafficIncidents.ahead(found, route: route, progress: progress, horizon: length ?? route.length)
    }
}

/// TomTom Traffic Incident Details v5 (free tier, key entered in Réglages, stored in the Keychain).
struct TomTomTrafficClient: TrafficClient {
    let key: String

    enum Failure: Error, Equatable {
        case rejectedKey, quota, http(Int)
    }

    func incidents(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) async throws -> [TrafficIncident] {
        var comps = URLComponents(string: "https://api.tomtom.com/traffic/services/5/incidentDetails")!
        comps.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "bbox", value: String(format: "%.5f,%.5f,%.5f,%.5f", minLon, minLat, maxLon, maxLat)),
            URLQueryItem(name: "fields", value: "{incidents{type,geometry{type,coordinates},properties{id,iconCategory,delay,events{description}}}}"),
            URLQueryItem(name: "language", value: "fr-FR"),
            URLQueryItem(name: "timeValidityFilter", value: "present"),
        ]
        var request = URLRequest(url: comps.url!, timeoutInterval: 5)
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try TrafficIncidents.parse(data)
        case 401, 403: throw Failure.rejectedKey
        case 429: throw Failure.quota
        case let code: throw Failure.http(code)
        }
    }

    /// French reason shown in the status line and in the key test.
    static func describe(_ error: Error) -> String {
        switch error {
        case Failure.rejectedKey: return "Clé TomTom refusée (vérifie-la dans Réglages › Trafic TomTom)"
        case Failure.quota: return "Quota TomTom du jour atteint"
        case Failure.http(let code): return "Erreur TomTom \(code)"
        case let url as URLError where [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost,
                                        .cannotConnectToHost, .dataNotAllowed].contains(url.code):
            return "Pas de réseau"
        case is DecodingError: return "Réponse TomTom illisible"
        default: return "Trafic indisponible (\(error.localizedDescription))"
        }
    }
}

/// Official live events (Bison Futé for French national roads, DGT for Spain) relayed by the PC, in the TomTom
/// shape. Reachable only through Tailscale: optional like every live source.
struct CompanionTrafficClient: TrafficClient {
    let client: CompanionClient

    func incidents(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) async throws -> [TrafficIncident] {
        try await client.liveEvents(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat)
    }
}

/// Every live source asked at once. A failing source is skipped (the others still count); an event reported by
/// several sources is announced once (TomTom first: it carries the delay).
struct CombinedTrafficClient: TrafficClient {
    let sources: [TrafficClient]

    func incidents(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) async throws -> [TrafficIncident] {
        let results = await withTaskGroup(of: (Int, Result<[TrafficIncident], Error>).self) { group in
            for (i, source) in sources.enumerated() {
                group.addTask {
                    do { return (i, .success(try await source.incidents(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat))) }
                    catch { return (i, .failure(error)) }
                }
            }
            var out: [(Int, Result<[TrafficIncident], Error>)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let lists = results.compactMap { try? $0.get() }
        if lists.isEmpty, case .failure(let error)? = results.first { throw error }
        return TrafficIncidents.merged(lists)
    }
}

enum LiveTraffic {
    /// TomTom (when a key is set) + the PC's official feeds (when the companion is configured); nil without either.
    @MainActor
    static func client(_ settings: AppSettings) -> TrafficClient? {
        var sources: [TrafficClient] = []
        if !settings.tomtomKey.isEmpty { sources.append(TomTomTrafficClient(key: settings.tomtomKey)) }
        if let pc = CompanionClient(urlString: settings.companionURL, token: settings.companionToken) {
            sources.append(CompanionTrafficClient(client: pc))
        }
        return sources.isEmpty ? nil : CombinedTrafficClient(sources: sources)
    }
}
