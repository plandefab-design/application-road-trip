import Foundation

/// A rider heard in the group's voice room.
struct VoiceParticipant: Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var speaking: Bool
}

struct VoiceState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case off, connecting, connected, reconnecting
        case failed(String)
    }

    var phase: Phase = .off
    var micOn = false
    var others: [VoiceParticipant] = []

    /// In the room, or on the way (network cuts included): the voice must be kept alive, not restarted.
    var isActive: Bool {
        switch phase {
        case .connecting, .connected, .reconnecting: true
        case .off, .failed: false
        }
    }
}

/// The group's voice room (WebRTC). Views and the session only know this protocol; the LiveKit adapter is the one
/// place that talks to the SDK (CLAUDE.md rule 4).
@MainActor
protocol VoiceRoom: AnyObject {
    var onChange: (@MainActor (VoiceState) -> Void)? { get set }
    /// true when joining will not show a permission dialog (never ask while riding, rule 9).
    var canJoinWithoutPrompt: Bool { get }
    func join(url: String, token: String, micOn: Bool) async throws
    func leave() async
    func setMicrophone(_ on: Bool) async
    /// 0…1: the others' voices are lowered while a navigation instruction is spoken.
    func setPlaybackVolume(_ volume: Double)
}

enum VoiceRoomError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Micro refusé : autorise-le dans Réglages › Moto Road › Micro."
        }
    }
}
