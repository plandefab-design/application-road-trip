import AVFoundation
import LiveKit

/// While the voice room is open, LiveKit owns the audio session (play and record, Bluetooth headset): the spoken
/// guidance must not reconfigure or deactivate it, only speak through it.
@MainActor
enum SharedAudio {
    static var roomOpen = false
}

/// The group's voice room on LiveKit (WebRTC). The only file that talks to the SDK (CLAUDE.md rule 4).
///
/// The rider's helmet intercom is a Bluetooth headset for the phone: microphone and speakers go through the system
/// audio route, nothing to select here. Background audio (UIBackgroundModes: audio) keeps the room alive with the
/// screen locked.
@MainActor
final class LiveKitVoiceRoom: NSObject, VoiceRoom, RoomDelegate {
    var onChange: (@MainActor (VoiceState) -> Void)?
    private(set) var state = VoiceState() {
        didSet { if state != oldValue { onChange?(state) } }
    }

    private var room: Room?
    private var volume = 1.0

    var canJoinWithoutPrompt: Bool { AVAudioApplication.shared.recordPermission == .granted }

    func join(url: String, token: String, micOn: Bool) async throws {
        guard !state.isActive else { return }
        guard await Self.microphoneAllowed() else { throw VoiceRoomError.microphoneDenied }
        state.phase = .connecting
        SharedAudio.roomOpen = true
        let room = Room(delegate: self)
        self.room = room
        do {
            try await room.connect(url: url, token: token)
            try await room.localParticipant.setMicrophone(enabled: micOn)
            guard self.room === room else { await room.disconnect(); return }       // left while connecting
            state.micOn = micOn
            state.phase = .connected
            refreshParticipants()
            applyVolume()
        } catch {
            if self.room === room { self.room = nil }
            SharedAudio.roomOpen = false
            await room.disconnect()
            state = VoiceState(phase: .failed(error.localizedDescription))
            throw error
        }
    }

    func leave() async {
        let closing = room
        room = nil
        SharedAudio.roomOpen = false
        state = VoiceState()
        await closing?.disconnect()
    }

    func setMicrophone(_ on: Bool) async {
        guard let room, state.isActive else { return }
        do {
            try await room.localParticipant.setMicrophone(enabled: on)
            state.micOn = on
        } catch {
            // The microphone stays as it was; the button shows the real state.
        }
    }

    func setPlaybackVolume(_ volume: Double) {
        self.volume = min(1, max(0, volume))
        applyVolume()
    }

    // MARK: Private

    private static func microphoneAllowed() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        if AVAudioApplication.shared.recordPermission == .denied { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private func applyVolume() {
        guard let room else { return }
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks {
                (publication.track as? RemoteAudioTrack)?.volume = volume
            }
        }
    }

    private func refreshParticipants() {
        guard let room else { return }
        state.others = room.remoteParticipants.values
            .map { VoiceParticipant(id: $0.identity?.stringValue ?? UUID().uuidString, name: $0.name ?? "Motard", speaking: $0.isSpeaking) }
            .sorted { $0.name < $1.name }
    }

    // MARK: RoomDelegate (called from the SDK's own threads)

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            self.refreshParticipants()
            self.applyVolume()
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            guard self.room === room else { return }                                  // a room we already left
            switch connectionState {
            case .reconnecting:
                self.state.phase = .reconnecting
            case .connected:
                if self.state.isActive { self.state.phase = .connected }
            case .disconnected:
                self.room = nil
                SharedAudio.roomOpen = false
                self.state = VoiceState(phase: .failed("Voix coupée : réseau perdu"))
            default:
                break
            }
        }
    }
}
