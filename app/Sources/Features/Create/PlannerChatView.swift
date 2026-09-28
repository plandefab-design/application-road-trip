import SwiftUI
import TripCore

/// Chat with Claude (running on the PC companion) + live map preview (SPEC §4.2 step 2).
struct PlannerChatView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings

    @State var trip: Trip
    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var sending = false
    @State private var companionStatus: String?

    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            TripMapView(content: MapContent.from(trip: trip))
                .frame(height: 260)

            if let s = companionStatus {
                Text(s).font(.caption).padding(6).frame(maxWidth: .infinity).background(Color.orange.opacity(0.2))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { m in
                            Text(m.text)
                                .padding(10)
                                .background(m.fromUser ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 12))
                                .frame(maxWidth: .infinity, alignment: m.fromUser ? .trailing : .leading)
                                .id(m.id)
                        }
                        if sending { ProgressView("Claude prépare l'itinéraire…") }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            HStack {
                TextField("Ajuster : ajoute un col, change le déjeuner…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button { Task { await send(input) } } label: { Image(systemName: "paperplane.fill") }
                    .disabled(input.isEmpty || sending)
            }
            .padding()
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Enregistrer") { store.save(trip) }
        }
        .task {
            guard messages.isEmpty else { return }
            if trip.days.isEmpty {
                await send("Propose l'itinéraire complet jour par jour selon le formulaire et les règles du projet.", showAsUser: false)
            } else {
                // Existing itinerary: never re-plan it automatically, wait for the rider's request.
                messages.append(Message(fromUser: false, text: "Itinéraire actuel : \(trip.days.count) jour(s). Dis-moi ce que tu veux changer."))
            }
        }
    }

    private func send(_ text: String, showAsUser: Bool = true) async {
        guard let client = CompanionClient(urlString: settings.companionURL, token: settings.companionToken) else {
            companionStatus = "Companion non configuré (Réglages › Companion). Tu peux importer un trip.json produit par ton projet Claude."
            return
        }
        if showAsUser { messages.append(Message(fromUser: true, text: text)) }
        input = ""
        sending = true
        defer { sending = false }
        do {
            let reply = try await client.chat(tripId: trip.id, message: text, trip: trip)
            companionStatus = nil
            messages.append(Message(fromUser: false, text: reply.text))
            if let q = reply.questions, !q.isEmpty {
                messages.append(Message(fromUser: false, text: q.map { "• \($0)" }.joined(separator: "\n")))
            }
            if let updated = reply.trip {
                trip = updated          // map redraws immediately
                store.save(updated)
            }
        } catch {
            companionStatus = "Companion injoignable : vérifie que le PC est allumé et Tailscale actif. (\(error.localizedDescription))"
        }
    }
}
