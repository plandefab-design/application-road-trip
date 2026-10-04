import Foundation
import TripCore
import XCTest
@testable import MotoTrip
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Supabase client against a fake server: what is sent (URL, headers, body, time-out) and how answers and
/// errors are read. No network, no real account.
final class GroupBackendTests: XCTestCase {
    private static let anon = "anon-public-key"
    private let token = "user-access-token"

    private func backend(_ handler: @escaping (URLRequest, Data) throws -> (Int, String)) -> SupabaseBackend {
        FakeServer.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeServer.self]
        return SupabaseBackend(urlString: "https://abc.supabase.co", anonKey: Self.anon, session: URLSession(configuration: config))!
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func testOnlyHttpsServersWithAKeyAreAccepted() {
        XCTAssertNil(SupabaseBackend(urlString: "http://abc.supabase.co", anonKey: "k"))
        XCTAssertNil(SupabaseBackend(urlString: "https://abc.supabase.co", anonKey: ""))
        XCTAssertNil(SupabaseBackend(urlString: "pas une adresse", anonKey: "k"))
        XCTAssertNotNil(SupabaseBackend(urlString: " https://abc.supabase.co ", anonKey: "k"))
    }

    func testSignInSendsCredentialsWithThePublicKeyAndReadsTheSession() async throws {
        var seen: URLRequest?
        var sent: [String: Any] = [:]
        let server = backend { request, body in
            seen = request
            sent = self.json(body)
            return (200, #"{"access_token":"A","refresh_token":"R","expires_in":3600,"expires_at":1900000000,"user":{"id":"u1","email":"fab@example.com"}}"#)
        }
        let tokens = try await server.signIn(email: "fab@example.com", password: "motdepasse")
        XCTAssertEqual(seen?.url?.absoluteString, "https://abc.supabase.co/auth/v1/token?grant_type=password")
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "apikey"), Self.anon)
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.anon)")
        XCTAssertEqual(sent["email"] as? String, "fab@example.com")
        XCTAssertEqual(sent["password"] as? String, "motdepasse")
        XCTAssertEqual(tokens, GroupTokens(accessToken: "A", refreshToken: "R", expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
                                           userId: "u1", email: "fab@example.com"))
    }

    func testSignUpCarriesTheDisplayNameAndReportsAPendingConfirmation() async throws {
        var sent: [String: Any] = [:]
        let server = backend { _, body in
            sent = self.json(body)
            return (200, #"{"id":"u2","email":"julien@example.com","confirmation_sent_at":"2026-10-04T10:00:00Z"}"#)
        }
        let tokens = try await server.signUp(email: "julien@example.com", password: "motdepasse", displayName: "Julien")
        XCTAssertNil(tokens, "no session until the e-mail is confirmed")
        XCTAssertEqual((sent["data"] as? [String: Any])?["display_name"] as? String, "Julien")
    }

    func testSignUpWithoutConfirmationGivesTheSessionAtOnce() async throws {
        let server = backend { _, _ in
            (200, #"{"access_token":"A","refresh_token":"R","expires_in":3600,"user":{"id":"u3","email":null}}"#)
        }
        let tokens = try await server.signUp(email: "marc@example.com", password: "motdepasse", displayName: "Marc")
        XCTAssertEqual(tokens?.userId, "u3")
        XCTAssertEqual(tokens?.email, "marc@example.com")
        XCTAssertTrue(tokens?.isFresh() == true)
    }

    func testPositionIsAnUpsertWithAShortTimeout() async throws {
        var seen: URLRequest?
        var sent: [String: Any] = [:]
        let server = backend { request, body in
            seen = request
            sent = self.json(body)
            return (201, "")
        }
        try await server.putPosition(groupId: "g1", userId: "u1",
                                     fix: SharedFix(point: GeoPoint(lat: 44.1, lon: 6.2), speedKmh: 82, course: nil), token: token)
        XCTAssertEqual(seen?.url?.absoluteString, "https://abc.supabase.co/rest/v1/positions?on_conflict=user_id")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=minimal")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(seen?.timeoutInterval, SupabaseBackend.liveTimeout)
        XCTAssertLessThanOrEqual(SupabaseBackend.liveTimeout, 5, "riding never waits for the group (rule 1)")
        XCTAssertEqual(sent["user_id"] as? String, "u1")
        XCTAssertEqual(sent["group_id"] as? String, "g1")
        XCTAssertEqual(sent["lat"] as? Double, 44.1)
        XCTAssertEqual(sent["speed_kmh"] as? Double, 82)
        XCTAssertTrue(sent["course"] is NSNull)
    }

    func testPositionsAreReadWithMicrosecondTimestamps() async throws {
        let server = backend { request, _ in
            XCTAssertTrue(request.url?.absoluteString.contains("group_id=eq.g1") == true)
            return (200, #"[{"user_id":"u2","lat":44.5,"lon":6.5,"speed_kmh":null,"course":90.5,"updated_at":"2026-10-04T12:34:56.789012+00:00"}]"#)
        }
        let positions = try await server.positions(groupId: "g1", token: token)
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions[0].userId, "u2")
        XCTAssertNil(positions[0].speedKmh)
        XCTAssertEqual(positions[0].course, 90.5)
        XCTAssertEqual(positions[0].updatedAt, GroupDates.parse("2026-10-04T12:34:56.789012+00:00"))
    }

    func testChatFirstLoadTakesTheLatestAndKeepsChronologicalOrder() async throws {
        var url = ""
        let server = backend { request, _ in
            url = request.url?.absoluteString ?? ""
            return (200, #"[{"id":9,"user_id":"u1","kind":"quick","body":"OK","share_id":null,"created_at":"2026-10-04T10:00:09Z"},{"id":8,"user_id":"u2","kind":"text","body":"salut","share_id":null,"created_at":"2026-10-04T10:00:08Z"}]"#)
        }
        let messages = try await server.messages(groupId: "g1", after: nil, limit: 50, token: token)
        XCTAssertTrue(url.contains("order=id.desc") && url.contains("limit=50"))
        XCTAssertEqual(messages.map(\.id), [8, 9])
        XCTAssertEqual(messages.map(\.kind), [.text, .quick])
    }

    func testChatPollingAsksOnlyForNewMessages() async throws {
        var url = ""
        let server = backend { request, _ in
            url = request.url?.absoluteString ?? ""
            return (200, "[]")
        }
        _ = try await server.messages(groupId: "g1", after: 42, limit: 100, token: token)
        XCTAssertTrue(url.contains("id=gt.42") && url.contains("order=id.asc"))
    }

    func testJoinWithAnUnknownCodeIsReadAsSuch() async {
        let server = backend { _, _ in (400, #"{"code":"P0002","details":null,"hint":null,"message":"invalid code"}"#) }
        do {
            _ = try await server.joinGroup(code: "AAAAAAAA", token: token)
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? GroupError, .invalidCode)
        }
    }

    func testJoinNormalizesTheCode() async throws {
        var sent: [String: Any] = [:]
        let server = backend { _, body in
            sent = self.json(body)
            return (200, #"{"id":"g1","name":"Alpes","invite_code":"K7M2QX4P","owner_id":"u1","created_at":"2026-10-04T10:00:00Z"}"#)
        }
        let group = try await server.joinGroup(code: "k7m2-qx4p", token: token)
        XCTAssertEqual(sent["code"] as? String, "K7M2QX4P")
        XCTAssertEqual(group, GroupInfo(id: "g1", name: "Alpes", inviteCode: "K7M2QX4P", ownerId: "u1"))
    }

    func testErrorsAreMappedFromBothServerDialects() {
        func failure(_ status: Int, _ body: String) -> GroupError { SupabaseBackend.failure(status: status, body: Data(body.utf8)) }
        XCTAssertEqual(failure(400, #"{"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#), .invalidCredentials)
        XCTAssertEqual(failure(400, #"{"error":"invalid_grant","error_description":"Invalid login credentials"}"#), .invalidCredentials)
        XCTAssertEqual(failure(400, #"{"error_code":"email_not_confirmed","msg":"Email not confirmed"}"#), .emailNotConfirmed)
        XCTAssertEqual(failure(422, #"{"error_code":"user_already_exists","msg":"User already registered"}"#), .emailTaken)
        XCTAssertEqual(failure(422, #"{"error_code":"weak_password","msg":"Password should be at least 8 characters"}"#), .weakPassword)
        XCTAssertEqual(failure(400, #"{"code":"P0003","message":"group full"}"#), .groupFull)
        XCTAssertEqual(failure(403, #"{"code":"42501","message":"not the owner"}"#), .notAllowed)
        XCTAssertEqual(failure(401, #"{"code":"PGRST301","message":"JWT expired"}"#), .notSignedIn)
        XCTAssertEqual(failure(503, #"{"error":"voice not configured"}"#), .voiceUnavailable)
        XCTAssertEqual(failure(500, "boom"), .server(500, "boom"))
    }

    func testSharingATripUploadsTheFileThenTheRowAndCleansUpOnFailure() async throws {
        var calls: [String] = []
        let ok = backend { request, body in
            calls.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            if request.url?.path.hasPrefix("/storage/") == true {
                XCTAssertEqual(String(data: body, encoding: .utf8), "{\"trip\":true}")
                return (200, #"{"Key":"trips/x"}"#)
            }
            let id = (self.json(body)["id"] as? String) ?? ""
            return (201, #"[{"id":""# + id + #"","user_id":"u1","name":"Alpes","days":3,"distance_km":650,"storage_path":"g1/"# + id + #".json","created_at":"2026-10-04T10:00:00+00:00"}]"#)
        }
        let share = try await ok.shareTrip(groupId: "g1", name: "Alpes", days: 3, distanceKm: 650, file: Data("{\"trip\":true}".utf8), token: token)
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].hasPrefix("POST /storage/v1/object/trips/g1/") && calls[0].hasSuffix(".json"))
        XCTAssertEqual(calls[1], "POST /rest/v1/shared_trips")
        XCTAssertEqual(share.name, "Alpes")
        XCTAssertEqual(share.id, share.id.lowercased(), "paths must match the server's lower-case ids")

        calls = []
        let failing = backend { request, _ in
            calls.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return request.url?.path.hasPrefix("/rest/") == true ? (403, #"{"code":"42501","message":"denied"}"#) : (200, "{}")
        }
        do {
            _ = try await failing.shareTrip(groupId: "g1", name: "Alpes", days: 3, distanceKm: 650, file: Data("x".utf8), token: token)
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(calls.last?.hasPrefix("DELETE /storage/v1/object/trips/g1/"), true, "the orphan file is removed")
        }
    }

    func testDeletingASharedTripRemovesTheFileBeforeTheRow() async throws {
        var calls: [String] = []
        let server = backend { request, _ in
            calls.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return (200, "")
        }
        let share = SharedTrip(id: "t1", userId: "u1", name: "Alpes", days: 3, distanceKm: 650, createdAt: Date())
        try await server.deleteSharedTrip(share, groupId: "g1", token: token)
        XCTAssertEqual(calls, ["DELETE /storage/v1/object/trips/g1/t1.json", "DELETE /rest/v1/shared_trips"])
    }

    func testVoiceAccessAsksTheFunctionForOneGroupAndReadsTheToken() async throws {
        var seen: URLRequest?
        var sent: [String: Any] = [:]
        let server = backend { request, body in
            seen = request
            sent = self.json(body)
            return (200, #"{"token":"lk.jwt","url":"wss://moto.livekit.cloud"}"#)
        }
        let access = try await server.voiceAccess(groupId: "g1", token: token)
        XCTAssertEqual(seen?.url?.path, "/functions/v1/livekit-token")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(sent["groupId"] as? String, "g1")
        XCTAssertEqual(access, VoiceAccess(url: "wss://moto.livekit.cloud", token: "lk.jwt"))
    }

    func testTokensAreRefreshedAMinuteEarly() {
        let now = Date()
        let tokens = { (expiresIn: TimeInterval) in
            GroupTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(expiresIn), userId: "u", email: "e")
        }
        XCTAssertTrue(tokens(120).isFresh(at: now))
        XCTAssertFalse(tokens(59).isFresh(at: now))
        XCTAssertFalse(tokens(-5).isFresh(at: now))
    }
}

/// A server in memory: every request of the session goes to `handler` (status, body).
final class FakeServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        do {
            let (status, text) = try Self.handler?(request, body) ?? (500, "no handler")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
