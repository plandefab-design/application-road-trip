import AVFoundation

/// Spoken guidance with the system voice. Works screen locked (UIBackgroundModes: audio).
@MainActor
final class VoiceService {
    private let synth = AVSpeechSynthesizer()
    private var lastSpoken: [String: Date] = [:]
    var enabled = true

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    }

    /// - Parameter key: de-duplication key; the same key is not repeated within `cooldown` seconds.
    func say(_ text: String, key: String? = nil, cooldown: TimeInterval = 60) {
        guard enabled else { return }
        let k = key ?? text
        if let last = lastSpoken[k], Date().timeIntervalSince(last) < cooldown { return }
        lastSpoken[k] = Date()
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }
}
