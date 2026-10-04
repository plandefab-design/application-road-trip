import Foundation
import TripCore
import XCTest
@testable import MotoTrip

/// The group session against an in-memory server: account and tokens, groups, live positions, chat read aloud
/// while riding, shared trips, voice. No network.
@MainActor
final class GroupSessionTests: XCTestCase {
    private let key = "anon-public-key"
    private let here = GeoPoint(lat: 44.0, lon: 6.0)

    // MARK: Fixtures

    private func makeSession(clock: TestClock = TestClock(), backend: FakeBackend? = nil, voice: FakeVoiceRoom? = nil,
                             storage: FakeStorage = FakeStorage()) -> (GroupSession, FakeBackend, FakeStorage, TestClock) {
        let server = backend ?? FakeBackend(clock: clock)
        let session = GroupSession(storage: storage, voiceRoom: voice, now: { clock.now() }, makeBackend: { _ in server })
        session.configure(url: "https://abc.supabase.co", anonKey: key)
        return (session, server, storage, clock)
    }

    /// Fab, signed in, owner of "Alpes".
    private func signedInWithGroup(voice: FakeVoiceRoom? = nil) async -> (GroupSession, FakeBackend, FakeStorage, TestClock) {
        let made = makeSession(voice: voice)
        let ok = await made.0.signUp(email: "fab@example.com", password: "motdepasse", name: "Fab")
        XCTAssertTrue(ok)
        let created = await made.0.createGroup(name: "Alpes")
        XCTAssertTrue(created)
        return made
    }

    private func eventually(_ what: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), what)
    }

    // MARK: Account

    func testSignUpSignsInAndRemembersTheAccount() async {
        let (session, _, storage, _) = makeSession()
        XCTAssertEqual(session.phase, .signedOut)
        let ok = await session.signUp(email: "fab@example.com", password: "motdepasse", name: "  Fab ")
        XCTAssertTrue(ok)
        XCTAssertEqual(session.phase, .signedIn)
        XCTAssertEqual(storage.displayName, "Fab")
        XCTAssertNotNil(storage.tokens)
        XCTAssertEqual(session.email, "fab@example.com")
    }

    func testBadFormsNeverReachTheServer() async {
        let (session, server, _, _) = makeSession()
        let shortName = await session.signUp(email: "fab@example.com", password: "motdepasse", name: "F")
        let badMail = await session.signUp(email: "fab@example", password: "motdepasse", name: "Fab")
        let weak = await session.signUp(email: "fab@example.com", password: "court", name: "Fab")
        XCTAssertFalse(shortName || badMail || weak)
        XCTAssertEqual(server.accountCount, 0)
        XCTAssertNotNil(session.lastError)
    }

    func testSignUpWaitingForTheConfirmationEmailIsNotASignIn() async {
        let (session, server, _, _) = makeSession()
        server.confirmEmail = true
        let ok = await session.signUp(email: "fab@example.com", password: "motdepasse", name: "Fab")
        XCTAssertFalse(ok)
        XCTAssertEqual(session.phase, .signedOut)
        XCTAssertNotNil(session.notice)
        XCTAssertNil(session.lastError)
    }

    func testWrongPasswordIsExplained() async {
        let (session, _, _, _) = makeSession()
        _ = await session.signUp(email: "fab@example.com", password: "motdepasse", name: "Fab")
        await session.signOut()
        let ok = await session.signIn(email: "fab@example.com", password: "mauvais!!")
        XCTAssertFalse(ok)
        XCTAssertEqual(session.lastError, GroupError.invalidCredentials.errorDescription)
    }

    func testTheAccountSurvivesARestart() async {
        let first = makeSession()
        _ = await first.0.signUp(email: "fab@example.com", password: "motdepasse", name: "Fab")
        _ = await first.0.createGroup(name: "Alpes")
        let again = GroupSession(storage: first.2, now: { first.3.now() }, makeBackend: { _ in first.1 })
        XCTAssertEqual(again.phase, .signedIn)
        XCTAssertEqual(again.currentGroupId, first.0.currentGroupId)
        XCTAssertEqual(again.myName, "Fab")
    }

    // MARK: Tokens

    func testSeveralCallsRefreshAnExpiredTokenOnlyOnce() async {
        let (session, server, _, clock) = await signedInWithGroup()
        let before = server.refreshCount
        clock.offset = 7_200                                    // the access token has expired
        async let a: Void = session.pollOnce()
        async let b: Void = session.pollOnce()
        _ = await (a, b)
        XCTAssertEqual(server.refreshCount, before + 1)
        XCTAssertEqual(session.phase, .signedIn)
    }

    func testARefusedRefreshSignsOutButAnOfflineOneKeepsTheAccount() async {
        let (session, server, _, clock) = await signedInWithGroup()
        clock.offset = 7_200
        server.offline = true
        await session.pollOnce()
        XCTAssertEqual(session.phase, .signedIn, "no network is not a reason to sign out")
        XCTAssertEqual(session.connection, .offline)

        server.offline = false
        server.refreshFailure = GroupError.server(400, "refresh_token_not_found")
        await session.pollOnce()
        XCTAssertEqual(session.phase, .signedOut)
        XCTAssertNotNil(session.lastError)
    }

    func testATokenTheServerStillRefusesIsRenewedOnce() async {
        let (session, server, _, _) = await signedInWithGroup()
        server.rejectNextToken = true
        let before = server.refreshCount
        await session.pollOnce()
        XCTAssertEqual(server.refreshCount, before + 1)
        XCTAssertEqual(session.connection, .online)
    }

    // MARK: Groups

    func testCreatingAGroupMakesYouItsOnlyMemberAndGivesAnInviteLink() async throws {
        let (session, _, _, _) = await signedInWithGroup()
        XCTAssertEqual(session.members.map(\.name), ["Fab"])
        XCTAssertTrue(session.isOwner)
        let link = try XCTUnwrap(session.inviteURL)
        let invite = try XCTUnwrap(GroupInvite.parse(link))
        XCTAssertEqual(invite.code, session.currentGroup?.inviteCode)
        XCTAssertEqual(invite.publicKey, key)
        XCTAssertEqual(invite.server.absoluteString, "https://abc.supabase.co")
    }

    func testAFriendJoinsWithTheLink() async throws {
        let (fab, server, _, clock) = await signedInWithGroup()
        let link = try XCTUnwrap(fab.inviteURL)

        let friend = GroupSession(storage: FakeStorage(), now: { clock.now() }, makeBackend: { _ in server })
        await friend.receive(try XCTUnwrap(GroupInvite.parse(link)))
        XCTAssertEqual(friend.phase, .signedOut, "server set up, account still to create")
        XCTAssertNotNil(friend.pendingInvite)
        let ok = await friend.signUp(email: "julien@example.com", password: "motdepasse", name: "Julien")
        XCTAssertTrue(ok)
        XCTAssertNil(friend.pendingInvite, "the code was used right after sign-up")
        XCTAssertEqual(friend.members.map(\.name), ["Fab", "Julien"])
        XCTAssertFalse(friend.isOwner)
    }

    func testAWrongCodeIsRefused() async {
        let (session, _, _, _) = await signedInWithGroup()
        let ok = await session.joinGroup(code: "AAAAAAAA")
        XCTAssertFalse(ok)
        XCTAssertEqual(session.lastError, GroupError.invalidCode.errorDescription)
        let malformed = await session.joinGroup(code: "12")
        XCTAssertFalse(malformed)
    }

    func testLeavingTheGroupClearsEverything() async {
        let (session, _, _, _) = await signedInWithGroup()
        _ = await session.sendQuick(.ok)
        XCTAssertFalse(session.messages.isEmpty)
        await session.leaveCurrentGroup()
        XCTAssertNil(session.currentGroup)
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertTrue(session.members.isEmpty)
    }

    func testOnlyTheOwnerRemovesSomeone() async throws {
        let (fab, server, _, clock) = await signedInWithGroup()
        let julien = GroupSession(storage: FakeStorage(), now: { clock.now() }, makeBackend: { _ in server })
        julien.configure(url: "https://abc.supabase.co", anonKey: key)
        _ = await julien.signUp(email: "julien@example.com", password: "motdepasse", name: "Julien")
        _ = await julien.joinGroup(code: try XCTUnwrap(fab.currentGroup?.inviteCode))
        await fab.reloadCurrent()
        let target = try XCTUnwrap(fab.members.first { $0.name == "Julien" })

        await julien.remove(try XCTUnwrap(julien.members.first { $0.name == "Fab" }))
        XCTAssertEqual(server.memberCount(of: try XCTUnwrap(fab.currentGroupId)), 2, "a member cannot remove the owner")

        await fab.remove(target)
        XCTAssertEqual(server.memberCount(of: try XCTUnwrap(fab.currentGroupId)), 1)
    }

    // MARK: Position while riding

    func testNothingIsSentUntilTheRiderAgreesAndRides() async {
        let (session, server, _, _) = await signedInWithGroup()
        session.reportFix(here, speedKmh: 80, course: 10)          // not riding
        session.rideDidStart(speak: { _ in })
        session.reportFix(here, speedKmh: 80, course: 10)          // riding, sharing still off
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(server.putCount, 0)
        session.rideDidEnd()
    }

    func testSharedPositionsAreThrottledAndWithdrawnAtTheEndOfTheRide() async {
        let (session, server, _, clock) = await signedInWithGroup()
        session.sharePosition = true
        session.rideDidStart(speak: { _ in })

        session.reportFix(here, speedKmh: 80, course: 10)
        await eventually("first fix sent") { server.putCount == 1 }
        session.reportFix(GeoPoint(lat: 44.0001, lon: 6.0), speedKmh: 80, course: 10)      // same second: held back
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(server.putCount, 1)

        clock.offset += 5
        session.reportFix(GeoPoint(lat: 44.0002, lon: 6.0), speedKmh: 80, course: -1)
        await eventually("second fix sent after 5 s") { server.putCount == 2 }
        XCTAssertNil(server.lastPut?.course, "an unknown course (-1) is not sent")

        session.rideDidEnd()
        await eventually("position withdrawn") { server.deletedPositionCount == 1 }
    }

    func testSwitchingSharingOffWithdrawsThePosition() async {
        let (session, server, _, _) = await signedInWithGroup()
        session.sharePosition = true
        session.sharePosition = false
        await eventually("position withdrawn") { server.deletedPositionCount >= 1 }
    }

    func testAnUnreachableServerNeverBlocksNorPilesUpSends() async {
        let (session, server, _, clock) = await signedInWithGroup()
        session.sharePosition = true
        session.rideDidStart(speak: { _ in })
        server.offline = true
        for step in 0..<5 {
            clock.offset += 5
            session.reportFix(GeoPoint(lat: 44 + Double(step) * 0.001, lon: 6), speedKmh: 80, course: 0)
        }
        await eventually("marked offline") { session.connection == .offline }
        XCTAssertEqual(server.putCount, 0)
        server.offline = false
        clock.offset += 5
        session.reportFix(GeoPoint(lat: 44.01, lon: 6), speedKmh: 80, course: 0)
        await eventually("back online") { server.putCount == 1 && session.connection == .online }
        session.rideDidEnd()
    }

    // MARK: Friends on the map

    func testFriendsAppearNearestFirstAndStaleOnesFade() async {
        let (session, server, _, clock) = await signedInWithGroup()
        let groupId = session.currentGroupId!
        server.addMember(groupId: groupId, name: "Julien", id: "julien")
        server.addMember(groupId: groupId, name: "Marc", id: "marc")
        await session.reloadCurrent()
        session.reportFix(here, speedKmh: 50, course: 0)            // my own position, for the distances
        server.setPosition(groupId: groupId, userId: "julien", point: GeoPoint(lat: 44.02, lon: 6), age: 5, now: clock.now())
        server.setPosition(groupId: groupId, userId: "marc", point: GeoPoint(lat: 44.01, lon: 6), age: 45, now: clock.now())
        await session.pollOnce()
        XCTAssertEqual(session.friendPins.map(\.name), ["Marc", "Julien"])
        XCTAssertEqual(session.friendPins.map(\.isStale), [true, false])
        XCTAssertFalse(session.friendPins.contains { $0.id == session.userId }, "I am not my own friend")
    }

    // MARK: Chat

    func testQuickReplyIsSentAndShownInOrder() async {
        let (session, _, _, _) = await signedInWithGroup()
        let ok = await session.sendQuick(.pause)
        XCTAssertTrue(ok)
        _ = await session.sendText("  on se retrouve à Barcelonnette \n")
        XCTAssertEqual(session.messages.map(\.body), ["On fait une pause ?", "on se retrouve à Barcelonnette"])
        XCTAssertEqual(session.messages.map(\.kind), [.quick, .text])
        let empty = await session.sendText("   ")
        XCTAssertFalse(empty)
    }

    func testIncomingMessagesAreReadAloudOnlyWhileRidingAndNeverTheOwnOnes() async {
        let (session, server, _, clock) = await signedInWithGroup()
        let groupId = session.currentGroupId!
        server.addMember(groupId: groupId, name: "Julien", id: "julien")
        await session.reloadCurrent()
        var said: [String] = []
        session.rideDidStart(speak: { said.append($0) })

        server.post(groupId: groupId, userId: "julien", kind: .quick, body: "On fait une pause ?", at: clock.now())
        _ = await session.sendQuick(.ok)                           // mine: refreshes the chat too
        XCTAssertEqual(said, ["Julien : On fait une pause ?"])

        said = []
        session.rideDidEnd()
        server.post(groupId: groupId, userId: "julien", kind: .text, body: "Je suis arrivé", at: clock.now())
        await session.pollOnce()
        XCTAssertTrue(said.isEmpty, "not riding: nothing is read")
    }

    func testOldMessagesAreNotReadWhenARideStarts() async {
        let (session, server, _, clock) = await signedInWithGroup()
        let groupId = session.currentGroupId!
        server.addMember(groupId: groupId, name: "Julien", id: "julien")
        server.post(groupId: groupId, userId: "julien", kind: .text, body: "Hier soir", at: clock.now().addingTimeInterval(-3_600))
        var said: [String] = []
        session.rideDidStart(speak: { said.append($0) })
        await session.reloadCurrent()
        await session.pollOnce()
        XCTAssertTrue(said.isEmpty, "a message older than a minute is not read out of the blue")
        XCTAssertEqual(session.messages.count, 1, "but it is in the chat")
    }

    func testUnreadCountsFriendsMessagesUntilTheTabIsOpened() async {
        let (session, server, _, clock) = await signedInWithGroup()
        let groupId = session.currentGroupId!
        server.addMember(groupId: groupId, name: "Julien", id: "julien")
        await session.reloadCurrent()
        server.post(groupId: groupId, userId: "julien", kind: .text, body: "1", at: clock.now())
        server.post(groupId: groupId, userId: "julien", kind: .text, body: "2", at: clock.now())
        await session.pollOnce()
        XCTAssertEqual(session.unread, 2)
        session.watch(.groupTab, true)
        XCTAssertEqual(session.unread, 0)
        server.post(groupId: groupId, userId: "julien", kind: .text, body: "3", at: clock.now())
        await session.pollOnce()
        XCTAssertEqual(session.unread, 0, "the tab is open: read at once")
        session.watch(.groupTab, false)
    }

    func testUnreadSurvivesARestart() async {
        let (session, server, storage, clock) = await signedInWithGroup()
        let groupId = session.currentGroupId!
        server.addMember(groupId: groupId, name: "Julien", id: "julien")
        await session.reloadCurrent()
        session.markRead()
        server.post(groupId: groupId, userId: "julien", kind: .text, body: "pendant ton absence", at: clock.now())
        let again = GroupSession(storage: storage, now: { clock.now() }, makeBackend: { _ in server })
        await again.refreshGroups()
        XCTAssertEqual(again.unread, 1)
    }

    // MARK: Shared trips

    private func sampleTrip() -> Trip {
        Trip(name: "Alpes 3 jours", status: .ready, params: TripParams(start: Place(name: "A", point: here), dateStart: "2027-06-01", dateEnd: "2027-06-03"),
             days: [TripDay(index: 1, distanceKm: 250), TripDay(index: 2, distanceKm: 300)],
             checklist: [ChecklistItem(label: "Plein", due: "J-1", done: true)],
             offlinePack: OfflinePack(tiles: "maplibre-offline", integrity: .ok))
    }

    func testSharedTripReachesAFriendAsHisOwnCopy() async throws {
        let (fab, server, _, clock) = await signedInWithGroup()
        let original = sampleTrip()
        let shared = await fab.share(original)
        XCTAssertTrue(shared)
        XCTAssertEqual(fab.sharedTrips.first?.days, 2)
        XCTAssertEqual(fab.sharedTrips.first?.distanceKm ?? 0, 550, accuracy: 0.001)
        XCTAssertEqual(fab.messages.last?.kind, .trip, "the group is told")

        let julien = GroupSession(storage: FakeStorage(), now: { clock.now() }, makeBackend: { _ in server })
        julien.configure(url: "https://abc.supabase.co", anonKey: key)
        _ = await julien.signUp(email: "julien@example.com", password: "motdepasse", name: "Julien")
        _ = await julien.joinGroup(code: try XCTUnwrap(fab.currentGroup?.inviteCode))
        let share = try XCTUnwrap(julien.sharedTrips.first)
        XCTAssertFalse(julien.isImported(share))
        let copy = await julien.importShared(share)
        let trip = try XCTUnwrap(copy)
        XCTAssertNotEqual(trip.id, original.id)
        XCTAssertEqual(trip.name, "Alpes 3 jours")
        XCTAssertEqual(trip.status, .validated)
        XCTAssertEqual(trip.offlinePack.integrity, .unknown)
        XCTAssertTrue(julien.isImported(share))
    }

    func testOnlyTheAuthorDeletesASharedTrip() async throws {
        let (fab, server, _, clock) = await signedInWithGroup()
        _ = await fab.share(sampleTrip())
        let julien = GroupSession(storage: FakeStorage(), now: { clock.now() }, makeBackend: { _ in server })
        julien.configure(url: "https://abc.supabase.co", anonKey: key)
        _ = await julien.signUp(email: "julien@example.com", password: "motdepasse", name: "Julien")
        _ = await julien.joinGroup(code: try XCTUnwrap(fab.currentGroup?.inviteCode))
        await julien.deleteShared(try XCTUnwrap(julien.sharedTrips.first))
        XCTAssertEqual(server.tripCount, 1)
        await fab.deleteShared(try XCTUnwrap(fab.sharedTrips.first))
        XCTAssertEqual(server.tripCount, 0)
        XCTAssertTrue(fab.sharedTrips.isEmpty)
    }

    // MARK: Voice

    func testJoiningTheVoiceRoomUsesTheServerTokenAndTheMicrophoneMode() async {
        let room = FakeVoiceRoom()
        let (session, _, _, _) = await signedInWithGroup(voice: room)
        session.pushToTalk = false
        let ok = await session.joinVoice()
        XCTAssertTrue(ok)
        XCTAssertEqual(room.joined?.url, "wss://moto.livekit.cloud")
        XCTAssertEqual(room.joined?.micOn, true, "open microphone by default")
        XCTAssertTrue(session.voice.isActive)

        await session.leaveVoice()
        session.pushToTalk = true
        _ = await session.joinVoice()
        XCTAssertEqual(room.joined?.micOn, false, "push-to-talk: silent until the button is held")
    }

    func testVoiceOpenedDuringARideClosesWithTheRideButNotOneOpenedBefore() async {
        let room = FakeVoiceRoom()
        let (session, _, _, _) = await signedInWithGroup(voice: room)
        session.rideDidStart(speak: { _ in })
        _ = await session.joinVoice()                          // opened from the riding screen
        session.rideDidEnd()
        await eventually("voice closed with the ride") { !session.voice.isActive }

        _ = await session.joinVoice()                          // opened from the tab, then a ride
        session.rideDidStart(speak: { _ in })
        session.rideDidEnd()
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(session.voice.isActive, "the rider chose to stay in the room")
        await session.leaveVoice()
    }

    func testVoiceAndNavigationShareTheEarsOfTheRider() async {
        let room = FakeVoiceRoom()
        let (session, _, _, _) = await signedInWithGroup(voice: room)
        session.duckVoice(true)
        XCTAssertEqual(room.volume, 0.15, accuracy: 1e-9)
        session.duckVoice(false)
        XCTAssertEqual(room.volume, 1, accuracy: 1e-9)
    }

    func testSigningOutLeavesTheVoiceAndWithdrawsThePosition() async {
        let room = FakeVoiceRoom()
        let (session, server, _, _) = await signedInWithGroup(voice: room)
        _ = await session.joinVoice()
        await session.signOut()
        XCTAssertFalse(session.voice.isActive)
        XCTAssertEqual(server.deletedPositionCount, 1)
        XCTAssertEqual(session.phase, .signedOut)
        XCTAssertTrue(session.groups.isEmpty)
    }

    func testDeletingTheAccountRemovesItsTripsAndThenTheAccount() async {
        let (session, server, storage, _) = await signedInWithGroup()
        _ = await session.share(sampleTrip())
        XCTAssertEqual(server.tripCount, 1)
        let ok = await session.deleteAccount()
        XCTAssertTrue(ok)
        XCTAssertEqual(server.tripCount, 0)
        XCTAssertEqual(server.accountCount, 0)
        XCTAssertNil(storage.tokens)
        XCTAssertEqual(session.phase, .signedOut)
    }
}

// MARK: - Doubles

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var shift: TimeInterval = 0
    var offset: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return shift }
        set { lock.lock(); shift = newValue; lock.unlock() }
    }
    func now() -> Date { Date().addingTimeInterval(offset) }
}

final class FakeStorage: GroupStorage {
    var config: GroupServerConfig?
    var tokens: GroupTokens?
    var displayName = ""
    var currentGroupId: String?
    var sharePosition = false
    var pushToTalk = false
    var lastSeenMessageId = 0
    var importedShareIds: Set<String> = []
}

@MainActor
final class FakeVoiceRoom: VoiceRoom {
    var onChange: (@MainActor (VoiceState) -> Void)?
    var canJoinWithoutPrompt = true
    var joined: (url: String, token: String, micOn: Bool)?
    var volume = 1.0

    func join(url: String, token: String, micOn: Bool) async throws {
        joined = (url, token, micOn)
        onChange?(VoiceState(phase: .connected, micOn: micOn, others: []))
    }

    func leave() async { onChange?(VoiceState()) }
    func setMicrophone(_ on: Bool) async {}
    func setPlaybackVolume(_ volume: Double) { self.volume = volume }
}

/// A server in memory with the same rules as `schema.sql`: members only, 5 minutes of visibility, owner rights.
final class FakeBackend: GroupBackend, @unchecked Sendable {
    private struct Account { let id: String; let password: String; var name: String }

    private let lock = NSLock()
    private let clock: TestClock
    private var accounts: [String: Account] = [:]            // by e-mail
    private var groupsById: [String: GroupInfo] = [:]
    private var members: [String: [String]] = [:]            // group → user ids, in order
    private var names: [String: String] = [:]                // user id → name
    private var positionsByUser: [String: (group: String, position: MemberPosition)] = [:]
    private var chat: [GroupMessage] = []
    private var groupOfMessage: [Int: String] = [:]
    private var shares: [(group: String, share: SharedTrip, file: Data)] = []
    private var tokenOwner: [String: String] = [:]
    private var counter = 0

    var confirmEmail = false
    var offline = false
    var refreshFailure: GroupError?
    var rejectNextToken = false
    private(set) var refreshCount = 0
    private(set) var putCount = 0
    private(set) var lastPut: SharedFix?
    private(set) var deletedPositionCount = 0

    init(clock: TestClock) { self.clock = clock }

    var accountCount: Int { lock.withLock { accounts.count } }
    var tripCount: Int { lock.withLock { shares.count } }
    func memberCount(of group: String) -> Int { lock.withLock { members[group]?.count ?? 0 } }

    // Test helpers
    func addMember(groupId: String, name: String, id: String) {
        lock.withLock {
            members[groupId, default: []].append(id)
            names[id] = name
        }
    }

    func setPosition(groupId: String, userId: String, point: GeoPoint, age: TimeInterval, now: Date) {
        lock.withLock {
            positionsByUser[userId] = (groupId, MemberPosition(userId: userId, point: point, speedKmh: 60, course: 0,
                                                              updatedAt: now.addingTimeInterval(-age)))
        }
    }

    func post(groupId: String, userId: String, kind: GroupMessageKind, body: String, at: Date) {
        lock.withLock {
            counter += 1
            chat.append(GroupMessage(id: counter, userId: userId, kind: kind, body: body, createdAt: at))
            groupOfMessage[counter] = groupId
        }
    }

    // MARK: GroupBackend

    private func issue(_ id: String, email: String) -> GroupTokens {
        counter += 1
        let access = "access-\(id)-\(counter)"
        tokenOwner[access] = id
        return GroupTokens(accessToken: access, refreshToken: "refresh-\(id)", expiresAt: clock.now().addingTimeInterval(3600),
                           userId: id, email: email)
    }

    private func user(_ token: String) throws -> String {
        if offline { throw GroupError.offline }
        if rejectNextToken { rejectNextToken = false; throw GroupError.notSignedIn }
        guard let id = tokenOwner[token] else { throw GroupError.notSignedIn }
        return id
    }

    func signUp(email: String, password: String, displayName: String) async throws -> GroupTokens? {
        try lock.withLock {
            if offline { throw GroupError.offline }
            guard accounts[email] == nil else { throw GroupError.emailTaken }
            counter += 1
            let id = "user-\(counter)"
            accounts[email] = Account(id: id, password: password, name: displayName)
            names[id] = displayName
            return confirmEmail ? nil : issue(id, email: email)
        }
    }

    func signIn(email: String, password: String) async throws -> GroupTokens {
        try lock.withLock {
            if offline { throw GroupError.offline }
            guard let account = accounts[email], account.password == password else { throw GroupError.invalidCredentials }
            return issue(account.id, email: email)
        }
    }

    func refresh(refreshToken: String) async throws -> GroupTokens {
        try await Task.sleep(nanoseconds: 20_000_000)          // long enough for a second caller to arrive
        return try lock.withLock {
            refreshCount += 1
            if offline { throw GroupError.offline }
            if let refreshFailure { throw refreshFailure }
            let id = String(refreshToken.dropFirst("refresh-".count))
            return issue(id, email: accounts.first { $0.value.id == id }?.key ?? "")
        }
    }

    func deleteAccount(token: String) async throws {
        try lock.withLock {
            let id = try user(token)
            accounts = accounts.filter { $0.value.id != id }
            for key in members.keys { members[key]?.removeAll { $0 == id } }
            positionsByUser[id] = nil
        }
    }

    func myGroups(token: String) async throws -> [GroupInfo] {
        try lock.withLock {
            let id = try user(token)
            return groupsById.values.filter { members[$0.id]?.contains(id) == true }.sorted { $0.id < $1.id }
        }
    }

    func createGroup(name: String, token: String) async throws -> GroupInfo {
        try lock.withLock {
            let id = try user(token)
            counter += 1
            let group = GroupInfo(id: "group-\(counter)", name: name, inviteCode: "K7M2QX4P", ownerId: id)
            groupsById[group.id] = group
            members[group.id] = [id]
            return group
        }
    }

    func joinGroup(code: String, token: String) async throws -> GroupInfo {
        try lock.withLock {
            let id = try user(token)
            guard let group = groupsById.values.first(where: { $0.inviteCode == GroupInvite.normalize(code: code) }) else {
                throw GroupError.invalidCode
            }
            if members[group.id]?.contains(id) == false { members[group.id, default: []].append(id) }
            return group
        }
    }

    func leaveGroup(id: String, token: String) async throws {
        try lock.withLock {
            let me = try user(token)
            members[id]?.removeAll { $0 == me }
            if positionsByUser[me]?.group == id { positionsByUser[me] = nil }
            if groupsById[id]?.ownerId == me {
                if let next = members[id]?.first { groupsById[id]?.ownerId = next } else { groupsById[id] = nil }
            }
        }
    }

    func rotateInvite(groupId: String, token: String) async throws -> GroupInfo {
        try lock.withLock {
            let me = try user(token)
            guard var group = groupsById[groupId], group.ownerId == me else { throw GroupError.notAllowed }
            group.inviteCode = "ZZ22ZZ22"
            groupsById[groupId] = group
            return group
        }
    }

    func roster(groupId: String, token: String) async throws -> [GroupMember] {
        try lock.withLock {
            let me = try user(token)
            guard members[groupId]?.contains(me) == true else { return [] }
            let owner = groupsById[groupId]?.ownerId
            return (members[groupId] ?? []).map { GroupMember(id: $0, name: names[$0] ?? "?", isOwner: $0 == owner) }
        }
    }

    func removeMember(groupId: String, userId: String, token: String) async throws {
        try lock.withLock {
            let me = try user(token)
            guard userId == me || groupsById[groupId]?.ownerId == me else { return }      // the rule silently removes nothing
            members[groupId]?.removeAll { $0 == userId }
        }
    }

    func putPosition(groupId: String, userId: String, fix: SharedFix, token: String) async throws {
        try lock.withLock {
            _ = try user(token)
            putCount += 1
            lastPut = fix
            positionsByUser[userId] = (groupId, MemberPosition(userId: userId, point: fix.point, speedKmh: fix.speedKmh,
                                                              course: fix.course, updatedAt: clock.now()))
        }
    }

    func positions(groupId: String, token: String) async throws -> [MemberPosition] {
        try lock.withLock {
            let me = try user(token)
            guard members[groupId]?.contains(me) == true else { return [] }
            return positionsByUser.values.filter { $0.group == groupId }.map(\.position)
                .filter { $0.userId == me || clock.now().timeIntervalSince($0.updatedAt) <= 300 }
        }
    }

    func deletePosition(userId: String, token: String) async throws {
        try lock.withLock {
            _ = try user(token)
            deletedPositionCount += 1
            positionsByUser[userId] = nil
        }
    }

    func messages(groupId: String, after: Int?, limit: Int, token: String) async throws -> [GroupMessage] {
        try lock.withLock {
            let me = try user(token)
            guard members[groupId]?.contains(me) == true else { return [] }
            let all = chat.filter { groupOfMessage[$0.id] == groupId }
            if let after { return Array(all.filter { $0.id > after }.prefix(limit)) }
            return Array(all.suffix(limit))
        }
    }

    func send(groupId: String, kind: GroupMessageKind, body: String, shareId: String?, token: String) async throws {
        try lock.withLock {
            let me = try user(token)
            guard members[groupId]?.contains(me) == true else { throw GroupError.notAllowed }
            counter += 1
            chat.append(GroupMessage(id: counter, userId: me, kind: kind, body: body, shareId: shareId, createdAt: clock.now()))
            groupOfMessage[counter] = groupId
        }
    }

    func sharedTrips(groupId: String, token: String) async throws -> [SharedTrip] {
        try lock.withLock {
            let me = try user(token)
            guard members[groupId]?.contains(me) == true else { return [] }
            return shares.filter { $0.group == groupId }.map(\.share).reversed()
        }
    }

    func shareTrip(groupId: String, name: String, days: Int, distanceKm: Double, file: Data, token: String) async throws -> SharedTrip {
        try lock.withLock {
            let me = try user(token)
            counter += 1
            let share = SharedTrip(id: "share-\(counter)", userId: me, name: name, days: days, distanceKm: distanceKm, createdAt: clock.now())
            shares.append((groupId, share, file))
            return share
        }
    }

    func downloadTrip(_ share: SharedTrip, groupId: String, token: String) async throws -> Data {
        try lock.withLock {
            let me = try user(token)
            guard members[groupId]?.contains(me) == true, let found = shares.first(where: { $0.share.id == share.id }) else {
                throw GroupError.notAllowed
            }
            return found.file
        }
    }

    func deleteSharedTrip(_ share: SharedTrip, groupId: String, token: String) async throws {
        try lock.withLock {
            let me = try user(token)
            shares.removeAll { $0.share.id == share.id && $0.share.userId == me }       // only the author's own
        }
    }

    func voiceAccess(groupId: String, token: String) async throws -> VoiceAccess {
        try lock.withLock {
            _ = try user(token)
            return VoiceAccess(url: "wss://moto.livekit.cloud", token: "livekit-jwt")
        }
    }
}
