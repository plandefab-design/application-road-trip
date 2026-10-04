import Foundation
import TripCore
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession on Linux (the request shapes are tested there too)
#endif

/// `GroupBackend` on Supabase (Auth + PostgREST + Storage + one Edge Function) through plain HTTPS: no SDK, so
/// what is sent is what is read here. Server side: `backend/supabase/schema.sql`.
struct SupabaseBackend: GroupBackend {
    let baseURL: URL
    let anonKey: String
    var session: URLSession = .shared

    /// Riding never waits for the group: live calls give up after 5 s (CLAUDE.md rule 1).
    static let liveTimeout: TimeInterval = 5
    static let normalTimeout: TimeInterval = 15
    static let fileTimeout: TimeInterval = 60

    init?(urlString: String, anonKey: String, session: URLSession = .shared) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil, !anonKey.isEmpty else { return nil }
        baseURL = url
        self.anonKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    // MARK: Account

    func signUp(email: String, password: String, displayName: String) async throws -> GroupTokens? {
        let body: [String: Any] = ["email": email, "password": password, "data": ["display_name": displayName]]
        let data = try await call("auth/v1/signup", method: "POST", token: nil, body: body, timeout: Self.normalTimeout)
        let reply = try Self.decoder.decode(AuthReply.self, from: data)
        return reply.accessToken == nil ? nil : try reply.tokens(fallbackEmail: email)
    }

    func signIn(email: String, password: String) async throws -> GroupTokens {
        let data = try await call("auth/v1/token", query: [.init(name: "grant_type", value: "password")], method: "POST",
                                  token: nil, body: ["email": email, "password": password], timeout: Self.normalTimeout)
        return try Self.decoder.decode(AuthReply.self, from: data).tokens(fallbackEmail: email)
    }

    func refresh(refreshToken: String) async throws -> GroupTokens {
        let data = try await call("auth/v1/token", query: [.init(name: "grant_type", value: "refresh_token")], method: "POST",
                                  token: nil, body: ["refresh_token": refreshToken], timeout: Self.normalTimeout)
        return try Self.decoder.decode(AuthReply.self, from: data).tokens(fallbackEmail: "")
    }

    func deleteAccount(token: String) async throws {
        _ = try await call("rest/v1/rpc/delete_account", method: "POST", token: token, body: [String: Any](), timeout: Self.normalTimeout)
    }

    // MARK: Groups

    private static let groupColumns = "id,name,invite_code,owner_id"

    func myGroups(token: String) async throws -> [GroupInfo] {
        let data = try await call("rest/v1/groups", query: [.init(name: "select", value: Self.groupColumns),
                                                            .init(name: "order", value: "created_at.asc")],
                                  token: token, timeout: Self.normalTimeout)
        return try Self.decoder.decode([GroupRow].self, from: data).map(\.info)
    }

    func createGroup(name: String, token: String) async throws -> GroupInfo {
        try await rpcGroup("create_group", ["group_name": name], token: token)
    }

    func joinGroup(code: String, token: String) async throws -> GroupInfo {
        try await rpcGroup("join_group", ["code": GroupInvite.normalize(code: code)], token: token)
    }

    func rotateInvite(groupId: String, token: String) async throws -> GroupInfo {
        try await rpcGroup("rotate_invite", ["gid": groupId], token: token)
    }

    func leaveGroup(id: String, token: String) async throws {
        _ = try await call("rest/v1/rpc/leave_group", method: "POST", token: token, body: ["gid": id], timeout: Self.normalTimeout)
    }

    func roster(groupId: String, token: String) async throws -> [GroupMember] {
        let data = try await call("rest/v1/rpc/group_roster", method: "POST", token: token, body: ["gid": groupId],
                                  timeout: Self.normalTimeout)
        return try Self.decoder.decode([RosterRow].self, from: data).map {
            GroupMember(id: $0.userId, name: $0.displayName, isOwner: $0.isOwner)
        }
    }

    func removeMember(groupId: String, userId: String, token: String) async throws {
        _ = try await call("rest/v1/group_members", query: [.init(name: "group_id", value: "eq.\(groupId)"),
                                                            .init(name: "user_id", value: "eq.\(userId)")],
                           method: "DELETE", token: token, timeout: Self.normalTimeout)
    }

    private func rpcGroup(_ function: String, _ args: [String: Any], token: String) async throws -> GroupInfo {
        let data = try await call("rest/v1/rpc/\(function)", method: "POST", token: token, body: args, timeout: Self.normalTimeout)
        return try Self.decoder.decode(GroupRow.self, from: data).info
    }

    // MARK: Live position

    func putPosition(groupId: String, userId: String, fix: SharedFix, token: String) async throws {
        let body: [String: Any] = [
            "user_id": userId, "group_id": groupId, "lat": fix.point.lat, "lon": fix.point.lon,
            "speed_kmh": fix.speedKmh.map { $0 as Any } ?? NSNull(),
            "course": fix.course.map { $0 as Any } ?? NSNull(),
        ]
        _ = try await call("rest/v1/positions", query: [.init(name: "on_conflict", value: "user_id")], method: "POST", token: token,
                           body: body, prefer: "resolution=merge-duplicates,return=minimal", timeout: Self.liveTimeout)
    }

    func positions(groupId: String, token: String) async throws -> [MemberPosition] {
        let data = try await call("rest/v1/positions",
                                  query: [.init(name: "select", value: "user_id,lat,lon,speed_kmh,course,updated_at"),
                                          .init(name: "group_id", value: "eq.\(groupId)")],
                                  token: token, timeout: Self.liveTimeout)
        return try Self.decoder.decode([PositionRow].self, from: data).map(\.position)
    }

    func deletePosition(userId: String, token: String) async throws {
        _ = try await call("rest/v1/positions", query: [.init(name: "user_id", value: "eq.\(userId)")], method: "DELETE",
                           token: token, timeout: Self.liveTimeout)
    }

    // MARK: Chat

    func messages(groupId: String, after: Int?, limit: Int, token: String) async throws -> [GroupMessage] {
        var query: [URLQueryItem] = [.init(name: "select", value: "id,user_id,kind,body,share_id,created_at"),
                                     .init(name: "group_id", value: "eq.\(groupId)"),
                                     .init(name: "limit", value: String(limit))]
        if let after {
            query += [.init(name: "id", value: "gt.\(after)"), .init(name: "order", value: "id.asc")]
        } else {
            query.append(.init(name: "order", value: "id.desc"))        // the latest ones, put back in order below
        }
        let data = try await call("rest/v1/messages", query: query, token: token, timeout: Self.liveTimeout)
        let rows = try Self.decoder.decode([MessageRow].self, from: data).map(\.message)
        return after == nil ? rows.reversed() : rows
    }

    func send(groupId: String, kind: GroupMessageKind, body: String, shareId: String?, token: String) async throws {
        let row: [String: Any] = ["group_id": groupId, "kind": kind.rawValue, "body": GroupRules.cleanMessage(body),
                                  "share_id": shareId.map { $0 as Any } ?? NSNull()]
        _ = try await call("rest/v1/messages", method: "POST", token: token, body: row, prefer: "return=minimal",
                           timeout: Self.normalTimeout)
    }

    // MARK: Shared trips

    private static let tripColumns = "id,user_id,name,days,distance_km,storage_path,created_at"

    func sharedTrips(groupId: String, token: String) async throws -> [SharedTrip] {
        let data = try await call("rest/v1/shared_trips",
                                  query: [.init(name: "select", value: Self.tripColumns),
                                          .init(name: "group_id", value: "eq.\(groupId)"),
                                          .init(name: "order", value: "created_at.desc"),
                                          .init(name: "limit", value: "30")],
                                  token: token, timeout: Self.normalTimeout)
        return try Self.decoder.decode([SharedTripRow].self, from: data).map(\.trip)
    }

    func shareTrip(groupId: String, name: String, days: Int, distanceKm: Double, file: Data, token: String) async throws -> SharedTrip {
        let id = UUID().uuidString.lowercased()
        let path = "\(groupId)/\(id).json"
        _ = try await call("storage/v1/object/trips/\(path)", method: "POST", token: token, rawBody: file,
                           timeout: Self.fileTimeout)
        let row: [String: Any] = ["id": id, "group_id": groupId, "name": String(name.prefix(120)), "days": days,
                                  "distance_km": distanceKm, "storage_path": path]
        do {
            let data = try await call("rest/v1/shared_trips", query: [.init(name: "select", value: Self.tripColumns)],
                                      method: "POST", token: token, body: row, prefer: "return=representation",
                                      timeout: Self.normalTimeout)
            guard let first = try Self.decoder.decode([SharedTripRow].self, from: data).first else {
                throw GroupError.server(0, "réponse vide")
            }
            return first.trip
        } catch {
            // No row, no use for the file.
            _ = try? await call("storage/v1/object/trips/\(path)", method: "DELETE", token: token, timeout: Self.normalTimeout)
            throw error
        }
    }

    func downloadTrip(_ share: SharedTrip, groupId: String, token: String) async throws -> Data {
        try await call("storage/v1/object/authenticated/trips/\(Self.path(share, groupId))", token: token, timeout: Self.fileTimeout)
    }

    func deleteSharedTrip(_ share: SharedTrip, groupId: String, token: String) async throws {
        // The file first: its deletion rule looks the row up.
        _ = try await call("storage/v1/object/trips/\(Self.path(share, groupId))", method: "DELETE", token: token,
                           timeout: Self.normalTimeout)
        _ = try await call("rest/v1/shared_trips", query: [.init(name: "id", value: "eq.\(share.id)")], method: "DELETE",
                           token: token, timeout: Self.normalTimeout)
    }

    private static func path(_ share: SharedTrip, _ groupId: String) -> String { "\(groupId)/\(share.id).json" }

    // MARK: Voice

    func voiceAccess(groupId: String, token: String) async throws -> VoiceAccess {
        let data = try await call("functions/v1/livekit-token", method: "POST", token: token, body: ["groupId": groupId], timeout: 10)
        let reply = try Self.decoder.decode(VoiceReply.self, from: data)
        return VoiceAccess(url: reply.url, token: reply.token)
    }

    // MARK: Transport

    /// - Parameters:
    ///   - token: the rider's access token; nil = the public key only (sign-up, sign-in).
    ///   - body: JSON object; `rawBody` sends bytes as they are (trip files).
    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", token: String?, body: [String: Any]? = nil,
                 rawBody: Data? = nil, prefer: String? = nil, timeout: TimeInterval) throws -> URLRequest {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw GroupError.notConfigured }
        parts.path = (baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path) + "/" + path
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw GroupError.notConfigured }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(anonKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(token ?? anonKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let prefer { r.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let rawBody {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = rawBody
        } else if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func call(_ path: String, query: [URLQueryItem] = [], method: String = "GET", token: String?, body: [String: Any]? = nil,
                      rawBody: Data? = nil, prefer: String? = nil, timeout: TimeInterval) async throws -> Data {
        let r = try request(path, query: query, method: method, token: token, body: body, rawBody: rawBody, prefer: prefer,
                            timeout: timeout)
        do {
            let (data, response) = try await session.data(for: r)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw Self.failure(status: code, body: data) }
            return data
        } catch let error as GroupError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                throw GroupError.offline
            default:
                throw GroupError.server(0, error.localizedDescription)
            }
        }
    }

    /// Server answers (GoTrue and PostgREST word their errors differently) → our own errors.
    static func failure(status: Int, body: Data) -> GroupError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        func text(_ keys: String...) -> String { keys.compactMap { json[$0] as? String }.first ?? "" }
        let code = text("error_code", "code")
        let message = text("msg", "message", "error_description", "error")
        let lower = message.lowercased()
        switch code {
        case "invalid_credentials": return .invalidCredentials
        case "email_not_confirmed": return .emailNotConfirmed
        case "user_already_exists", "email_exists": return .emailTaken
        case "weak_password": return .weakPassword
        case "P0002": return .invalidCode
        case "P0003": return .groupFull
        case "42501" where status != 401: return .notAllowed
        case "28000": return .notSignedIn
        default: break
        }
        if lower.contains("invalid login credentials") { return .invalidCredentials }
        if lower.contains("email not confirmed") { return .emailNotConfirmed }
        if lower.contains("already registered") { return .emailTaken }
        if lower.contains("voice not configured") { return .voiceUnavailable }
        if status == 401 { return .notSignedIn }
        return .server(status, message.isEmpty ? (String(data: body, encoding: .utf8) ?? "") : message)
    }

    // MARK: Rows

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private struct AuthReply: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Double?
        let expiresAt: Double?
        let user: AuthUser?

        struct AuthUser: Decodable {
            let id: String
            let email: String?
        }

        func tokens(fallbackEmail: String) throws -> GroupTokens {
            guard let accessToken, let refreshToken, let user else { throw GroupError.server(0, "réponse d'authentification incomplète") }
            let expiry = expiresAt.map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(expiresIn ?? 3600)
            return GroupTokens(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiry, userId: user.id,
                               email: user.email ?? fallbackEmail)
        }
    }

    private struct GroupRow: Decodable {
        let id: String
        let name: String
        let inviteCode: String
        let ownerId: String
        var info: GroupInfo { GroupInfo(id: id, name: name, inviteCode: inviteCode, ownerId: ownerId) }
    }

    private struct RosterRow: Decodable {
        let userId: String
        let displayName: String
        let isOwner: Bool
    }

    private struct PositionRow: Decodable {
        let userId: String
        let lat: Double
        let lon: Double
        let speedKmh: Double?
        let course: Double?
        let updatedAt: String
        var position: MemberPosition {
            MemberPosition(userId: userId, point: GeoPoint(lat: lat, lon: lon), speedKmh: speedKmh, course: course,
                           updatedAt: GroupDates.parse(updatedAt) ?? Date())
        }
    }

    private struct MessageRow: Decodable {
        let id: Int
        let userId: String
        let kind: String
        let body: String
        let shareId: String?
        let createdAt: String
        var message: GroupMessage {
            GroupMessage(id: id, userId: userId, kind: GroupMessageKind(rawValue: kind) ?? .text, body: body, shareId: shareId,
                         createdAt: GroupDates.parse(createdAt) ?? Date())
        }
    }

    private struct SharedTripRow: Decodable {
        let id: String
        let userId: String
        let name: String
        let days: Int
        let distanceKm: Double
        let createdAt: String
        var trip: SharedTrip {
            SharedTrip(id: id, userId: userId, name: name, days: days, distanceKm: distanceKm,
                       createdAt: GroupDates.parse(createdAt) ?? Date())
        }
    }

    private struct VoiceReply: Decodable {
        let token: String
        let url: String
    }
}
