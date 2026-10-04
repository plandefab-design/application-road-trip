import AVFoundation

/// Spoken guidance with the system voice. Works screen locked (UIBackgroundModes: audio).
///
/// Announcements are queued by priority: a camera or a turn is never stuck behind a traffic message (it cuts it),
/// and a message that waited too long is dropped instead of being said late. Music is lowered only while speaking.
@MainActor
final class VoiceService: NSObject, AVSpeechSynthesizerDelegate {
    enum Priority: Int, Comparable {
        /// Traffic, weather, pause, status: may wait 45 s, cut by anything more urgent.
        case info = 0
        /// Turn « dans 300 mètres », start/end messages.
        case normal = 1
        /// Camera, hazard, turn « maintenant », speed limit: said first, within 8 s or never.
        case urgent = 2

        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }

        var maxWait: TimeInterval {
            switch self {
            case .info: 45
            case .normal: 12
            case .urgent: 8
            }
        }
    }

    private struct Item {
        let text: String
        let priority: Priority
        let queuedAt: Date
    }

    private let synth = AVSpeechSynthesizer()
    private var lastSpoken: [String: Date] = [:]
    private var queue: [Item] = []
    private var current: Priority?

    /// true while a sentence is spoken, false when the queue is empty: the group's voices are lowered meanwhile.
    var onSpeakingChange: ((Bool) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
        configureSession()
    }

    /// Playback over the music. While the group's voice room is open, its audio session stays untouched.
    private func configureSession() {
        guard !SharedAudio.roomOpen else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt,
                                                         options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    }

    /// - Parameter key: de-duplication key; the same key is not repeated within `cooldown` seconds.
    func say(_ text: String, key: String? = nil, cooldown: TimeInterval = 60, priority: Priority = .normal) {
        let k = key ?? text
        if let last = lastSpoken[k], Date().timeIntervalSince(last) < cooldown { return }
        lastSpoken[k] = Date()
        let item = Item(text: text, priority: priority, queuedAt: Date())
        // Stable insert: after every item of the same or higher priority.
        let at = queue.firstIndex { $0.priority < priority } ?? queue.endIndex
        queue.insert(item, at: at)
        if let current, current < priority, priority == .urgent {
            synth.stopSpeaking(at: .word)          // didCancel → next item, the urgent one
        } else if current == nil {
            speakNext()
        }
    }

    private func speakNext() {
        let now = Date()
        queue.removeAll { now.timeIntervalSince($0.queuedAt) > $0.priority.maxWait }
        guard !queue.isEmpty else {
            current = nil
            onSpeakingChange?(false)
            // Give the music its volume back (the voice room, when open, keeps the session).
            if !SharedAudio.roomOpen { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            return
        }
        let item = queue.removeFirst()
        current = item.priority
        onSpeakingChange?(true)
        if !SharedAudio.roomOpen {
            configureSession()          // the voice room may have changed the category since the last sentence
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        let u = AVSpeechUtterance(string: item.text)
        u.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakNext() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakNext() }
    }
}
