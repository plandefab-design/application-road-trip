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
    @EnvironmentObject private var offlineMaps: OfflineMapStore
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
    @State private var remindersMessage: String?
    @State private var preparing = false
    @State private var prep: [PrepStep] = []
    @State private var checkingWeather = false
    @State private var weatherReport: [String] = []

    /// Days planned by Claude have no geometry (nor turn-by-turn) until the PC computes it. GPX imports
    /// (no highlights) keep their own track: rerouting them would replace the rider's GPX.
    private var missingTracks: Bool {
        trip.days.contains { $0.track == nil || ($0.instructions.isEmpty && !$0.highlights.isEmpty) }
    }

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
                    Text("Touche une étape ci-dessous pour choisir le jour. Guidage vocal virage par virage, pleins, hors tracé, fin d'étape.")
                }
            }

            Section {
                Button {
                    Task { await prepareDeparture() }
                } label: {
                    Label(preparing ? "Préparation en cours…" : "Préparer le départ (tout mettre à jour)",
                          systemImage: "checklist.checked")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(preparing || tracing)
                ForEach(prep) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            switch step.state {
                            case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                            case .running: ProgressView()
                            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            }
                        }
                        .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.label).font(.subheadline.bold())
                            if step.state == .running, step.id == "route", let traceProgress {
                                Text(traceProgress).font(.caption).foregroundStyle(.secondary)
                            } else if step.state == .running, step.id == "map", let s = offlineMaps.status[trip.id] {
                                Text("\(Int(s.fraction * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            } else if let detail = step.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Le jour du départ (Wi-Fi + Tailscale) : recalcule le tracé et le guidage, met à jour radars, dangers, stations et pleins, télécharge la carte hors ligne, vérifie la météo et programme les rappels.")
            }

            if missingTracks || tracing {
                Section {
                    Button { Task { await computeTracks() } } label: {
                        Label(tracing ? "Calcul du tracé en cours…" : "Calculer le tracé et le guidage",
                              systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .disabled(tracing)
                    if tracing {
                        ProgressView(traceProgress ?? "Localisation des lieux…").font(.caption)
                    }
                } footer: {
                    Text("Calculé par le PC (routes moto sinueuses, instructions virage par virage). Nécessaire pour rouler et exporter le GPX ; ensuite la navigation n'a plus besoin du PC.")
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
                if !missingTracks && !tracing && trip.days.contains(where: { !$0.highlights.isEmpty }) {
                    Button { Task { await computeTracks() } } label: {
                        Label("Recalculer tracé, guidage, radars et dangers", systemImage: "arrow.triangle.2.circlepath")
                    }
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

            Section {
                ForEach(TripChecklist.merged(trip)) { item in
                    Button { toggle(item) } label: {
                        Label(item.label, systemImage: item.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.done ? .secondary : .primary)
                    }
                    .badge(item.due)
                }
                Button(remindersMessage ?? "Programmer les rappels (9 h le jour indiqué)") {
                    Task { await scheduleReminders() }
                }
            } header: {
                Text("Préparation")
            } footer: {
                Text("Notifications locales sur l'iPhone, sans serveur. Coche une ligne quand c'est fait : son rappel est annulé.")
            }

            if trip.days.contains(where: { $0.track != nil }) {
                offlineMapSection

                Section {
                    Button(checkingWeather ? "Vérification de la météo…" : "Vérifier la météo sur la route") {
                        Task {
                            checkingWeather = true
                            weatherReport = await WeatherClient().tripReport(trip, pace: settings.pace)
                            checkingWeather = false
                        }
                    }
                    .disabled(checkingWeather)
                    ForEach(weatherReport, id: \.self) { line in
                        Text(line).font(.subheadline)
                    }
                } header: {
                    Text("Météo sur la route")
                } footer: {
                    Text("Prévision Open-Meteo à l'heure de passage estimée (départ 9 h), un point tous les 15 km : pluie > 0,5 mm/h, rafales > 60 km/h, < 5 °C, visibilité < 1 km. En roulant, mise à jour toutes les 20 min si réseau.")
                }

                Section {
                    ShareLink(item: gpxFile(), preview: SharePreview("\(trip.name).gpx")) {
                        Label("Exporter le GPX", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: trip.id) { await offlineMaps.refresh(tripId: trip.id) }
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
            NavigationView(trip: trip, day: day, location: location, voice: voice, pace: settings.pace,
                           camerasEnabled: settings.radarAnnouncements, tomtomKey: settings.tomtomKey) { newPace in
                settings.pace = newPace
            }
        }
    }

    // MARK: Checklist (A9)

    private func toggle(_ item: ChecklistItem) {
        guard var t = store.trips.first(where: { $0.id == trip.id }) else { return }
        var items = TripChecklist.merged(t)
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].done.toggle() }
        t.checklist = items
        store.save(t)
        if remindersMessage != nil { Task { await scheduleReminders(for: t) } }   // keep reminders in sync
    }

    private func scheduleReminders(for current: Trip? = nil) async {
        let t = current ?? trip
        var allowed = await Reminders.isAuthorized()
        if !allowed { allowed = await Reminders.requestAuthorization() }
        guard allowed else {
            remindersMessage = "Notifications refusées (Réglages iPhone › MotoTrip)"
            return
        }
        let count = await Reminders.schedule(trip: t, items: TripChecklist.merged(t))
        if let expiry = SigningInfo.expirationDate { await Reminders.scheduleSignatureReminder(expiry: expiry) }
        remindersMessage = count == 0 ? "Aucun rappel à venir" : "\(count) rappel(s) programmé(s) ✓"
    }

    // MARK: Offline map (A7 / A8)

    private var offlineMapSection: some View {
        let s = offlineMaps.status[trip.id]
        return Section {
            if let s, s.downloading {
                ProgressView(value: s.fraction) {
                    Text("Téléchargement de la carte… \(Int(s.fraction * 100)) %")
                }
            } else if let s, s.complete {
                Label("Carte hors ligne prête · \(ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file))",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if let s {
                Label("Carte hors ligne incomplète (\(Int(s.fraction * 100)) %)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Carte non téléchargée : sans réseau, le fond de carte sera vide", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
            if s?.downloading != true {
                Button(s?.complete == true ? "Mettre à jour la carte hors ligne" : "Télécharger la carte hors ligne") {
                    Task { await downloadOfflineMap() }
                }
                if s != nil {
                    Button("Supprimer la carte hors ligne", role: .destructive) {
                        Task {
                            await offlineMaps.delete(tripId: trip.id)
                            setPackIntegrity(.missing)
                        }
                    }
                }
            }
            if let error = s?.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Carte hors ligne")
        } footer: {
            Text("À faire en Wi-Fi avant le départ : la carte s'affiche ensuite sans réseau (montagne, mode avion). Le guidage, lui, n'a jamais besoin du réseau.")
        }
    }

    private func downloadOfflineMap() async {
        do {
            try await offlineMaps.download(trip: trip)
            setPackIntegrity(.ok)
        } catch {
            setPackIntegrity(.missing)
        }
    }

    private func setPackIntegrity(_ integrity: PackIntegrity) {
        guard var t = store.trips.first(where: { $0.id == trip.id }) else { return }
        t.offlinePack.integrity = integrity
        t.offlinePack.tiles = integrity == .ok ? "maplibre-offline" : nil
        store.save(t)
    }

    private func startNavigation(_ day: TripDay) {
        voice.enabled = settings.voiceEnabled
        var t = trip
        t.status = .active
        store.save(t)
        navigatingDay = day
    }

    private func computeTracks() async {
        traceMessage = await runFinalize().message
    }

    /// Route, guidance, radars, dangers and stations from the PC, then fuel stops on the iPhone.
    private func runFinalize() async -> (ok: Bool, message: String) {
        guard let client = CompanionClient(urlString: settings.companionURL, token: settings.companionToken) else {
            return (false, "Companion non configuré (Réglages › Companion).")
        }
        let current = store.trips.first { $0.id == trip.id } ?? trip
        tracing = true
        defer { tracing = false; traceProgress = nil }
        do {
            let job = try await client.startFinalize(tripId: current.id, trip: current)
            let done = try await client.waitForJob(tripId: current.id, jobId: job.jobId) { traceProgress = $0 }
            guard done.status == "done", let reply = done.reply else {
                return (false, "Tracé impossible : \(done.error ?? "erreur inconnue")")
            }
            var fuelWarnings: [String] = []
            if var updated = reply.trip {
                fuelWarnings = updated.planFuelStops()      // stops placed on real stations (SPEC §5.2)
                store.save(updated)
            }
            return (true, ([reply.text] + fuelWarnings.map { "⛽ \($0)" }).joined(separator: "\n\n"))
        } catch {
            return (false, "Companion injoignable : PC allumé ? Tailscale actif ? (\(error.localizedDescription))")
        }
    }

    // MARK: Departure preparation (one tap)

    struct PrepStep: Identifiable, Equatable {
        enum State { case pending, running, ok, warning, failed }
        let id: String
        let label: String
        var state: State = .pending
        var detail: String?
    }

    /// Everything to refresh on departure day, in order; a failed step never blocks the next ones.
    private func prepareDeparture() async {
        preparing = true
        defer { preparing = false }
        prep = [
            PrepStep(id: "route", label: "Tracé, guidage, radars, dangers, pleins"),
            PrepStep(id: "map", label: "Carte hors ligne"),
            PrepStep(id: "weather", label: "Météo sur la route"),
            PrepStep(id: "reminders", label: "Rappels et signature SideStore"),
        ]
        func set(_ id: String, _ state: PrepStep.State, _ detail: String? = nil) {
            if let i = prep.firstIndex(where: { $0.id == id }) { prep[i].state = state; prep[i].detail = detail }
        }

        set("route", .running)
        if trip.days.contains(where: { !$0.highlights.isEmpty }) {
            let r = await runFinalize()
            set("route", r.ok ? (r.message.contains("⛽") || r.message.contains("introuvable") ? .warning : .ok) : .failed,
                r.message.components(separatedBy: "\n\n").prefix(3).joined(separator: "\n"))
        } else {
            set("route", .ok, "Trace importée (GPX) conservée telle quelle.")
        }

        let latest = store.trips.first { $0.id == trip.id } ?? trip
        set("map", .running)
        do {
            try await offlineMaps.download(trip: latest)
            setPackIntegrity(.ok)
            set("map", .ok, offlineMaps.status[latest.id].map { ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file) })
        } catch {
            setPackIntegrity(.missing)
            set("map", .failed, error.localizedDescription)
        }

        set("weather", .running)
        weatherReport = await WeatherClient().tripReport(latest, pace: settings.pace)
        let alerts = weatherReport.filter { !$0.contains("rien à signaler") }
        set("weather", alerts.isEmpty ? .ok : .warning, alerts.isEmpty ? "Rien à signaler." : alerts.prefix(3).joined(separator: "\n"))

        set("reminders", .running)
        if await Reminders.isAuthorized() {
            await scheduleReminders(for: latest)
            let expiry = SigningInfo.expirationDate.map { "Signature valable jusqu'au \($0.formatted(date: .abbreviated, time: .shortened))." }
            set("reminders", .ok, [remindersMessage, expiry].compactMap { $0 }.joined(separator: "\n"))
        } else {
            set("reminders", .warning, "Touche « Programmer les rappels » dans Préparation pour autoriser les notifications.")
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
