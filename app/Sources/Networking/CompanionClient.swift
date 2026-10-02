import Foundation
import TripCore

/// Client for the PC companion (reached through Tailscale, HTTPS via `tailscale serve`).
/// Used ONLY in creation mode and for optional background tasks — never required to navigate.
struct CompanionClient {
    let baseURL: URL
    let token: String

    init?(urlString: String, token: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return nil }
        baseURL = url
        self.token = token
    }

    struct Health: Decodable {
        let status: String
        let graphhopper: String?
        let planner: String?
    }

    struct ChatRequest: Encodable {
        let message: String
        let trip: Trip
    }

    struct ChatReply: Decodable {
        let text: String
        /// Partial or complete trip proposed by the planner (drawn on the map immediately).
        let trip: Trip?
        let questions: [String]?
    }

    enum Failure: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Companion : HTTP \(code) \(body.prefix(200))"
            }
        }
        var statusCode: Int {
            switch self {
            case .http(let code, _): return code
            }
        }
    }

    func health() async throws -> Health {
        try await get("health", timeout: 5)
    }

    /// A planner turn runs for several minutes on the PC: it is started, then polled.
    struct ChatJob: Decodable {
        let jobId: String
        let status: String          // running | done | error
        let progress: [String]?
        let reply: ChatReply?
        let error: String?
    }

    func startChat(tripId: String, message: String, trip: Trip) async throws -> ChatJob {
        try await post("trips/\(tripId)/chat", body: ChatRequest(message: message, trip: trip), timeout: 20)
    }

    func chatJob(tripId: String, jobId: String) async throws -> ChatJob {
        try await get("trips/\(tripId)/chat/\(jobId)", timeout: 15)
    }

    // MARK: Sync (A11)

    struct TripSummary: Decodable {
        let id: String
        let name: String
        let updatedAt: String?
    }

    func listTrips() async throws -> [TripSummary] {
        try await get("trips", timeout: 10)
    }

    func getTrip(_ id: String) async throws -> Trip {
        var r = request("trips/\(id)", timeout: 30)
        r.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.http(code, String(data: data, encoding: .utf8) ?? "") }
        return try TripCodec.decode(data)
    }

    func putTrip(_ trip: Trip) async throws {
        var r = request("trips/\(trip.id)", timeout: 30)
        r.httpMethod = "PUT"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try TripCodec.encode(trip)
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.http(code, String(data: data, encoding: .utf8) ?? "") }
    }

    func putRide(id: String, body: Data) async throws {
        var r = request("rides/\(id)", timeout: 30)
        r.httpMethod = "PUT"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure.http(code, String(data: data, encoding: .utf8) ?? "") }
    }

    // MARK: Offline alert pack (free ride)

    struct PackVersion: Decodable { let version: String }

    func alertPackVersion() async throws -> String {
        let v: PackVersion = try await get("alerts-pack/version", timeout: 10)
        return v.version
    }

    func alertPack() async throws -> AlertPack {
        try await get("alerts-pack", timeout: 120)
    }

    struct FinalizeRequest: Encodable { let trip: Trip }

    /// Locates the waypoints and computes each day's road track on the PC (GraphHopper), no Claude involved.
    func startFinalize(tripId: String, trip: Trip) async throws -> ChatJob {
        try await post("trips/\(tripId)/finalize", body: FinalizeRequest(trip: trip), timeout: 30)
    }

    /// Polls a job every 3 s until it ends; short network drops are retried.
    func waitForJob(tripId: String, jobId: String, onProgress: @escaping @MainActor (String?) -> Void) async throws -> ChatJob {
        var failures = 0
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            do {
                let job: ChatJob = try await get("trips/\(tripId)/jobs/\(jobId)", timeout: 15)
                failures = 0
                if job.status != "running" { return job }
                await onProgress(job.progress?.last)
            } catch let failure as Failure {
                throw failure            // 404: job lost (PC restarted), 401: token
            } catch {
                failures += 1
                if failures >= 40 { throw error }
            }
            try await Task.sleep(for: .seconds(3))
        }
        throw URLError(.timedOut)
    }

    /// Deletes a trip on the PC (set aside there). An unknown trip counts as deleted.
    func deleteTrip(_ id: String) async throws {
        var r = request("trips/\(id)", timeout: 15)
        r.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 204 || code == 404 else { throw Failure.http(code, String(data: data, encoding: .utf8) ?? "") }
    }

    // MARK: - Free ride route with several stops

    struct RideRoute: Decodable {
        let track: [GeoPoint]
        let instructions: [TurnInstruction]
        let distanceKm: Double
        let timeMin: Double
        /// Position of each intermediate stop along the track, metres.
        let via: [Double]
    }

    /// Road route through `points` (start, stops, end): « curvy », « nomotorway » or « fast » (10 s max).
    func rideRoute(points: [GeoPoint], mode: String) async throws -> RideRoute {
        struct Body: Encodable { let points: [[Double]]; let mode: String }
        return try await post("ride-route", body: Body(points: points.map { [$0.lat, $0.lon] }, mode: mode), timeout: 10)
    }

    // MARK: - Live events (riding: 5 s max, never waited for)

    func liveEvents(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) async throws -> [TrafficIncident] {
        var r = request("live-events", timeout: 5)
        var comps = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "bbox", value: String(format: "%.5f,%.5f,%.5f,%.5f", minLon, minLat, maxLon, maxLat))]
        r.url = comps.url
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.http(code, String(data: data, encoding: .utf8) ?? "") }
        return try TrafficIncidents.parse(data)
    }

    // MARK: - Transport

    private func request(_ path: String, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    private func get<T: Decodable>(_ path: String, timeout: TimeInterval) async throws -> T {
        try await send(request(path, timeout: timeout))
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B, timeout: TimeInterval) async throws -> T {
        var r = request(path, timeout: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(body)
        return try await send(r)
    }

    private func send<T: Decodable>(_ r: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw Failure.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
