import SwiftUI
import TripCore

/// Always shows the stored version of the trip, so edits (form, Claude) appear immediately.
struct TripDetailView: View {
    @EnvironmentObject private var store: TripStore
    let tripId: String

    var body: some View {
        if let trip = store.trips.first(where: { $0.id == tripId }) {
            TripDetailContent(trip: trip)
        } else {
            ContentUnavailableView("Trip introuvable", systemImage: "map", description: Text("Ce trip a été supprimé."))
        }
    }
}

struct TripDetailContent: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var location = LocationService()
    @State private var voice = VoiceService()

    let trip: Trip
    @State private var selectedDay: Int?
    @State private var navigatingDay: TripDay?
    @State private var editing = false
    @State private var chatting = false
    @State private var tracing = false
    @State private var traceProgress: String?
    @State private var traceMessage: String?

    /// Days planned by Claude have no geometry until the PC computes it (needed to ride and export).
    private var missingTracks: Bool { !trip.days.isEmpty && trip.days.contains { $0.track == nil } }

    /// Selected day if it can be ridden, else the first day that has a track.
    private var rideDay: TripDay? {
        if let s = selectedDay, let d = trip.days.first(where: { $0.index == s }), d.track != nil { return d }
        return trip.days.first { $0.track != nil }
    }

    var body: some View {
        List {
            Section {
                TripMapView(content: MapContent.from(trip: trip, highlightDay: selectedDay))
                    .frame(height: 280)
                    .listRowInsets(EdgeInsets())
            }

            if let day = rideDay {
                Section {
                    Button { startNavigation(day) } label: {
                        Label("Rouler — Jour \(day.index)", systemImage: "location.north.line.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } footer: {
                    Text("Touche une étape ci-dessous pour choisir le jour. Guidage vocal : pleins, arrêts, hors tracé, fin d'étape.")
                }
            }

            if missingTracks || tracing {
                Section {
                    Button { Task { await computeTracks() } } label: {
                        Label(tracing ? "Calcul du tracé en cours…" : "Calculer le tracé des étapes",
                              systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .disabled(tracing)
                    if tracing {
                        ProgressView(traceProgress ?? "Localisation des lieux…").font(.caption)
                    }
                } footer: {
                    Text("Calculé par le PC (routes moto sinueuses). Nécessaire pour rouler et exporter le GPX ; ensuite la navigation n'a plus besoin du PC.")
                }
            }

            Section {
                Button { chatting = true } label: {
                    Label(trip.days.isEmpty ? "Préparer l'itinéraire avec Claude" : "Modifier l'itinéraire avec Claude",
                          systemImage: "bubble.left.and.bubble.right")
                }
                Button { editing = true } label: {
                    Label("Modifier les paramètres (dates, motos, zones…)", systemImage: "slider.horizontal.3")
                }
            }

            let issues = TripValidator.validate(trip)
            if !issues.isEmpty {
                Section("Points à corriger") {
                    ForEach(issues.indices, id: \.self) { i in
                        Label(issues[i].message, systemImage: issues[i].severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(issues[i].severity == .error ? .red : .orange)
                    }
                }
            }

            Section("Étapes") {
                ForEach(trip.days) { day in
                    DayRow(trip: trip, day: day, selected: selectedDay == day.index)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedDay = selectedDay == day.index ? nil : day.index }
                        .swipeActions {
                            if day.track != nil {
                                Button("Rouler") { startNavigation(day) }.tint(.orange)
                            }
                        }
                }
            }

            if !trip.pois.isEmpty {
                Section("Adresses") {
                    ForEach(trip.pois) { poi in POIRow(poi: poi) }
                }
            }

            if !trip.checklist.isEmpty {
                Section("Préparation") {
                    ForEach(trip.checklist) { item in
                        Label(item.label, systemImage: item.done ? "checkmark.circle.fill" : "circle")
                            .badge(item.due)
                    }
                }
            }

            if trip.days.contains(where: { $0.track != nil }) {
                Section {
                    ShareLink(item: gpxFile(), preview: SharePreview("\(trip.name).gpx")) {
                        Label("Exporter le GPX", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle(trip.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editing = true } label: { Label("Modifier les paramètres", systemImage: "slider.horizontal.3") }
                    Button { chatting = true } label: { Label("Continuer avec Claude", systemImage: "bubble.left.and.bubble.right") }
                } label: {
                    Label("Modifier", systemImage: "pencil.circle")
                }
            }
            if let day = trip.days.first(where: { $0.index == (selectedDay ?? 1) }), day.track != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startNavigation(day) } label: {
                        Label("Rouler", systemImage: "location.north.line.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
        .sheet(isPresented: $editing) {
            CreateTripView(editing: trip).environmentObject(store).environmentObject(settings)
        }
        .navigationDestination(isPresented: $chatting) { PlannerChatView(trip: trip) }
        .alert("Tracé", isPresented: Binding(get: { traceMessage != nil }, set: { if !$0 { traceMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(traceMessage ?? "")
        }
        .onAppear { location.requestPermissions() }   // permissions asked before riding, never during
        .fullScreenCover(item: $navigatingDay) { day in
            NavigationView(trip: trip, day: day, location: location, voice: voice, pace: settings.pace) { newPace in
                settings.pace = newPace
            }
        }
    }

    private func startNavigation(_ day: TripDay) {
        voice.enabled = settings.voiceEnabled
        var t = trip
        t.status = .active
        store.save(t)
        navigatingDay = day
    }

    private func computeTracks() async {
        guard let client = CompanionClient(urlString: settings.companionURL, token: settings.companionToken) else {
            traceMessage = "Companion non configuré (Réglages › Companion)."
            return
        }
        tracing = true
        defer { tracing = false; traceProgress = nil }
        do {
            let job = try await client.startFinalize(tripId: trip.id, trip: trip)
            let done = try await client.waitForJob(tripId: trip.id, jobId: job.jobId) { traceProgress = $0 }
            if done.status == "done", let reply = done.reply {
                if let updated = reply.trip { store.save(updated) }
                traceMessage = reply.text
            } else {
                traceMessage = "Tracé impossible : \(done.error ?? "erreur inconnue")"
            }
        } catch {
            traceMessage = "Companion injoignable : vérifie que le PC est allumé et Tailscale actif. (\(error.localizedDescription))"
        }
    }

    private func gpxFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(trip.name).gpx")
        try? GPX.write(trip: trip).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct DayRow: View {
    let trip: Trip
    let day: TripDay
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Jour \(day.index)").font(.headline)
                if let d = day.date { Text(d).foregroundStyle(.secondary) }
                Spacer()
                if selected { Image(systemName: "eye.fill").foregroundStyle(.orange) }
            }
            HStack(spacing: 12) {
                if let km = day.distanceKm { Label("\(Int(km)) km", systemImage: "road.lanes") }
                if let min = day.drivingTimeMin { Label(Format.duration(minutes: min), systemImage: "clock") }
                if let c = day.curvinessScore { Label("\(Int(c))/100", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                if let a = day.ascentM, a > 0 { Label("\(Int(a)) m", systemImage: "mountain.2") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !day.highlights.isEmpty {
                Text(day.highlights.map(\.name).joined(separator: " · ")).font(.caption)
            }
            if !day.fuelStops.isEmpty {
                Text("⛽ " + day.fuelStops.map { "\($0.name) (km \(Int($0.kmFromStart)))" }.joined(separator: ", ")).font(.caption)
            }
            let chosen = trip.selectedStops(for: day)
            if !chosen.isEmpty {
                Text(chosen.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 2)
    }
}

struct POIRow: View {
    let poi: POI

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(poi.name).font(.subheadline.bold())
                Spacer()
                // SPEC §0.4: every factual item shows its verification status.
                Text(poi.verification == .verified ? "vérifié" : "non vérifié")
                    .font(.caption2.bold())
                    .foregroundStyle(poi.verification == .verified ? .green : .orange)
            }
            if let a = poi.address { Text(a).font(.caption) }
            HStack {
                if let phone = poi.phone, let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                    Link(phone, destination: url).font(.caption)
                }
                if let w = poi.website, let url = URL(string: w) { Link("Site", destination: url).font(.caption) }
                if let s = poi.source, let url = URL(string: s) { Link("Source", destination: url).font(.caption) }
            }
        }
    }
}
