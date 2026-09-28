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
