import Foundation
import TripCore

/// What the group tab needs from a server (SPEC §13). The views and the session only know this protocol:
/// the hosting (Supabase today) can change without touching them (CLAUDE.md rule 4).
protocol GroupBackend: Sendable {
    // Account
    /// nil = the account exists but the server wants the e-mail confirmed first.
    func signUp(email: String, password: String, displayName: String) async throws -> GroupTokens?
    func signIn(email: String, password: String) async throws -> GroupTokens
    func refresh(refreshToken: String) async throws -> GroupTokens
    func deleteAccount(token: String) async throws

    // Groups
    func myGroups(token: String) async throws -> [GroupInfo]
    func createGroup(name: String, token: String) async throws -> GroupInfo
    func joinGroup(code: String, token: String) async throws -> GroupInfo
    func leaveGroup(id: String, token: String) async throws
    func rotateInvite(groupId: String, token: String) async throws -> GroupInfo
    func roster(groupId: String, token: String) async throws -> [GroupMember]
    func removeMember(groupId: String, userId: String, token: String) async throws

    // Live position (a few seconds old at most: short timeouts, never blocks riding)
    func putPosition(groupId: String, userId: String, fix: SharedFix, token: String) async throws
    func positions(groupId: String, token: String) async throws -> [MemberPosition]
    func deletePosition(userId: String, token: String) async throws

    // Chat
    func messages(groupId: String, after: Int?, limit: Int, token: String) async throws -> [GroupMessage]
    func send(groupId: String, kind: GroupMessageKind, body: String, shareId: String?, token: String) async throws

    // Shared trips
    func sharedTrips(groupId: String, token: String) async throws -> [SharedTrip]
    func shareTrip(groupId: String, name: String, days: Int, distanceKm: Double, file: Data, token: String) async throws -> SharedTrip
    func downloadTrip(_ share: SharedTrip, groupId: String, token: String) async throws -> Data
    func deleteSharedTrip(_ share: SharedTrip, groupId: String, token: String) async throws

    // Voice
    func voiceAccess(groupId: String, token: String) async throws -> VoiceAccess
}

struct GroupTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: String
    var email: String

    /// Refreshed a minute early so a request never leaves with a token about to expire.
    func isFresh(at now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) > 60 }
}

struct GroupInfo: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var inviteCode: String
    var ownerId: String
}

/// The rider's own position as sent to the group.
struct SharedFix: Equatable, Sendable {
    var point: GeoPoint
    var speedKmh: Double?
    var course: Double?
}

struct VoiceAccess: Equatable, Sendable {
    let url: String
    let token: String
}

enum GroupError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case emailNotConfirmed
    case invalidCredentials
    case emailTaken
    case weakPassword
    case invalidCode
    case groupFull
    case notAllowed
    case voiceUnavailable
    case offline
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Serveur du groupe non configuré."
        case .notSignedIn: "Connecte-toi pour utiliser le groupe."
        case .emailNotConfirmed: "Adresse e-mail pas encore confirmée : ouvre le lien reçu par e-mail."
        case .invalidCredentials: "E-mail ou mot de passe incorrect."
        case .emailTaken: "Un compte existe déjà avec cette adresse : connecte-toi."
        case .weakPassword: "Mot de passe trop faible (8 caractères minimum)."
        case .invalidCode: "Code d'invitation inconnu."
        case .groupFull: "Ce groupe est complet (10 motards)."
        case .notAllowed: "Action réservée au créateur du groupe."
        case .voiceUnavailable: "Voix non configurée sur le serveur."
        case .offline: "Pas de réseau."
        case .server(let code, let text): "Serveur : erreur \(code) \(text.prefix(160))"
        }
    }
}
