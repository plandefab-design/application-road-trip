import Foundation
import TripCore
#if canImport(Combine)
import Combine
#endif

/// Where the group server is (Réglages › Groupe, or an invitation link). The key is the public one.
struct GroupServerConfig: Codable, Equatable, Sendable {
    var url: String
    var anonKey: String
}

/// What the session keeps between launches: tokens and server in the Keychain, preferences in UserDefaults.
protocol GroupStorage: AnyObject {
    var config: GroupServerConfig? { get set }
    var tokens: GroupTokens? { get set }
    var displayName: String { get set }
    var currentGroupId: String? { get set }
    /// Share my position with the group while I ride (off until the rider turns it on).
    var sharePosition: Bool { get set }
    /// Voice: speak only while the button is held (instead of an open microphone).
    var pushToTalk: Bool { get set }
    var lastSeenMessageId: Int { get set }
    var importedShareIds: Set<String> { get set }
}

/// Everything the « Groupe » tab and the riding screens need: the account, the group, the friends' positions,
/// the chat, the shared trips and the voice room.
///
/// Riding never depends on it (CLAUDE.md rule 1): every call has a short time-out, a failure only changes the
/// discreet status line, and nothing here is awaited by the navigation.
@MainActor
final class GroupSession: ObservableObject {
    enum Phase { case notConfigured, signedOut, signedIn }
    /// Who needs fresh data: the tab being looked at, or a ride in progress (4 s), else a slow check (30 s).
    enum Watch: Hashable { case groupTab, riding }
    enum Connection { case unknown, online, offline }

    @Published private(set) var config: GroupServerConfig?
    @Published private(set) var tokens: GroupTokens?
    @Published private(set) var groups: [GroupInfo] = []
    @Published private(set) var currentGroupId: String?
    @Published private(set) var members: [GroupMember] = []
    @Published private(set) var positions: [MemberPosition] = []
    @Published private(set) var friendPins: [FriendPin] = []
    @Published private(set) var messages: [GroupMessage] = []
    @Published private(set) var sharedTrips: [SharedTrip] = []
    @Published private(set) var unread = 0
    @Published private(set) var importedShareIds: Set<String> = []
    @Published private(set) var connection: Connection = .unknown
    @Published private(set) var voice = VoiceState()
    @Published private(set) var busy = false
    @Published var lastError: String?
    /// Information, not a failure (« confirme ton e-mail »).
    @Published var notice: String?
    /// An invitation received by link, waiting for the rider to sign in or accept.
    @Published private(set) var pendingInvite: String?
    @Published var sharePosition: Bool { didSet { storage.sharePosition = sharePosition; if !sharePosition { withdrawPosition() } } }
    @Published var pushToTalk: Bool { didSet { storage.pushToTalk = pushToTalk } }

    let voiceRoom: VoiceRoom?
    private let storage: GroupStorage
    private let makeBackend: (GroupServerConfig) -> GroupBackend?
    private let now: () -> Date
    private var backend: GroupBackend?
    private var storedName: String

    private var watchers: Set<Watch> = []
    private var appActive = false
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<GroupTokens, Error>?
    private var lastMessageId = 0
    private var firstMessageLoad = true

    // Riding
    private var riding = false
    private var speaker: ((String) -> Void)?
    private var throttle = PositionThrottle()
    private var sendingPosition = false
    private var lastOwnPoint: GeoPoint?
    /// The voice was opened from the riding screen: it closes with the ride (no microphone left open at the stop).
    private var voiceStartedInRide = false

    init(storage: GroupStorage, voiceRoom: VoiceRoom? = nil, now: @escaping () -> Date = Date.init,
         makeBackend: @escaping (GroupServerConfig) -> GroupBackend? = { SupabaseBackend(urlString: $0.url, anonKey: $0.anonKey) }) {
        self.storage = storage
        self.voiceRoom = voiceRoom
        self.now = now
        self.makeBackend = makeBackend
        config = storage.config
        tokens = storage.tokens
        currentGroupId = storage.currentGroupId
        storedName = storage.displayName
        sharePosition = storage.sharePosition
        pushToTalk = storage.pushToTalk
        importedShareIds = storage.importedShareIds
        backend = storage.config.flatMap(makeBackend)
        voiceRoom?.onChange = { [weak self] state in
            self?.voice = state
            self?.updatePolling()
        }
    }

    // MARK: State

    var phase: Phase {
        if config == nil { return .notConfigured }
        return tokens == nil ? .signedOut : .signedIn
    }

    var userId: String? { tokens?.userId }
    var myName: String { members.first { $0.id == userId }?.name ?? storedName }
    var email: String { tokens?.email ?? "" }
    var currentGroup: GroupInfo? { groups.first { $0.id == currentGroupId } }
    var isOwner: Bool { currentGroup?.ownerId == userId }
    var isRiding: Bool { riding }

    /// The link to send a friend: it carries the server and the code, one tap sets everything up.
    var inviteURL: URL? {
        guard let config, let group = currentGroup, let server = URL(string: config.url) else { return nil }
        return GroupInvite(server: server, publicKey: config.anonKey, code: group.inviteCode).url
    }

    func isImported(_ share: SharedTrip) -> Bool { importedShareIds.contains(share.id) }
    func name(of userId: String) -> String { members.first { $0.id == userId }?.name ?? "Un ami" }

    // MARK: Server and invitations

    @discardableResult
    func configure(url: String, anonKey: String) -> Bool {
        let candidate = GroupServerConfig(url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                                          anonKey: anonKey.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let made = makeBackend(candidate) else {
            lastError = "Adresse du serveur ou clé invalide (https://… et clé publique)."
            return false
        }
        if candidate != config { forgetAccount() }
        config = candidate
        storage.config = candidate
        backend = made
        lastError = nil
        return true
    }

    /// An invitation link was opened: the server is set up, the code waits for the account.
    func receive(_ invite: GroupInvite) async {
        guard configure(url: invite.server.absoluteString, anonKey: invite.publicKey) else { return }
        pendingInvite = invite.code
        if phase == .signedIn { await acceptPendingInvite() }
    }

    func acceptPendingInvite() async {
        guard let code = pendingInvite else { return }
        if await joinGroup(code: code) { pendingInvite = nil }
    }

    func dismissPendingInvite() { pendingInvite = nil }

    // MARK: Account

    /// - Returns: true when signed in; false with `lastError` or `notice` set.
    @discardableResult
    func signUp(email: String, password: String, name: String) async -> Bool {
        guard let backend else { lastError = GroupError.notConfigured.errorDescription; return false }
        let clean = GroupRules.cleanName(name)
        guard GroupRules.isValidName(clean) else { lastError = "Pseudo de 2 à 20 caractères."; return false }
        guard GroupRules.isValidEmail(email) else { lastError = "Adresse e-mail invalide."; return false }
        guard GroupRules.isValidPassword(password) else { lastError = GroupError.weakPassword.errorDescription; return false }
        busy = true
        defer { busy = false }
        do {
            let mail = email.trimmingCharacters(in: .whitespaces)
            guard let session = try await backend.signUp(email: mail, password: password, displayName: clean) else {
                notice = "Compte créé. Ouvre le lien reçu par e-mail, puis connecte-toi."
                lastError = nil
                return false
            }
            storedName = clean
            storage.displayName = clean
            await adopt(session)
            return true
        } catch {
            lastError = describe(error)
            return false
        }
    }

    @discardableResult
    func signIn(email: String, password: String) async -> Bool {
        guard let backend else { lastError = GroupError.notConfigured.errorDescription; return false }
        busy = true
        defer { busy = false }
        do {
            await adopt(try await backend.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password))
            return true
        } catch {
            lastError = describe(error)
            return false
        }
    }

    private func adopt(_ session: GroupTokens) async {
        tokens = session
        storage.tokens = session
        lastError = nil
        notice = nil
        await refreshGroups()
        if pendingInvite != nil { await acceptPendingInvite() }
    }

    func signOut() async {
        await leaveVoice()
        await withdrawPositionNow()
        forgetAccount()
    }

    /// Deletes the account and everything it shared (positions, messages, trips) on the server.
    @discardableResult
    func deleteAccount() async -> Bool {
        busy = true
        defer { busy = false }
        await leaveVoice()
        do {
            for group in groups {
                for share in (try? await run { try await $0.sharedTrips(groupId: group.id, token: $1) }) ?? [] where share.userId == userId {
                    try? await run { try await $0.deleteSharedTrip(share, groupId: group.id, token: $1) }
                }
            }
            try await run { try await $0.deleteAccount(token: $1) }
            forgetAccount()
            return true
        } catch {
            lastError = describe(error)
            return false
        }
    }

    /// Local sign-out: keeps the server, forgets the person.
    private func forgetAccount() {
        tokens = nil
        storage.tokens = nil
        storage.currentGroupId = nil
        storage.lastSeenMessageId = 0
        storedName = ""
        storage.displayName = ""
        resetGroupState()
        groups = []
        currentGroupId = nil
        updatePolling()
    }

    private func resetGroupState() {
        members = []
        positions = []
        friendPins = []
        messages = []
        sharedTrips = []
        unread = 0
        lastMessageId = 0
        firstMessageLoad = true
    }

    // MARK: Tokens

    /// A valid access token: refreshed once even when several calls ask at the same time. An unreachable server
    /// keeps the account (offline); a refused refresh signs out.
    private func validToken() async throws -> String {
        guard let current = tokens else { throw GroupError.notSignedIn }
        if current.isFresh(at: now()) { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let backend else { throw GroupError.notConfigured }
        let refreshToken = current.refreshToken
        let task = Task { try await backend.refresh(refreshToken: refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            storage.tokens = fresh
            return fresh.accessToken
        } catch GroupError.offline {
            throw GroupError.offline
        } catch {
            forgetAccount()
            lastError = "Session expirée : reconnecte-toi."
            throw GroupError.notSignedIn
        }
    }

    /// Runs a server call with a valid token; a token the server still refuses is renewed once.
    @discardableResult
    private func run<T>(_ operation: (GroupBackend, String) async throws -> T) async throws -> T {
        guard let backend else { throw GroupError.notConfigured }
        let token = try await validToken()
        do {
            return try await operation(backend, token)
        } catch GroupError.notSignedIn {
            if var stale = tokens {
                stale.expiresAt = .distantPast
                tokens = stale
            }
            return try await operation(backend, try await validToken())
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? GroupError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Groups

    func refreshGroups() async {
        do {
            groups = try await run { try await $0.myGroups(token: $1) }
            connection = .online
            if currentGroup == nil { currentGroupId = groups.first?.id }
            storage.currentGroupId = currentGroupId
            await reloadCurrent()
        } catch {
            noteFailure(error)
        }
        updatePolling()
    }

    @discardableResult
    func createGroup(name: String) async -> Bool {
        let clean = GroupRules.cleanName(name)
        guard (2...40).contains(clean.count) else { lastError = "Nom du groupe de 2 à 40 caractères."; return false }
        return await enter { try await self.run { try await $0.createGroup(name: clean, token: $1) } }
    }

    @discardableResult
    func joinGroup(code: String) async -> Bool {
        guard GroupInvite.isValid(code: code) else { lastError = GroupError.invalidCode.errorDescription; return false }
        return await enter { try await self.run { try await $0.joinGroup(code: code, token: $1) } }
    }

    private func enter(_ action: () async throws -> GroupInfo) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let group = try await action()
            if !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
            lastError = nil
            await select(group.id)
            return true
        } catch {
            lastError = describe(error)
            return false
        }
    }

    func select(_ id: String) async {
        guard id != currentGroupId else { return }
        if currentGroupId != nil {          // leaving a group: nothing to withdraw when the first one is chosen
            await leaveVoice()
            await withdrawPositionNow()
        }
        resetGroupState()
        currentGroupId = id
        storage.currentGroupId = id
        storage.lastSeenMessageId = 0
        await reloadCurrent()
        updatePolling()
    }

    func leaveCurrentGroup() async {
        guard let group = currentGroup else { return }
        busy = true
        defer { busy = false }
        await leaveVoice()
        await withdrawPositionNow()
        do {
            try await run { try await $0.leaveGroup(id: group.id, token: $1) }
            groups.removeAll { $0.id == group.id }
            resetGroupState()
            currentGroupId = groups.first?.id
            storage.currentGroupId = currentGroupId
            storage.lastSeenMessageId = 0
            await reloadCurrent()
            updatePolling()
        } catch {
            lastError = describe(error)
        }
    }

    func rotateInvite() async {
        guard let group = currentGroup else { return }
        do {
            let updated = try await run { try await $0.rotateInvite(groupId: group.id, token: $1) }
            if let i = groups.firstIndex(where: { $0.id == updated.id }) { groups[i] = updated }
        } catch {
            lastError = describe(error)
        }
    }

    func remove(_ member: GroupMember) async {
        guard let group = currentGroup, isOwner, member.id != userId else { return }
        do {
            try await run { try await $0.removeMember(groupId: group.id, userId: member.id, token: $1) }
            members.removeAll { $0.id == member.id }
            positions.removeAll { $0.userId == member.id }
            updatePins()
        } catch {
            lastError = describe(error)
        }
    }

    // MARK: Loading and polling

    /// Roster, trips, the last messages and positions of the current group.
    func reloadCurrent() async {
        guard let gid = currentGroupId else { return }
        do {
            members = try await run { try await $0.roster(groupId: gid, token: $1) }
            sharedTrips = (try? await run { try await $0.sharedTrips(groupId: gid, token: $1) }) ?? sharedTrips
            let latest = try await run { try await $0.messages(groupId: gid, after: nil, limit: 50, token: $1) }
            firstMessageLoad = true
            messages = []
            lastMessageId = 0
            ingest(latest)
            let seen = storage.lastSeenMessageId
            unread = watchers.contains(.groupTab) ? 0 : latest.filter { $0.id > seen && $0.userId != userId }.count
            positions = try await run { try await $0.positions(groupId: gid, token: $1) }
            updatePins()
            connection = .online
        } catch {
            noteFailure(error)
        }
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        updatePolling()
    }

    func watch(_ who: Watch, _ on: Bool) {
        if on { watchers.insert(who) } else { watchers.remove(who) }
        if who == .groupTab, on { markRead() }
        updatePolling()
    }

    private func updatePolling() {
        let wanted = phase == .signedIn && currentGroupId != nil && (appActive || riding || voice.isActive)
        if wanted, pollTask == nil {
            pollTask = Task { await self.pollLoop() }
        } else if !wanted, let task = pollTask {
            task.cancel()
            pollTask = nil
        }
    }

    private func pollLoop() async {
        var tick = 0
        while !Task.isCancelled {
            await pollOnce(full: tick % 8 == 0 && tick > 0)
            tick += 1
            try? await Task.sleep(for: .seconds(watchers.isEmpty ? 30 : 4))
        }
    }

    /// One round: positions and new messages (and, now and then, the roster and the trips).
    func pollOnce(full: Bool = false) async {
        guard let gid = currentGroupId, phase == .signedIn else { return }
        do {
            positions = try await run { try await $0.positions(groupId: gid, token: $1) }
            updatePins()
            let fresh = try await run { try await $0.messages(groupId: gid, after: lastMessageId, limit: 100, token: $1) }
            ingest(fresh)
            connection = .online
            if full {
                members = try await run { try await $0.roster(groupId: gid, token: $1) }
                sharedTrips = try await run { try await $0.sharedTrips(groupId: gid, token: $1) }
            }
        } catch {
            noteFailure(error)
        }
    }

    private func noteFailure(_ error: Error) {
        if case GroupError.offline = error { connection = .offline; return }
        if case GroupError.notSignedIn = error { return }          // already signed out by validToken
        connection = .offline
        lastError = describe(error)
    }

    private func updatePins() {
        friendPins = FriendTracker.pins(positions: positions, members: members, me: userId, from: lastOwnPoint, now: now())
    }

    // MARK: Chat

    private func ingest(_ incoming: [GroupMessage]) {
        let known = Set(messages.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }.sorted { $0.id < $1.id }
        guard !fresh.isEmpty else { firstMessageLoad = false; return }
        messages += fresh
        lastMessageId = max(lastMessageId, fresh.last?.id ?? 0)
        let wasFirst = firstMessageLoad
        firstMessageLoad = false
        if watchers.contains(.groupTab) {
            markRead()
        } else if !wasFirst {
            unread += fresh.filter { $0.userId != userId }.count
        }
        guard !wasFirst, let speaker else { return }
        for message in fresh {
            if let text = GroupSpeech.announcement(for: message, author: name(of: message.userId), me: userId, now: now()) {
                speaker(text)
            }
        }
    }

    func markRead() {
        unread = 0
        storage.lastSeenMessageId = lastMessageId
    }

    @discardableResult
    func sendQuick(_ reply: QuickReply) async -> Bool { await post(.quick, reply.text) }

    @discardableResult
    func sendText(_ text: String) async -> Bool {
        let clean = GroupRules.cleanMessage(text)
        guard !clean.isEmpty else { return false }
        return await post(.text, clean)
    }

    private func post(_ kind: GroupMessageKind, _ body: String, shareId: String? = nil) async -> Bool {
        guard let gid = currentGroupId else { return false }
        do {
            try await run { try await $0.send(groupId: gid, kind: kind, body: body, shareId: shareId, token: $1) }
            connection = .online
            await pollOnce()
            return true
        } catch {
            noteFailure(error)
            return false
        }
    }

    // MARK: Shared trips

    @discardableResult
    func share(_ trip: Trip) async -> Bool {
        guard let gid = currentGroupId else { return false }
        busy = true
        defer { busy = false }
        do {
            let file = try TripCodec.encode(trip)
            guard file.count <= SharedTripRules.maxFileBytes else {
                lastError = "Ce trip est trop volumineux pour être partagé (20 Mo maximum)."
                return false
            }
            let summary = SharedTripRules.summary(of: trip)
            let created = try await run {
                try await $0.shareTrip(groupId: gid, name: trip.name, days: summary.days, distanceKm: summary.distanceKm,
                                       file: file, token: $1)
            }
            sharedTrips.insert(created, at: 0)
            _ = await post(.trip, trip.name, shareId: created.id)
            lastError = nil
            return true
        } catch {
            lastError = describe(error)
            return false
        }
    }

    /// The friend's trip as a copy of mine to save in the trip store; nil with `lastError` set on failure.
    func importShared(_ share: SharedTrip) async -> Trip? {
        guard let gid = currentGroupId else { return nil }
        busy = true
        defer { busy = false }
        do {
            let data = try await run { try await $0.downloadTrip(share, groupId: gid, token: $1) }
            let copy = SharedTripRules.prepareForImport(try TripCodec.decode(data))
            importedShareIds.insert(share.id)
            storage.importedShareIds = importedShareIds
            lastError = nil
            return copy
        } catch {
            lastError = (error as? GroupError)?.errorDescription ?? "Trip illisible : \(error.localizedDescription)"
            return nil
        }
    }

    func deleteShared(_ share: SharedTrip) async {
        guard let gid = currentGroupId, share.userId == userId else { return }
        do {
            try await run { try await $0.deleteSharedTrip(share, groupId: gid, token: $1) }
            sharedTrips.removeAll { $0.id == share.id }
        } catch {
            lastError = describe(error)
        }
    }

    // MARK: Riding

    /// A ride starts: positions go out (if sharing is on) and incoming messages are read aloud through `speak`.
    func rideDidStart(speak: @escaping (String) -> Void) {
        riding = true
        speaker = speak
        throttle.reset()
        watchers.insert(.riding)
        updatePolling()
    }

    func rideDidEnd() {
        riding = false
        speaker = nil
        watchers.remove(.riding)
        lastOwnPoint = nil
        withdrawPosition()
        if voiceStartedInRide { Task { await leaveVoice() } }
        updatePolling()
    }

    /// Every GPS fix of the riding screens passes here; the throttle decides what is sent. Never waits.
    func reportFix(_ point: GeoPoint, speedKmh: Double?, course: Double?) {
        lastOwnPoint = point
        guard riding, sharePosition, let gid = currentGroupId, let me = userId else { return }
        guard throttle.shouldSend(point: point, speedKmh: speedKmh, at: now()), !sendingPosition else { return }
        sendingPosition = true
        let fix = SharedFix(point: point, speedKmh: speedKmh.map { max(0, $0) }, course: course.flatMap { $0 >= 0 ? $0 : nil })
        Task {
            defer { sendingPosition = false }
            do {
                try await run { try await $0.putPosition(groupId: gid, userId: me, fix: fix, token: $1) }
                connection = .online
            } catch {
                noteFailure(error)
            }
        }
    }

    /// The rider's position leaves the server (end of the ride, sharing switched off, sign-out).
    private func withdrawPosition() {
        throttle.reset()
        Task { await withdrawPositionNow() }
    }

    private func withdrawPositionNow() async {
        guard let me = userId, tokens != nil else { return }
        _ = try? await run { try await $0.deletePosition(userId: me, token: $1) }
    }

    // MARK: Voice

    var canJoinVoiceWithoutPrompt: Bool { voiceRoom?.canJoinWithoutPrompt ?? false }

    @discardableResult
    func joinVoice() async -> Bool {
        guard let voiceRoom, let gid = currentGroupId, !voice.isActive else { return voice.isActive }
        do {
            let access = try await run { try await $0.voiceAccess(groupId: gid, token: $1) }
            try await voiceRoom.join(url: access.url, token: access.token, micOn: !pushToTalk)
            voiceStartedInRide = riding
            lastError = nil
            return true
        } catch {
            lastError = describe(error)
            return false
        }
    }

    func leaveVoice() async {
        voiceStartedInRide = false
        await voiceRoom?.leave()
    }

    func setMicrophone(_ on: Bool) async {
        await voiceRoom?.setMicrophone(on)
    }

    /// Navigation instructions come first: the friends' voices are lowered while one is spoken.
    func duckVoice(_ ducked: Bool) {
        voiceRoom?.setPlaybackVolume(ducked ? 0.15 : 1)
    }
}
