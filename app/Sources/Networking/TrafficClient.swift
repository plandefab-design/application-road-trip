import Foundation
import TripCore

/// Live traffic source used while riding. Optional: failures only update the status line (CLAUDE.md rule 1).
protocol TrafficClient {
    func incidents(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) async throws -> [TrafficIncident]
}

/// TomTom Traffic Incident Details v5 (free tier, key entered in Réglages, stored in the Keychain).
struct TomTomTrafficClient: TrafficClient {
    let key: String

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
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw URLError(code == 403 ? .userAuthenticationRequired : .badServerResponse) }
        return try TrafficIncidents.parse(data)
    }
}
