import XCTest
@testable import TripCore

final class GroupTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let here = GeoPoint(lat: 44.0, lon: 6.0)

    // MARK: Position sharing

    func testFirstFixIsAlwaysSent() {
        var throttle = PositionThrottle()
        XCTAssertTrue(throttle.shouldSend(point: here, speedKmh: 90, at: t0))
    }

    func testMovingBikeSendsEveryFourSecondsNotBefore() {
        var throttle = PositionThrottle()
        _ = throttle.shouldSend(point: here, speedKmh: 80, at: t0)
        let step = GeoPoint(lat: here.lat + 0.0001, lon: here.lon)           // ~11 m
        XCTAssertFalse(throttle.shouldSend(point: step, speedKmh: 80, at: t0.addingTimeInterval(2)))
        XCTAssertTrue(throttle.shouldSend(point: step, speedKmh: 80, at: t0.addingTimeInterval(4)))
    }

    func testStoppedBikeSendsEveryTwentySeconds() {
        var throttle = PositionThrottle()
        _ = throttle.shouldSend(point: here, speedKmh: 0, at: t0)
        XCTAssertFalse(throttle.shouldSend(point: here, speedKmh: 0, at: t0.addingTimeInterval(10)))
        XCTAssertTrue(throttle.shouldSend(point: here, speedKmh: 0, at: t0.addingTimeInterval(20)))
    }

    func testBigJumpGoesOutAtOnce() {
        var throttle = PositionThrottle()
        _ = throttle.shouldSend(point: here, speedKmh: 0, at: t0)
        let far = GeoPoint(lat: here.lat + 0.001, lon: here.lon)             // ~111 m
        XCTAssertTrue(throttle.shouldSend(point: far, speedKmh: 0, at: t0.addingTimeInterval(1)))
    }

    func testInvalidFixIsNeverSentAndResetRestarts() {
        var throttle = PositionThrottle()
        XCTAssertFalse(throttle.shouldSend(point: GeoPoint(lat: 200, lon: 0), speedKmh: 50, at: t0))
        _ = throttle.shouldSend(point: here, speedKmh: 50, at: t0)
        throttle.reset()
        XCTAssertTrue(throttle.shouldSend(point: here, speedKmh: 50, at: t0.addingTimeInterval(0.5)))
    }

    /// Invariant: whatever the speed, no more than one send per 4 s once the bike moves less than 60 m between fixes.
    func testSendRateNeverExceedsOnePerFourSeconds() {
        var throttle = PositionThrottle()
        var sent = 0
        for second in 0..<120 {
            let p = GeoPoint(lat: here.lat + Double(second) * 0.00015, lon: here.lon)   // ~17 m per second
            if throttle.shouldSend(point: p, speedKmh: 60, at: t0.addingTimeInterval(Double(second))) { sent += 1 }
        }
        XCTAssertLessThanOrEqual(sent, 120 / 4 + 1)
        XCTAssertGreaterThanOrEqual(sent, 120 / 4)
    }

    // MARK: Friends on the map

    private let members = [GroupMember(id: "me", name: "FAB"), GroupMember(id: "a", name: "Julien"),
                           GroupMember(id: "b", name: "Marc"), GroupMember(id: "c", name: "Léa")]

    private func position(_ id: String, lat: Double, ageSeconds: Double) -> MemberPosition {
        MemberPosition(userId: id, point: GeoPoint(lat: lat, lon: 6.0), speedKmh: 70, course: 0,
                       updatedAt: t0.addingTimeInterval(-ageSeconds))
    }

    func testPinsExcludeMeUnknownAndOldAndSortByDistance() {
        let positions = [position("me", lat: 44.0, ageSeconds: 1),
                         position("a", lat: 44.02, ageSeconds: 5),        // ~2.2 km
                         position("b", lat: 44.01, ageSeconds: 5),        // ~1.1 km
                         position("c", lat: 44.03, ageSeconds: 400),      // too old
                         position("ghost", lat: 44.0, ageSeconds: 1)]     // not in the group
        let pins = FriendTracker.pins(positions: positions, members: members, me: "me", from: here, now: t0)
        XCTAssertEqual(pins.map(\.name), ["Marc", "Julien"])
        XCTAssertEqual(pins[0].distance!, 1_112, accuracy: 20)
        XCTAssertEqual(pins[0].bearing!, 0, accuracy: 0.5)
    }

    func testStaleAfterThirtySecondsButStillShown() {
        let pins = FriendTracker.pins(positions: [position("a", lat: 44.01, ageSeconds: 45)], members: members,
                                      me: "me", from: here, now: t0)
        XCTAssertEqual(pins.count, 1)
        XCTAssertTrue(pins[0].isStale)
        let fresh = FriendTracker.pins(positions: [position("a", lat: 44.01, ageSeconds: 10)], members: members,
                                       me: "me", from: here, now: t0)
        XCTAssertFalse(fresh[0].isStale)
    }

    func testPinsWithoutRiderPositionHaveNoDistance() {
        let pins = FriendTracker.pins(positions: [position("a", lat: 44.01, ageSeconds: 1)], members: members,
                                      me: "me", from: nil, now: t0)
        XCTAssertNil(pins[0].distance)
    }

    func testRelativeSide() {
        XCTAssertEqual(FriendTracker.relativeSide(bearing: 10, course: 0), .ahead)
        XCTAssertEqual(FriendTracker.relativeSide(bearing: 350, course: 5), .ahead)
        XCTAssertEqual(FriendTracker.relativeSide(bearing: 180, course: 0), .behind)
        XCTAssertEqual(FriendTracker.relativeSide(bearing: 90, course: 0), .right)
        XCTAssertEqual(FriendTracker.relativeSide(bearing: 270, course: 0), .left)
    }

    // MARK: What is read aloud

    private func message(_ user: String, _ kind: GroupMessageKind, _ body: String, age: Double = 5) -> GroupMessage {
        GroupMessage(id: 1, userId: user, kind: kind, body: body, createdAt: t0.addingTimeInterval(-age))
    }

    func testOwnAndOldMessagesAreNeverRead() {
        XCTAssertNil(GroupSpeech.announcement(for: message("me", .quick, "OK"), author: "FAB", me: "me", now: t0))
        XCTAssertNil(GroupSpeech.announcement(for: message("a", .quick, "OK", age: 120), author: "Julien", me: "me", now: t0))
    }

    func testFriendMessagesAreReadWithTheirAuthor() {
        XCTAssertEqual(GroupSpeech.announcement(for: message("a", .quick, "On fait une pause ?"), author: "Julien", me: "me", now: t0),
                       "Julien : On fait une pause ?")
        XCTAssertEqual(GroupSpeech.announcement(for: message("a", .trip, "Alpes 3 jours"), author: "Julien", me: "me", now: t0),
                       "Julien a partagé un trip : Alpes 3 jours")
        XCTAssertNil(GroupSpeech.announcement(for: message("a", .text, "   "), author: "Julien", me: "me", now: t0))
    }

    func testLongMessagesAreCut() {
        let long = String(repeating: "a", count: 400)
        let said = GroupSpeech.announcement(for: message("a", .text, long), author: "Julien", me: "me", now: t0)!
        XCTAssertLessThanOrEqual(said.count, "Julien : ".count + GroupSpeech.maxSpokenLength + 1)
    }

    func testEveryQuickReplyHasATextAndAnIcon() {
        for reply in QuickReply.allCases {
            XCTAssertFalse(reply.text.isEmpty)
            XCTAssertFalse(reply.icon.isEmpty)
        }
        XCTAssertEqual(Set(QuickReply.allCases.map(\.text)).count, QuickReply.allCases.count)
    }

    // MARK: Account rules

    func testNameRules() {
        XCTAssertTrue(GroupRules.isValidName("Fab"))
        XCTAssertTrue(GroupRules.isValidName("  Julien  "))
        XCTAssertFalse(GroupRules.isValidName("A"))
        XCTAssertFalse(GroupRules.isValidName("   "))
        XCTAssertFalse(GroupRules.isValidName(String(repeating: "x", count: 21)))
        XCTAssertEqual(GroupRules.cleanName("  Marc\n"), "Marc")
    }

    func testEmailAndPasswordRules() {
        XCTAssertTrue(GroupRules.isValidEmail("fab@example.com"))
        XCTAssertTrue(GroupRules.isValidEmail(" fab@mail.example.fr "))
        XCTAssertFalse(GroupRules.isValidEmail("fab@example"))
        XCTAssertFalse(GroupRules.isValidEmail("@example.com"))
        XCTAssertFalse(GroupRules.isValidEmail("fab @example.com"))
        XCTAssertFalse(GroupRules.isValidEmail("fab@@example.com"))
        XCTAssertFalse(GroupRules.isValidEmail("fab@example..com"))
        XCTAssertTrue(GroupRules.isValidPassword("12345678"))
        XCTAssertFalse(GroupRules.isValidPassword("1234567"))
    }

    func testMessageIsTrimmedAndBounded() {
        XCTAssertEqual(GroupRules.cleanMessage("  salut \n"), "salut")
        XCTAssertEqual(GroupRules.cleanMessage(String(repeating: "z", count: 900)).count, GroupRules.maxMessageLength)
    }

    // MARK: Invitations

    func testInviteRoundTrip() throws {
        let invite = GroupInvite(server: URL(string: "https://abcd.supabase.co")!, publicKey: "sb_publishable_xyz", code: "K7M2QX4P")
        let url = try XCTUnwrap(invite.url)
        XCTAssertEqual(GroupInvite.parse(url), invite)
    }

    func testInviteRejectsIncompleteOrUnsafeLinks() {
        XCTAssertNil(GroupInvite.parse(URL(string: "https://example.com")!))
        XCTAssertNil(GroupInvite.parse(URL(string: "motoroad://join?u=https://a.co&k=x")!))                     // no code
        XCTAssertNil(GroupInvite.parse(URL(string: "motoroad://join?u=http://a.co&k=x&c=K7M2QX4P")!))           // not https
        XCTAssertNil(GroupInvite.parse(URL(string: "motoroad://join?u=https://a.co&k=x&c=K7M2")!))              // short code
        XCTAssertNil(GroupInvite.parse(URL(string: "motoroad://join?u=https://a.co&k=x&c=K7M2QX40")!))          // 0 is not in the alphabet
        XCTAssertNil(GroupInvite.parse(URL(string: "motoroad://other?u=https://a.co&k=x&c=K7M2QX4P")!))
    }

    func testInviteIsFoundInAPastedMessage() throws {
        let invite = GroupInvite(server: URL(string: "https://abcd.supabase.co")!, publicKey: "sb_publishable_xyz", code: "K7M2QX4P")
        let link = try XCTUnwrap(invite.url?.absoluteString)
        XCTAssertEqual(GroupInvite.find(in: "Rejoins mon groupe Moto Road : \(link) à toute !"), invite)
        XCTAssertEqual(GroupInvite.find(in: "Voilà le lien \(link)."), invite, "a full stop after the link is not part of it")
        XCTAssertEqual(GroupInvite.find(in: "motoroad://autre?x=1 puis \(link)"), invite, "skips a link that is not an invitation")
        XCTAssertNil(GroupInvite.find(in: "rien à voir ici, https://example.com"))
        XCTAssertNil(GroupInvite.find(in: ""))
    }

    func testInviteCodeIsNormalized() {
        XCTAssertEqual(GroupInvite.normalize(code: "k7m2-qx4p"), "K7M2QX4P")
        XCTAssertTrue(GroupInvite.isValid(code: "k7m2 qx4p"))
    }

    // MARK: Server timestamps

    func testServerTimestampsWithMicrosecondsAndZones() throws {
        let a = try XCTUnwrap(GroupDates.parse("2026-10-04T12:34:56.789012+00:00"))
        let b = try XCTUnwrap(GroupDates.parse("2026-10-04T12:34:56+00:00"))
        let c = try XCTUnwrap(GroupDates.parse("2026-10-04T12:34:56Z"))
        let d = try XCTUnwrap(GroupDates.parse("2026-10-04T14:34:56.5+02:00"))
        XCTAssertEqual(a.timeIntervalSince(b), 0.789012, accuracy: 1e-6)
        XCTAssertEqual(b, c)
        XCTAssertEqual(d.timeIntervalSince(c), 0.5, accuracy: 1e-6)
        XCTAssertNil(GroupDates.parse("hier"))
    }

    func testSentTimestampsReadBackThroughTheParser() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_123.456)
        let back = try XCTUnwrap(GroupDates.parse(GroupDates.format(date)))
        XCTAssertEqual(back.timeIntervalSince(date), 0, accuracy: 0.001)
    }
}
