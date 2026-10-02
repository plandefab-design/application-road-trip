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
    @EnvironmentObject private var rides: RideStore
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var maintenance: MaintenanceStore
    @ObservedObject private var favoritesStore = FavoritePlaces.shared
    @ObservedObject private var validation = RoadBookValidation.shared
    @State private var pendingRide: RideLog?
    @State private var shownRide: RideLog?
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
    @State private var renderingPDF = false
    @State private var viewingPDF: PDFToShow?
    @State private var editingRoute = false

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
            mapAndRideSections
            prepareSection
            tracingSection
            actionsSection
            issuesSection
            stepsAndAddressesSections
            checklistSection
            tracedSections
        }
        .task(id: trip.id) { await offlineMaps.refresh(tripId: trip.id) }
        .motoList()
        .navigationTitle(trip.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { favoritesStore.toggleTrip(trip.id) } label: {
                    Image(systemName: favoritesStore.isFavoriteTrip(trip.id) ? "star.fill" : "star").foregroundStyle(.yellow)
                }
                .accessibilityLabel("Favori")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editing = true } label: { Label("Modifier les paramètres", systemImage: "slider.horizontal.3") }
                    Button { editingRoute = true } label: { Label("Modifier le tracé sur la carte", systemImage: "hand.tap") }
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
        .onAppear {
            location.requestPermissions()   // permissions asked before riding, never during
            location.warmUp()               // GPS already locked when « Rouler » is tapped
        }
        .fullScreenCover(item: $navigatingDay, onDismiss: {
            // Summary of what was ridden, then a silent backup to the PC when reachable.
            if let ride = pendingRide {
                shownRide = ride
                pendingRide = nil
                Task { await sync.sync(store: store, rides: rides, settings: settings) }
            }
        }) { day in
            NavigationView(trip: trip, day: day, location: location, voice: voice, pace: settings.pace,
                           traffic: LiveTraffic.client(settings), directions: settings.voiceEnabled,
                           onFinished: { ride in
                               guard let ride else { return }
                               // The km go to « Ma moto »: odometer + maintenance alerts.
                               pendingRide = RideFinish.record(ride, settings: settings, rides: rides, maintenance: maintenance)
                           }) { newPace in
                settings.pace = newPace
            }
        }
        .sheet(item: $shownRide) { RideSummaryView(ride: $0) }
        .sheet(item: $viewingPDF) { PDFViewer(url: $0.url, title: $0.title) }
        .fullScreenCover(isPresented: $editingRoute) {
            RouteEditorView(trip: store.trips.first { $0.id == trip.id } ?? trip, day: selectedDay)
                .environmentObject(store).environmentObject(settings)
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
            remindersMessage = "Notifications refusées (Réglages iPhone › Moto Road)"
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
        let current = store.trips.first { $0.id == trip.id } ?? trip
        tracing = true
        defer { tracing = false; traceProgress = nil }
        let outcome = await TripRouting.finalize(current, settings: settings) { traceProgress = $0 }
        if let updated = outcome.trip { store.save(updated) }
        return (outcome.ok, outcome.message)
    }

    // MARK: Departure preparation (one tap)

    struct PrepStep: Identifiable, Equatable {
        enum State { case pending, running, ok, warning, failed }
        let id: String
        let label: String
        var state: State = .pending
        var detail: String?
    }

    /// Leaving NOW (the trip dates are ignored): everything refreshed for the selected day, in order;
    /// a failed step never blocks the next ones.
    private func prepareDeparture() async {
        preparing = true
        defer { preparing = false }
        prep = [
            PrepStep(id: "route", label: "Tracé, guidage, radars, dangers, pleins"),
            PrepStep(id: "traffic", label: "Trafic en direct sur tout le trajet"),
            PrepStep(id: "weather", label: "Météo à l'heure de passage, départ maintenant"),
            PrepStep(id: "map", label: "Carte hors ligne"),
            PrepStep(id: "maintenance", label: "Entretien de ma moto"),
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
        // The day to ride: the selected one, else the first traced day.
        let day = latest.days.first { $0.index == selectedDay && $0.track != nil } ?? latest.days.first { $0.track != nil }

        set("traffic", .running)
        if let track = day?.track, let live = LiveTraffic.client(settings) {
            do {
                let incidents = try await live.alongRoute(track)
                // Dangers first (accident, obstacle, closure, jam…); roadworks only counted.
                let serious = incidents.filter { !$0.incident.category.isMinor }
                let works = incidents.count - serious.count
                var lines = serious.prefix(4).map { i in
                    "\(i.incident.category.label) au km \(Int(i.along / 1000))" + (i.incident.delay.map { " (+\(Int(($0 / 60).rounded())) min)" } ?? "")
                }
                if serious.count > 4 { lines.append("… et \(serious.count - 4) autre(s)") }
                if works > 0 { lines.append("\(works) zone(s) de travaux ou voie fermée") }
                set("traffic", serious.isEmpty ? .ok : .warning,
                    lines.isEmpty ? "Rien à signaler sur les \(Int(track.length / 1000)) km (jour \(day!.index))." : lines.joined(separator: "\n"))
            } catch {
                set("traffic", .failed, TomTomTrafficClient.describe(error))
            }
        } else {
            set("traffic", .warning, day == nil ? "Aucune étape tracée." : "Ajoute ta clé TomTom ou connecte le PC (Réglages).")
        }

        set("weather", .running)
        if let track = day?.track {
            if let hazards = await WeatherClient().nowReport(track: track, pace: settings.pace) {
                weatherReport = hazards.map { "\($0.summary) au km \(Int($0.along / 1000)) vers \(WeatherClient.hour($0.eta))" }
                set("weather", hazards.isEmpty ? .ok : .warning,
                    hazards.isEmpty ? "Rien à signaler en partant maintenant." : weatherReport.prefix(3).joined(separator: "\n"))
            } else {
                set("weather", .failed, "Météo indisponible (pas de réseau ?).")
            }
        } else {
            set("weather", .warning, "Aucune étape tracée.")
        }

        set("map", .running)
        do {
            try await offlineMaps.download(trip: latest)
            setPackIntegrity(.ok)
            set("map", .ok, offlineMaps.status[latest.id].map { ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file) })
        } catch {
            setPackIntegrity(.missing)
            set("map", .failed, error.localizedDescription)
        }

        set("maintenance", .running)
        if let bike = settings.primaryBike {
            let book = maintenance.book(for: bike)
            let tripKm = latest.days.compactMap(\.distanceKm).reduce(0, +)
            let todo = book.dueDuringTrip(tripKm: tripKm)
            set("maintenance", todo.isEmpty ? .ok : .warning,
                todo.isEmpty ? "\(bike.model) : rien à prévoir sur ces \(Int(tripKm)) km."
                    : "\(bike.model), à faire avant de partir : " + todo.prefix(4).map(\.label).joined(separator: ", ") + ".")
        } else {
            set("maintenance", .warning, "Ajoute ta moto dans Réglages › Garage.")
        }

        set("reminders", .running)
        if await Reminders.isAuthorized() {
            await scheduleReminders(for: latest)
            let expiry = SigningInfo.expirationDate.map { "Signature valable jusqu'au \($0.formatted(date: .abbreviated, time: .shortened))." }
            set("reminders", .ok, [remindersMessage, expiry].compactMap { $0 }.joined(separator: "\n"))
        } else {
            set("reminders", .warning, "Touche « Programmer les rappels » dans Préparation pour autoriser les notifications.")
        }
    }

    /// Road book PDF of this trip (validated or draft), shown in the app.
    private func showRoadBookPDF() async {
        renderingPDF = true
        let current = store.trips.first { $0.id == trip.id } ?? trip
        let book = RoadBook.build(current, pace: settings.pace, validatedAt: validation.validatedAt(current))
        let url = await RoadBookPDF.render(book, trip: current)
        renderingPDF = false
        viewingPDF = PDFToShow(url: url, title: "Feuille de route")
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
    var pace = PaceEstimator()

    /// One stage at a glance: how far, how long on the bike, when you get there.
    var body: some View {
        let timing = StageTimer.estimate(day, in: trip, pace: pace)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Étape \(day.index)").font(.headline)
                if let date = RoadBook.stageDate(day.date) { Text(date).foregroundStyle(.secondary) }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange) }
            }
            HStack(spacing: 14) {
                if let km = day.distanceKm { Label("\(Int(km.rounded())) km", systemImage: "road.lanes") }
                if let t = timing { Label(RoadBook.duration(t.riding), systemImage: "timer") }
                if let a = day.ascentM, a > 0 { Label("+\(Int(a)) m", systemImage: "mountain.2") }
            }
            .font(.subheadline.bold())
            if let t = timing, let departure = StageTimer.defaultDeparture(for: day) {
                Text("Départ \(RoadBook.clockText(departure)) → arrivée vers \(RoadBook.clockText(departure.addingTimeInterval(t.total)))"
                     + (t.stopsDuration > 0 ? " (arrêts compris : \(RoadBook.duration(t.stopsDuration)))" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !day.highlights.isEmpty {
                Text(day.highlights.prefix(4).map(\.name).joined(separator: " · ")).font(.caption)
            }
            if !day.fuelStops.isEmpty {
                Text("⛽ " + day.fuelStops.map { "km \(Int($0.kmFromStart)) \($0.name)" }.joined(separator: " · ")).font(.caption)
            }
            let chosen = trip.selectedStops(for: day)
            if !chosen.isEmpty {
                Text(chosen.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
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

// MARK: - Sections (split so the type checker stays fast)

extension TripDetailContent {
    @ViewBuilder var mapAndRideSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                TripMapView(content: MapContent.from(trip: trip, highlightDay: selectedDay))
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(chips, id: \.self) { chip($0) } }
                }
                if let day = rideDay {
                    Button { startNavigation(day) } label: {
                        Label("Rouler — Jour \(day.index)", systemImage: "location.north.line.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                HStack(spacing: 8) {
                    actionTile(preparing ? "En cours…" : "Préparer", "bolt.fill", .green) {
                        Task { await prepareDeparture() }
                    }
                    .disabled(preparing || tracing)
                    NavigationLink { RoadBookView(tripId: trip.id) } label: {
                        tileLabel(roadBookTitle, roadBookIcon, roadBookColor)
                    }
                    .buttonStyle(.plain)
                    actionTile("Modifier le tracé", "hand.tap.fill", .orange) { editingRoute = true }
                        .disabled(tracing)
                    actionTile("Claude", "bubble.left.and.bubble.right.fill", .purple) { chatting = true }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 12, trailing: 8))
            .listRowBackground(Color.clear)
        } footer: {
            Text("« Préparer » : départ maintenant, tout est remis à jour (tracé, trafic, météo, radars, carte, entretien). Touche une étape pour choisir le jour.")
        }
    }

    /// Key figures of the trip at a glance.
    private var chips: [String] {
        let km = trip.days.compactMap(\.distanceKm).reduce(0, +)
        let radars = trip.days.reduce(0) { $0 + $1.alerts.filter(\.kind.isCamera).count }
        let dangers = trip.days.reduce(0) { $0 + $1.alerts.filter { !$0.kind.isCamera }.count }
        let riding = trip.days.compactMap { StageTimer.estimate($0, in: trip, pace: settings.pace)?.riding }.reduce(0, +)
        return ["🗓 \(trip.days.count) j", "🛣 \(Int(km)) km"] + (riding > 0 ? ["⏱ \(RoadBook.duration(riding))"] : [])
            + ["🏍 \(profileLabel)"]
            + (radars > 0 ? ["📷 \(radars)"] : []) + (dangers > 0 ? ["⚠️ \(dangers)"] : [])
    }

    private var profileLabel: String {
        switch trip.params.routeProfile {
        case .curvy: "sinueux"
        case .fast: "rapide"
        case .adventure: "trail"
        case .enduro: "enduro"
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.background.secondary, in: Capsule())
    }

    private func actionTile(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, icon, color) }
            .buttonStyle(.plain)
    }

    private func tileLabel(_ title: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption.bold()).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    // Cahier des charges tile: validated (green), changed since (orange), to validate (blue).
    private var roadBookTitle: String {
        if validation.validatedAt(trip) != nil { return "Cahier validé" }
        return validation.isOutdated(trip) ? "Cahier à revalider" : "Cahier des charges"
    }
    private var roadBookIcon: String {
        validation.validatedAt(trip) != nil ? "checkmark.seal.fill" : "doc.text.fill"
    }
    private var roadBookColor: Color {
        if validation.validatedAt(trip) != nil { return .green }
        return validation.isOutdated(trip) ? .orange : .blue
    }

    @ViewBuilder var prepareSection: some View {
        if !prep.isEmpty {
            Section {
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
            } header: {
                Text("Départ maintenant")
            } footer: {
                Text("Wi-Fi + Tailscale conseillés. Ensuite, en roulant : trafic toutes les 5 min sur 200 km, météo toutes les 20 min, radars et dangers hors ligne.")
            }
        }
    }

    @ViewBuilder var tracingSection: some View {
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
    }

    /// Claude and parameters moved to the action bar; only the explicit recompute stays here.
    @ViewBuilder var actionsSection: some View {
        if !missingTracks && !tracing && trip.days.contains(where: { !$0.highlights.isEmpty }) {
            Section {
                Button { Task { await computeTracks() } } label: {
                    Label("Recalculer seulement le tracé (guidage, radars, dangers, pauses)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder var issuesSection: some View {
            let issues = TripValidator.validate(trip)
            if !issues.isEmpty {
                Section("Points à corriger") {
                    ForEach(issues.indices, id: \.self) { i in
                        Label(issues[i].message, systemImage: issues[i].severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(issues[i].severity == .error ? .red : .orange)
                    }
                }
            }
    }

    @ViewBuilder var stepsAndAddressesSections: some View {
            Section("Étapes") {
                ForEach(trip.days) { day in
                    DayRow(trip: trip, day: day, selected: selectedDay == day.index, pace: settings.pace)
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
                Section {
                    DisclosureGroup("Adresses (\(trip.pois.count))") {
                        ForEach(trip.pois) { poi in POIRow(poi: poi) }
                    }
                }
            }
    }

    @ViewBuilder var checklistSection: some View {
            let items = TripChecklist.merged(trip)
            Section {
                DisclosureGroup("Préparation · \(items.filter(\.done).count)/\(items.count) fait") {
                    ForEach(items) { item in
                        Button { toggle(item) } label: {
                            Label(item.label, systemImage: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.done ? .secondary : .primary)
                        }
                        .badge(item.due)
                    }
                    Button(remindersMessage ?? "Programmer les rappels (9 h le jour indiqué)") {
                        Task { await scheduleReminders() }
                    }
                }
            } footer: {
                Text("Notifications locales sur l'iPhone, sans serveur. Coche une ligne quand c'est fait : son rappel est annulé.")
            }
    }

    @ViewBuilder var tracedSections: some View {
            if trip.days.contains(where: { $0.track != nil }) {
                offlineMapSection

                let ridden = rides.rides(for: trip.id)
                if !ridden.isEmpty {
                    Section("Mes sorties") {
                        ForEach(ridden) { ride in
                            Button { shownRide = ride } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Jour \(ride.day) · \(Format.distance(ride.summary.distance))").font(.subheadline.bold())
                                        Text("\(ride.summary.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "") · \(ride.summary.bends) virages · \(Int((ride.summary.averageMovingSpeed * 3.6).rounded())) km/h de moyenne")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: ride.uploaded ? "checkmark.icloud" : "icloud.and.arrow.up").foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { idx in idx.map { ridden[$0] }.forEach(rides.delete) }
                    }
                }

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
                    Button { Task { await showRoadBookPDF() } } label: {
                        Label(renderingPDF ? "Préparation de la feuille de route…" : "Feuille de route (PDF)",
                              systemImage: "doc.richtext")
                    }
                    .disabled(renderingPDF)
                } footer: {
                    Text("Le PDF s'ouvre dans l'app : lis-le, enregistre-le dans Fichiers ou partage-le.")
                }
            }
    }

}
