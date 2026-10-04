import SwiftUI
import TripCore

/// The group on the riding screens: no modal alert, no permission request, no typing (CLAUDE.md rule 9) and
/// nothing the guidance waits for (rule 1).
struct GroupRideModifier: ViewModifier {
    @EnvironmentObject private var group: GroupSession
    private let location: LocationService
    private let voice: VoiceService

    init(location: LocationService, voice: VoiceService) {
        self.location = location
        self.voice = voice
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Friends' messages are read aloud like any other information, after the turns.
                group.rideDidStart { text in
                    voice.say(text, key: "group-\(UUID().uuidString)", cooldown: 0, priority: .normal)
                }
                // The group's voices are lowered while an instruction is spoken.
                voice.onSpeakingChange = { speaking in group.duckVoice(speaking) }
            }
            .onDisappear {
                voice.onSpeakingChange = nil
                group.duckVoice(false)
                group.rideDidEnd()
            }
            .onReceive(location.$lastFix) { fix in
                guard let fix else { return }
                group.reportFix(fix.point, speedKmh: fix.speed >= 0 ? fix.speed * 3.6 : nil, course: fix.course >= 0 ? fix.course : nil)
            }
    }
}

extension View {
    /// Connects a riding screen to the group: position, messages read aloud, voice ducking.
    func groupRide(location: LocationService, voice: VoiceService) -> some View {
        modifier(GroupRideModifier(location: location, voice: voice))
    }
}

/// Voice and quick-message buttons, in the column of round buttons on the right of the map.
struct GroupRideButtons: View {
    @EnvironmentObject private var group: GroupSession
    @State private var showQuick = false
    @State private var holding = false
    @State private var hint: String?

    var body: some View {
        if group.phase == .signedIn, group.currentGroup != nil {
            VStack(spacing: 10) {
                voiceButton
                MapRoundButton(icon: "text.bubble.fill", label: "Message rapide au groupe") { showQuick = true }
            }
            .overlay(alignment: .topTrailing) {
                if let hint {
                    Text(hint).font(.caption.bold()).multilineTextAlignment(.trailing)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: 230, alignment: .trailing)
                        .glass(radius: 14)
                        .offset(x: -66)
                        .allowsHitTesting(false)
                }
            }
            .sheet(isPresented: $showQuick) { QuickReplySheet() }
        }
    }

    @ViewBuilder private var voiceButton: some View {
        if group.voice.isActive {
            if group.pushToTalk { pushToTalkButton } else { muteButton }
        } else {
            MapRoundButton(icon: "headphones", label: "Rejoindre la voix du groupe") { join() }
        }
    }

    /// Open microphone: a tap mutes or unmutes.
    private var muteButton: some View {
        Button { Task { await group.setMicrophone(!group.voice.micOn) } } label: {
            Image(systemName: group.voice.micOn ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 21, weight: .bold))
                .frame(width: 56, height: 56)
                .glass(radius: 28, tint: group.voice.micOn ? Theme.ok : Theme.camera)
                .opacity(group.voice.phase == .reconnecting ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.voice.micOn ? "Micro ouvert. Toucher pour couper" : "Micro coupé. Toucher pour parler")
    }

    /// Push-to-talk: the microphone is open while the button is held.
    private var pushToTalkButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 21, weight: .bold))
            .frame(width: 56, height: 56)
            .glass(radius: 28, tint: holding ? Theme.ok : nil)
            .opacity(group.voice.phase == .reconnecting ? 0.5 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding else { return }
                        holding = true
                        Task { await group.setMicrophone(true) }
                    }
                    .onEnded { _ in
                        holding = false
                        Task { await group.setMicrophone(false) }
                    }
            )
            .accessibilityLabel("Maintenir pour parler")
    }

    private func join() {
        guard group.canJoinVoiceWithoutPrompt else {
            show("Première fois : active la voix dans l'onglet Groupe (autorisation du micro)")
            return
        }
        Task {
            let ok = await group.joinVoice()
            if !ok { show(group.lastError ?? "Voix indisponible") }
        }
    }

    private func show(_ text: String) {
        hint = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if hint == text { hint = nil }
        }
    }
}

/// One-tap messages: big buttons, closes itself.
struct QuickReplySheet: View {
    @EnvironmentObject private var group: GroupSession
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 14) {
            Text("Message au groupe").font(.headline).padding(.top, 14)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(QuickReply.allCases, id: \.self) { reply in
                    Button {
                        Task { await group.sendQuick(reply) }
                        dismiss()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: reply.icon).font(.title)
                            Text(reply.text).font(.subheadline.bold()).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 88)
                        .glass(radius: 18, tint: reply == .careful ? Theme.camera : nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
        .presentationBackground(Theme.bar)
    }
}

/// The nearest friends above the bottom cards, and a discreet line when the group is out of reach.
struct GroupFriendsStrip: View {
    @EnvironmentObject private var group: GroupSession

    var body: some View {
        if group.phase == .signedIn, group.currentGroup != nil {
            HStack(spacing: 8) {
                ForEach(Array(group.friendPins.prefix(3))) { pin in chip(pin) }
                if group.connection == .offline {
                    Label("Groupe hors réseau", systemImage: "wifi.slash")
                        .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6).glass(radius: 14)
                } else if group.sharePosition {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.caption.bold()).foregroundStyle(Theme.ok)
                        .padding(8).glass(radius: 14)
                        .accessibilityLabel("Position partagée avec le groupe")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(_ pin: FriendPin) -> some View {
        let speaking = group.voice.others.contains { $0.id == pin.id && $0.speaking }
        return HStack(spacing: 6) {
            FriendBadge(name: pin.name, size: 24)
            Text(pin.name).font(.subheadline.bold()).lineLimit(1)
            if let distance = pin.distance { Text(Format.distance(distance)).font(.subheadline.monospacedDigit()) }
            if speaking { Image(systemName: "waveform").foregroundStyle(Theme.ok) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .glass(radius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(speaking ? Theme.ok : .clear, lineWidth: 2))
        .opacity(pin.isStale ? 0.5 : 1)
    }
}
