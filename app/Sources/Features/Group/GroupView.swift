import SwiftUI
import TripCore

/// « Groupe »: ride with friends. Live voice (the helmet intercom is the phone's Bluetooth headset), their position
/// on the map, quick messages, trips shared between riders. All optional: riding never depends on it.
struct GroupView: View {
    @EnvironmentObject private var group: GroupSession

    var body: some View {
        NavigationStack {
            Group {
                switch group.phase {
                case .notConfigured:
                    GroupServerForm()
                case .signedOut:
                    GroupSignInView()
                case .signedIn:
                    if group.currentGroup == nil { GroupStartView() } else { GroupHomeView() }
                }
            }
            .navigationTitle(group.phase == .signedIn ? (group.currentGroup?.name ?? "Groupe") : "Groupe")
            .toolbarBackground(Theme.bar, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
        }
        .onAppear { group.watch(.groupTab, true) }
        .onDisappear { group.watch(.groupTab, false) }
    }
}

/// The group's main screen: voice, position, then messages, trips, members and account.
struct GroupHomeView: View {
    @EnvironmentObject private var group: GroupSession
    @State private var showStart = false

    var body: some View {
        List {
            if let error = group.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.camera)
                    Button("Masquer") { group.lastError = nil }
                }
            }
            if group.connection == .offline {
                Section {
                    Label("Pas de réseau : le groupe se remet à jour au retour du réseau.", systemImage: "wifi.slash")
                        .foregroundStyle(Theme.hazard)
                }
            }
            voiceSection
            positionSection
            Section {
                NavigationLink { GroupChatView() } label: {
                    GroupRow(title: "Messages", icon: "bubble.left.and.bubble.right.fill", tint: Theme.info, badge: group.unread)
                }
                NavigationLink { GroupTripsView() } label: {
                    GroupRow(title: "Trips partagés", icon: "map.fill", tint: Theme.accent,
                             value: group.sharedTrips.isEmpty ? nil : "\(group.sharedTrips.count)")
                }
                NavigationLink { GroupMembersView() } label: {
                    GroupRow(title: "Membres et invitation", icon: "person.3.fill", tint: .teal, value: "\(group.members.count)")
                }
                NavigationLink { GroupAccountView() } label: {
                    GroupRow(title: "Mon compte", icon: "person.crop.circle.fill", tint: .gray, value: group.myName)
                }
            }
        }
        .motoList()
        .tint(Theme.accent)
        .refreshable { await group.reloadCurrent() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(group.groups) { g in
                        Button { Task { await group.select(g.id) } } label: {
                            Label(g.name, systemImage: g.id == group.currentGroupId ? "checkmark" : "person.3")
                        }
                    }
                    Divider()
                    Button { showStart = true } label: { Label("Créer ou rejoindre un autre groupe", systemImage: "plus") }
                } label: {
                    Image(systemName: "person.3.sequence.fill")
                }
                .accessibilityLabel("Mes groupes")
            }
        }
        .sheet(isPresented: $showStart) {
            NavigationStack { GroupStartView(inSheet: true) }
        }
    }

    // MARK: Voice

    @ViewBuilder private var voiceSection: some View {
        let voice = group.voice
        Section {
            Button {
                Task {
                    if voice.isActive { await group.leaveVoice() } else { _ = await group.joinVoice() }
                }
            } label: {
                HStack(spacing: 12) {
                    IconBadge(icon: voice.isActive ? "phone.down.fill" : "headphones", tint: voice.isActive ? Theme.camera : Theme.ok)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.isActive ? "Quitter la voix" : "Rejoindre la voix").font(.headline).foregroundStyle(.primary)
                        Text(voiceStatus(voice)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if voice.phase == .connecting || voice.phase == .reconnecting { ProgressView() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if voice.isActive {
                if !group.pushToTalk {
                    Toggle(isOn: Binding(get: { voice.micOn }, set: { on in Task { await group.setMicrophone(on) } })) {
                        GroupRow(title: "Micro ouvert", icon: voice.micOn ? "mic.fill" : "mic.slash.fill",
                                 tint: voice.micOn ? Theme.ok : .gray)
                    }
                }
                ForEach(voice.others) { other in
                    HStack(spacing: 12) {
                        FriendBadge(name: other.name, size: 32)
                        Text(other.name)
                        Spacer()
                        if other.speaking { Image(systemName: "waveform").foregroundStyle(Theme.ok) }
                    }
                }
            }
            Toggle(isOn: $group.pushToTalk) {
                GroupRow(title: "Appuyer pour parler", icon: "hand.tap.fill", tint: Theme.info,
                         subtitle: "Sur la carte, tu maintiens le bouton micro pendant que tu parles")
            }
        } header: {
            Text("Voix")
        } footer: {
            Text("Ton casque intercom se branche en Bluetooth au téléphone : il fait micro et oreillettes. Une consigne de guidage couvre les voix le temps d'une phrase. Le réglage « Appuyer pour parler » prend effet à la prochaine connexion.")
        }
    }

    private func voiceStatus(_ voice: VoiceState) -> String {
        switch voice.phase {
        case .off: "Parle avec ton groupe, mains libres"
        case .connecting: "Connexion…"
        case .connected: voice.others.isEmpty ? "Connecté · personne d'autre pour l'instant" : "Connecté · \(voice.others.count) autre\(voice.others.count > 1 ? "s" : "")"
        case .reconnecting: "Reconnexion…"
        case .failed(let message): message
        }
    }

    // MARK: Position

    @ViewBuilder private var positionSection: some View {
        Section {
            Toggle(isOn: $group.sharePosition) {
                GroupRow(title: "Partager ma position en roulant", icon: "location.fill", tint: Theme.info,
                         subtitle: group.sharePosition ? "Tes amis te voient pendant tes sorties" : "Personne ne te voit")
            }
            ForEach(group.friendPins) { pin in
                HStack(spacing: 12) {
                    FriendBadge(name: pin.name, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pin.name).font(.headline)
                        Text(GroupFormat.pinLine(pin)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let speed = pin.speedKmh { Text("\(Int(speed)) km/h").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                }
                .opacity(pin.isStale ? 0.5 : 1)
            }
            if group.friendPins.isEmpty {
                Text("Aucun ami en route pour l'instant.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Position")
        } footer: {
            Text("Seulement pendant une navigation ou une balade libre. Ta moto disparaît de leur carte 5 minutes après la dernière mise à jour, ou dès que tu arrêtes.")
        }
    }
}

/// Create a group or join one with a code (or the invitation link / pasted message).
struct GroupStartView: View {
    @EnvironmentObject private var group: GroupSession
    @Environment(\.dismiss) private var dismiss
    private let inSheet: Bool
    @State private var name = ""
    @State private var code = ""

    init(inSheet: Bool = false) { self.inSheet = inSheet }

    var body: some View {
        List {
            if let code = group.pendingInvite {
                Section {
                    Button { Task { await group.acceptPendingInvite() } } label: {
                        GroupRow(title: "Invitation reçue", icon: "envelope.open.fill", tint: Theme.ok,
                                 subtitle: "Touche pour rejoindre le groupe (code \(code))")
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                TextField("Code d'invitation (8 caractères)", text: $code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("Rejoindre") {
                    Task { if await group.joinGroup(code: code) { finish() } }
                }
                .disabled(group.busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                PasteInviteButton()
            } header: {
                Text("Rejoindre un groupe")
            } footer: {
                Text("Un ami t'a envoyé son invitation ? Colle le message reçu : le code est reconnu tout seul.")
            }
            Section {
                TextField("Nom du groupe (ex. Alpes entre amis)", text: $name)
                Button("Créer le groupe") {
                    Task { if await group.createGroup(name: name) { finish() } }
                }
                .disabled(group.busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Créer un groupe")
            } footer: {
                Text("Jusqu'à 10 motards. Tu pourras inviter tes amis par lien ou par code.")
            }
            if let error = group.lastError { Section { Text(error).foregroundStyle(Theme.camera) } }
            if !inSheet {
                Section {
                    NavigationLink { GroupAccountView() } label: {
                        GroupRow(title: "Mon compte", icon: "person.crop.circle.fill", tint: .gray, value: group.myName)
                    }
                }
            }
        }
        .motoList()
        .tint(Theme.accent)
        .keyboardDoneButton()
        .navigationTitle(inSheet ? "Autre groupe" : "Groupe")
        .toolbar {
            if inSheet { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } } }
        }
    }

    private func finish() {
        name = ""
        code = ""
        if inSheet { dismiss() }
    }
}

// MARK: - Small shared pieces

/// A settings-style row: coloured icon, title, optional subtitle, value or unread badge.
struct GroupRow: View {
    let title: String
    let icon: String
    var tint: Color = Theme.accent
    var subtitle: String?
    var value: String?
    var badge = 0

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            if badge > 0 {
                Text("\(badge)").font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
            } else if let value {
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A friend's coloured initial, the same disc as on the map.
struct FriendBadge: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        Text(FriendStyle.initial(name))
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(FriendStyle.color(name)), in: Circle())
            .accessibilityHidden(true)
    }
}

/// « Coller l'invitation »: reads the invitation out of a message the friend sent (the system paste button asks
/// for no permission).
struct PasteInviteButton: View {
    @EnvironmentObject private var group: GroupSession

    var body: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let invite = strings.lazy.compactMap({ GroupInvite.find(in: $0) }).first else {
                group.lastError = "Aucune invitation Moto Road dans ce texte."
                return
            }
            Task { await group.receive(invite) }
        }
        .tint(Theme.accent)
    }
}

enum GroupFormat {
    static func ago(_ seconds: TimeInterval) -> String {
        seconds < 10 ? "à l'instant" : seconds < 60 ? "il y a \(Int(seconds)) s" : "il y a \(Int(seconds / 60)) min"
    }

    /// « 1,2 km · il y a 4 s ».
    static func pinLine(_ pin: FriendPin) -> String {
        [pin.distance.map { Format.distance($0) }, ago(pin.age)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The friends as the map draws them.
    static func mapFriends(_ pins: [FriendPin]) -> [MapContent.Friend] {
        pins.map { MapContent.Friend(id: $0.id, name: $0.name, subtitle: pinLine($0), point: $0.point, stale: $0.isStale) }
    }
}
