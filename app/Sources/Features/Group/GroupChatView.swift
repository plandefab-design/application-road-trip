import SwiftUI
import TripCore

/// The group's chat: quick replies in one tap, typed messages when stopped. Trip shares appear as cards.
struct GroupChatView: View {
    @EnvironmentObject private var group: GroupSession
    @EnvironmentObject private var store: TripStore
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if group.messages.isEmpty {
                            Text("Aucun message. Dis bonjour, ou touche une réponse rapide.")
                                .font(.subheadline).foregroundStyle(.secondary).padding(.top, 40)
                        }
                        ForEach(group.messages) { message in
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: group.messages.count) { _, _ in scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy) }
            }
            Divider()
            quickBar
            composer
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { group.markRead() }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = group.messages.last?.id else { return }
        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
    }

    // MARK: Bubbles

    @ViewBuilder private func bubble(_ message: GroupMessage) -> some View {
        let mine = message.userId == group.userId
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 48) } else { FriendBadge(name: group.name(of: message.userId), size: 28) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                if !mine { Text(group.name(of: message.userId)).font(.caption.bold()).foregroundStyle(.secondary) }
                content(message, mine: mine)
                Text(message.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
            if !mine { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder private func content(_ message: GroupMessage, mine: Bool) -> some View {
        switch message.kind {
        case .text:
            Text(message.body)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(mine ? Theme.accent : Theme.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(mine ? Color.white : Color.primary)
        case .quick:
            let icon = QuickReply.allCases.first { $0.text == message.body }?.icon ?? "bolt.fill"
            Label(message.body, systemImage: icon)
                .font(.subheadline.bold())
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background((mine ? Theme.accent : Theme.info).opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
        case .trip:
            tripCard(message, mine: mine)
        }
    }

    @ViewBuilder private func tripCard(_ message: GroupMessage, mine: Bool) -> some View {
        let share = group.sharedTrips.first { $0.id == message.shareId }
        VStack(alignment: .leading, spacing: 6) {
            Label(message.body, systemImage: "map.fill").font(.headline)
            if let share {
                Text("\(share.days) jour\(share.days > 1 ? "s" : "") · \(Int(share.distanceKm.rounded())) km")
                    .font(.caption).foregroundStyle(.secondary)
                if mine {
                    Text("Partagé avec le groupe").font(.caption).foregroundStyle(.secondary)
                } else if group.isImported(share) {
                    Label("Ajouté à mes trips", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(Theme.ok)
                } else {
                    Button { add(share) } label: { Label("Ajouter à mes trips", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                }
            } else {
                Text("Ce trip n'est plus partagé.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func add(_ share: SharedTrip) {
        Task {
            if let trip = await group.importShared(share) { store.save(trip) }
        }
    }

    // MARK: Composer

    private var quickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickReply.allCases, id: \.self) { reply in
                    Button { Task { await group.sendQuick(reply) } } label: {
                        Label(reply.text, systemImage: reply.icon).font(.subheadline.bold())
                    }
                    .buttonStyle(.bordered).tint(Theme.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...3)
                .padding(10)
                .background(Theme.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Button {
                let text = draft
                draft = ""
                Task {
                    let sent = await group.sendText(text)
                    if !sent { draft = text }
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Envoyer")
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

/// Trips shared with the group: share one of mine, add a friend's to mine.
struct GroupTripsView: View {
    @EnvironmentObject private var group: GroupSession
    @EnvironmentObject private var store: TripStore

    var body: some View {
        List {
            Section {
                Menu {
                    ForEach(store.trips) { trip in
                        Button(trip.name) { Task { await group.share(trip) } }
                    }
                } label: {
                    HStack {
                        GroupRow(title: "Partager un de mes trips", icon: "square.and.arrow.up", tint: Theme.accent,
                                 subtitle: "Avec tout le groupe, tracé et cahier des charges compris")
                        if group.busy { ProgressView() }
                    }
                }
                .disabled(store.trips.isEmpty || group.busy)
            } footer: {
                Text("Chaque ami reçoit sa propre copie : il choisit ses repas et ses hôtels, télécharge ses cartes, et rien ne revient chez toi.")
            }
            Section("Partagés avec le groupe") {
                if group.sharedTrips.isEmpty {
                    Text("Aucun trip partagé pour l'instant.").foregroundStyle(.secondary)
                }
                ForEach(group.sharedTrips) { share in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(share.name).font(.headline)
                            Text("\(group.name(of: share.userId)) · \(share.days) jour\(share.days > 1 ? "s" : "") · \(Int(share.distanceKm.rounded())) km")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if share.userId == group.userId {
                            Image(systemName: "person.fill.checkmark").foregroundStyle(.secondary)
                        } else if group.isImported(share) {
                            Label("Ajouté", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(Theme.ok)
                        } else {
                            Button("Ajouter") { add(share) }
                                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                                .disabled(group.busy)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if share.userId == group.userId {
                            Button("Retirer", role: .destructive) { Task { await group.deleteShared(share) } }
                        }
                    }
                }
            }
            if let error = group.lastError { Section { Text(error).foregroundStyle(Theme.camera) } }
        }
        .motoList()
        .tint(Theme.accent)
        .navigationTitle("Trips partagés")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add(_ share: SharedTrip) {
        Task {
            if let trip = await group.importShared(share) { store.save(trip) }
        }
    }
}
