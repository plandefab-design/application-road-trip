import Foundation

/// When to send the rider's position to the group: often enough to follow a bike, rarely enough to spare the
/// battery and the data plan. Moving: every 4 s; nearly stopped: every 20 s; any 60 m jump goes out at once.
public struct PositionThrottle: Sendable {
    public static let movingInterval: TimeInterval = 4
    public static let stoppedInterval: TimeInterval = 20
    public static let jumpMeters = 60.0
    public static let stoppedSpeedKmh = 3.0

    private var lastPoint: GeoPoint?
    private var lastSent: Date?

    public init() {}

    /// true when this fix must be sent; the throttle then remembers it as the last one sent.
    public mutating func shouldSend(point: GeoPoint, speedKmh: Double?, at now: Date) -> Bool {
        guard point.isValid else { return false }
        guard let lastPoint, let lastSent else {
            remember(point, now)
            return true
        }
        let elapsed = now.timeIntervalSince(lastSent)
        let interval = (speedKmh ?? 0) < Self.stoppedSpeedKmh ? Self.stoppedInterval : Self.movingInterval
        if elapsed >= interval || Geo.distance(lastPoint, point) >= Self.jumpMeters {
            remember(point, now)
            return true
        }
        return false
    }

    /// Forgets the last send (sharing stopped and restarted: the next fix goes out at once).
    public mutating func reset() {
        lastPoint = nil
        lastSent = nil
    }

    private mutating func remember(_ point: GeoPoint, _ now: Date) {
        lastPoint = point
        lastSent = now
    }
}

/// A friend as drawn on the riding map and listed in the group.
public struct FriendPin: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let point: GeoPoint
    public let speedKmh: Double?
    /// Metres and compass bearing from the rider, when the rider's position is known.
    public let distance: Double?
    public let bearing: Double?
    public let age: TimeInterval
    /// No news for 30 s: shown greyed (tunnel, dead zone) instead of vanishing.
    public let isStale: Bool
}

public enum FriendTracker {
    /// Positions older than this are not shown at all (the server drops them too).
    public static let maxAge: TimeInterval = 300
    public static let staleAfter: TimeInterval = 30

    /// The friends to draw: everyone but `me`, with a known name, seen in the last 5 minutes, nearest first.
    public static func pins(positions: [MemberPosition], members: [GroupMember], me: String?, from rider: GeoPoint?,
                            now: Date) -> [FriendPin] {
        let names = Dictionary(members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let pins: [FriendPin] = positions.compactMap { p in
            guard p.userId != me, let name = names[p.userId], p.point.isValid else { return nil }
            let age = max(0, now.timeIntervalSince(p.updatedAt))
            guard age <= maxAge else { return nil }
            return FriendPin(id: p.userId, name: name, point: p.point, speedKmh: p.speedKmh,
                             distance: rider.map { Geo.distance($0, p.point) },
                             bearing: rider.map { Geo.bearing($0, p.point) },
                             age: age, isStale: age > staleAfter)
        }
        return pins.sorted {
            let a = $0.distance ?? .infinity, b = $1.distance ?? .infinity
            return a != b ? a < b : $0.name < $1.name
        }
    }

    /// Which side of the rider's course a friend is on, to tell friends apart at a glance.
    public static func relativeSide(bearing: Double, course: Double) -> RelativeSide {
        let delta = Geo.angleDelta(course, bearing)
        if abs(delta) <= 45 { return .ahead }
        if abs(delta) >= 135 { return .behind }
        return delta > 0 ? .right : .left
    }

    public enum RelativeSide: Sendable { case ahead, behind, left, right }
}

/// What is read aloud to a rider (never his own messages, never a stale one).
public enum GroupSpeech {
    public static let maxMessageAge: TimeInterval = 60
    public static let maxSpokenLength = 140

    public static func announcement(for message: GroupMessage, author: String, me: String?, now: Date) -> String? {
        guard message.userId != me, now.timeIntervalSince(message.createdAt) <= maxMessageAge else { return nil }
        switch message.kind {
        case .text, .quick:
            let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let text = body.count > maxSpokenLength ? String(body.prefix(maxSpokenLength)) + "…" : body
            return "\(author) : \(text)"
        case .trip:
            return "\(author) a partagé un trip : \(message.body)"
        }
    }
}

/// Rules shared by the sign-up form and its tests.
public enum GroupRules {
    public static let displayNameRange = 2...20
    public static let minPasswordLength = 8
    public static let maxMessageLength = 500

    public static func cleanName(_ raw: String) -> String {
        raw.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isValidName(_ raw: String) -> Bool {
        displayNameRange.contains(cleanName(raw).count)
    }

    public static func isValidEmail(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !s.contains(" ") else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
    }

    public static func isValidPassword(_ raw: String) -> Bool { raw.count >= minPasswordLength }

    public static func cleanMessage(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > maxMessageLength ? String(s.prefix(maxMessageLength)) : s
    }
}

/// Invitation link `motoroad://join?u=<server>&k=<public key>&c=<code>`: one tap on a friend's phone sets up the
/// server, then offers to create the account and join the group. The key is the public (anon) one: the data are
/// protected by the server's row rules, not by hiding it.
public struct GroupInvite: Equatable, Sendable {
    public static let scheme = "motoroad"
    /// Without 0/O/1/I/L: readable over the phone.
    public static let codeAlphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    public static let codeLength = 8

    public var server: URL
    public var publicKey: String
    public var code: String

    public init(server: URL, publicKey: String, code: String) {
        self.server = server
        self.publicKey = publicKey
        self.code = code
    }

    public static func normalize(code raw: String) -> String {
        String(raw.uppercased().filter { $0 != " " && $0 != "-" })
    }

    public static func isValid(code raw: String) -> Bool {
        let c = normalize(code: raw)
        return c.count == codeLength && c.allSatisfy { codeAlphabet.contains($0) }
    }

    public var url: URL? {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "join"
        c.queryItems = [URLQueryItem(name: "u", value: server.absoluteString),
                        URLQueryItem(name: "k", value: publicKey),
                        URLQueryItem(name: "c", value: code)]
        return c.url
    }

    /// The invitation hidden in a pasted message (« Rejoins mon groupe : motoroad://join?… Merci ! »): messaging apps
    /// do not always make a custom link tappable, so the app also reads it from the clipboard.
    public static func find(in text: String) -> GroupInvite? {
        var rest = Substring(text)
        while let found = rest.range(of: "\(scheme)://", options: .caseInsensitive) {
            let tail = rest[found.lowerBound...]
            let token = tail.prefix { !$0.isWhitespace && !"\"<>".contains($0) }
            let link = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)»”"))
            if let url = URL(string: link), let invite = parse(url) { return invite }
            rest = tail.dropFirst(scheme.count)
        }
        return nil
    }

    /// nil when the link is not a complete, well-formed invitation.
    public static func parse(_ url: URL) -> GroupInvite? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let u = value("u"), let server = URL(string: u), server.scheme == "https", server.host != nil,
              let k = value("k"), !k.isEmpty, let c = value("c"), isValid(code: c) else { return nil }
        return GroupInvite(server: server, publicKey: k, code: normalize(code: c))
    }
}

/// Server timestamps (« 2026-10-04T12:34:56.789012+00:00 ») and the ones we send.
public enum GroupDates {
    public static func parse(_ text: String) -> Date? {
        var base = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let after = text[text.index(after: dot)...]
            let digits = after.prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            base = String(text[..<dot]) + String(after.dropFirst(digits.count))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: base).map { $0.addingTimeInterval(fraction) }
    }

    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
