import Foundation

/// A person of a riding group (the server profile, not the phone).
public struct GroupMember: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var isOwner: Bool

    public init(id: String, name: String, isOwner: Bool = false) {
        self.id = id
        self.name = name
        self.isOwner = isOwner
    }
}

/// Last position shared by a member while riding (one per member, replaced every few seconds).
public struct MemberPosition: Codable, Hashable, Sendable {
    public let userId: String
    public var point: GeoPoint
    public var speedKmh: Double?
    public var course: Double?
    public var updatedAt: Date

    public init(userId: String, point: GeoPoint, speedKmh: Double? = nil, course: Double? = nil, updatedAt: Date) {
        self.userId = userId
        self.point = point
        self.speedKmh = speedKmh
        self.course = course
        self.updatedAt = updatedAt
    }
}

public enum GroupMessageKind: String, Codable, Sendable {
    /// Typed message (never while riding).
    case text
    /// One of the `QuickReply` phrases, sent with one tap.
    case quick
    /// A trip shared with the group (`shareId` points to it).
    case trip
}

public struct GroupMessage: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let userId: String
    public var kind: GroupMessageKind
    public var body: String
    /// For `.trip`: id of the shared trip.
    public var shareId: String?
    public var createdAt: Date

    public init(id: Int, userId: String, kind: GroupMessageKind, body: String, shareId: String? = nil, createdAt: Date) {
        self.id = id
        self.userId = userId
        self.kind = kind
        self.body = body
        self.shareId = shareId
        self.createdAt = createdAt
    }
}

/// A trip a member put at the group's disposal (the trip itself is downloaded on demand).
public struct SharedTrip: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let userId: String
    public var name: String
    public var days: Int
    public var distanceKm: Double
    public var createdAt: Date

    public init(id: String, userId: String, name: String, days: Int, distanceKm: Double, createdAt: Date) {
        self.id = id
        self.userId = userId
        self.name = name
        self.days = days
        self.distanceKm = distanceKm
        self.createdAt = createdAt
    }
}

/// One-tap messages for the road: big buttons, no typing (CLAUDE.md rule 9).
public enum QuickReply: String, CaseIterable, Sendable {
    case arriving, pause, fuel, ok, careful, stopped, behind, waitForMe

    public var text: String {
        switch self {
        case .arriving: "J'arrive"
        case .pause: "On fait une pause ?"
        case .fuel: "Je dois faire le plein"
        case .ok: "OK"
        case .careful: "Attention, danger devant"
        case .stopped: "Je suis arrêté"
        case .behind: "Je suis derrière, ralentissez un peu"
        case .waitForMe: "Attendez-moi"
        }
    }

    public var icon: String {
        switch self {
        case .arriving: "figure.wave"
        case .pause: "cup.and.saucer.fill"
        case .fuel: "fuelpump.fill"
        case .ok: "hand.thumbsup.fill"
        case .careful: "exclamationmark.triangle.fill"
        case .stopped: "parkingsign"
        case .behind: "tortoise.fill"
        case .waitForMe: "hand.raised.fill"
        }
    }
}
