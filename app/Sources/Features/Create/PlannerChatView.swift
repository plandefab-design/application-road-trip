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
    @State private var progress: String?
    @State private var startedAt: Date?
    @State private var loaded = false
    @FocusState private var inputFocused: Bool

    /// Job id of a planner turn still running on the PC, so reopening the chat picks it up again.
    private var pendingJobKey: String { "plannerJob.\(trip.id)" }

    typealias Message = ChatHistory.Message

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
                        if sending {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView("Claude prépare l'itinéraire… (plusieurs minutes possibles)")
                                if let startedAt {
                                    Text(startedAt, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                if let progress {
                                    Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            HStack {
                TextField("Ajuster : ajoute un col, change le déjeuner…", text: $input, axis: .vertical)
                    .focused($inputFocused)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button { inputFocused = false; Task { await send(input) } } label: { Image(systemName: "paperplane.fill") }
                    .disabled(input.isEmpty || sending)
            }
            .padding()
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Enregistrer") { store.save(trip) }
        }
        .keyboardDoneButton()
        .onChange(of: messages) { _, all in ChatHistory.save(all, for: trip.id) }
        .task {
            guard !loaded else { return }
            loaded = true
            messages = ChatHistory.load(trip.id)   // previous conversation with Claude for this trip
            if let jobId = UserDefaults.standard.string(forKey: pendingJobKey),
               let client = CompanionClient(urlString: settings.companionURL, token: settings.companionToken) {
                // A previous request is still running (or finished) on the PC: follow it instead of restarting.
                sending = true
                defer { sending = false; progress = nil; startedAt = nil }
                startedAt = Date()
                await follow(jobId: jobId, client: client)
            } else if !messages.isEmpty {
                return
            } else if trip.days.isEmpty {
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
        startedAt = Date()
        defer { sending = false; progress = nil; startedAt = nil }
        do {
            let job = try await client.startChat(tripId: trip.id, message: text, trip: trip)
            companionStatus = nil
            UserDefaults.standard.set(job.jobId, forKey: pendingJobKey)
            await follow(jobId: job.jobId, client: client)
        } catch {
            companionStatus = "Companion injoignable : vérifie que le PC est allumé et Tailscale actif. (\(error.localizedDescription))"
        }
    }

    /// Polls a planner job every 3 s until it ends. Short network drops (app in background,
    /// Tailscale reconnecting) are retried; the job keeps running on the PC meanwhile.
    private func follow(jobId: String, client: CompanionClient) async {
        var failures = 0
        let deadline = Date().addingTimeInterval(45 * 60)
        while Date() < deadline {
            do {
                let job = try await client.chatJob(tripId: trip.id, jobId: jobId)
                failures = 0
                companionStatus = nil
                switch job.status {
                case "running":
                    progress = job.progress?.last
                case "done":
                    UserDefaults.standard.removeObject(forKey: pendingJobKey)
                    if let reply = job.reply { apply(reply) }
                    return
                default:
                    UserDefaults.standard.removeObject(forKey: pendingJobKey)
                    companionStatus = "Claude n'a pas pu terminer : \(job.error ?? "erreur inconnue")"
                    return
                }
            } catch let failure as CompanionClient.Failure where failure.statusCode == 404 {
                UserDefaults.standard.removeObject(forKey: pendingJobKey)
                companionStatus = "Le PC a redémarré pendant la préparation : renvoie ta demande."
                return
            } catch {
                failures += 1
                if failures >= 40 {     // ~2 min without the PC: stop, the chat resumes this job when reopened
                    companionStatus = "Companion injoignable : vérifie que le PC est allumé et Tailscale actif. Rouvre ce chat pour récupérer la réponse."
                    return
                }
                companionStatus = "Connexion au PC interrompue, nouvel essai…"
            }
            try? await Task.sleep(for: .seconds(3))
        }
        companionStatus = "Claude n'a pas terminé après 45 min : renvoie ta demande."
    }

    private func apply(_ reply: CompanionClient.ChatReply) {
        messages.append(Message(fromUser: false, text: reply.text))
        if let q = reply.questions, !q.isEmpty {
            messages.append(Message(fromUser: false, text: q.map { "• \($0)" }.joined(separator: "\n")))
        }
        if let updated = reply.trip {
            trip = updated          // map redraws immediately
            store.save(updated)
        }
    }
}
