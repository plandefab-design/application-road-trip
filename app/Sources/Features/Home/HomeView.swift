import SwiftUI
import TripCore

/// Home: the next trip at a glance — countdown, readiness, one big action — plus quick actions.
struct HomeView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var offlineMaps: OfflineMapStore
    @EnvironmentObject private var maintenance: MaintenanceStore
    @Binding var tab: RootView.Tab
    @EnvironmentObject private var rides: RideStore
    @EnvironmentObject private var sync: SyncService
    @State private var path: [String] = []
    @StateObject private var location = LocationService()
    @State private var voice = VoiceService()
    @State private var freeRiding = false
    @State private var showRides = false
    @State private var pendingRide: RideLog?
    @State private var shownRide: RideLog?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    freeRideButton
                    if !settings.sosPhone.isEmpty {
                        Button {
                            Task { await Messaging.sendCheckpoint(to: settings.sosPhone, location: location) }
                        } label: {
                            Label("Petit point à \(settings.sosName.isEmpty ? "mon contact" : settings.sosName) : tout va bien + ma ville",
                                  systemImage: "hand.thumbsup.fill")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                    }
                    if let expiry = SigningInfo.expirationDate, expiry.timeIntervalSinceNow < 2 * 86_400 {
                        banner("Signature expire \(expiry.formatted(.relative(presentation: .named)))",
                               detail: "Rafraîchis MotoTrip dans SideStore (LocalDevVPN connecté).",
                               icon: "exclamationmark.shield.fill", color: .orange)
                    }
                    if let trip = nextTrip {
                        nextTripCard(trip)
                    } else {
                        emptyCard
                    }
                    quickActions
                    if let urgent = maintenance.mostUrgent(garage: settings.garage) {
                        banner("Entretien \(urgent.bike.model) : \(urgent.item.label)",
                               detail: urgent.status.text.prefix(1).uppercased() + urgent.status.text.dropFirst() + ". Touche pour ouvrir le carnet.",
                               icon: "wrench.adjustable.fill",
                               color: urgent.status.level >= .due ? .red : .yellow) { tab = .settings }
                    }
                    if settings.garage.isEmpty || settings.garage.contains(where: { $0.category == nil }) {
                        banner("Complète ton garage", detail: "Type de moto et autonomie réelle : les itinéraires et les pleins en dépendent.",
                               icon: "wrench.and.screwdriver.fill", color: .blue) { tab = .settings }
                    }
                    if others.count > 0 {
                        Text("Autres trips").font(.headline).padding(.top, 4)
                        ForEach(others) { trip in
                            Button { path.append(trip.id) } label: { compactRow(trip) }.buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("MotoTrip")
            .navigationDestination(for: String.self) { TripDetailView(tripId: $0) }
            .navigationDestination(isPresented: $showRides) { RidesListView() }
            .task(id: nextTrip?.id) { if let id = nextTrip?.id { await offlineMaps.refresh(tripId: id) } }
            .onAppear {
                location.requestPermissions()   // asked here, never while riding
                location.warmUp()               // GPS already locked when « Rouler » is tapped
            }
            .fullScreenCover(isPresented: $freeRiding, onDismiss: {
                if let ride = pendingRide {
                    shownRide = ride
                    pendingRide = nil
                    Task { await sync.sync(store: store, rides: rides, settings: settings) }
                }
            }) {
                FreeRideView(location: location, voice: voice, camerasEnabled: settings.radarAnnouncements) { ride in
                    guard let ride else { return }
                    pendingRide = RideFinish.record(ride, settings: settings, rides: rides, maintenance: maintenance)
                }
            }
            .sheet(item: $shownRide) { RideSummaryView(ride: $0) }
        }
    }

    /// Ride now, without an itinerary: cameras and hazards spoken, km counted for maintenance.
    private var freeRideButton: some View {
        Button {
            voice.enabled = settings.voiceEnabled
            freeRiding = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "location.north.line.fill").font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rouler sans itinéraire").font(.headline)
                    Text("Radars et dangers annoncés, km comptés pour l'entretien, trace enregistrée")
                        .font(.caption).opacity(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right")
            }
            .foregroundStyle(.white)
            .padding()
            .background(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    // MARK: Data

    /// Trip in progress, else the next one to come, else the most recent.
    private var nextTrip: Trip? {
        let today = ISODate.format(Date())
        let sorted = store.trips.sorted { $0.params.dateStart < $1.params.dateStart }
        return sorted.first { $0.params.dateStart <= today && today <= $0.params.dateEnd && $0.status != .done }
            ?? sorted.first { $0.params.dateStart > today && $0.status != .done }
            ?? store.trips.first
    }

    private var others: [Trip] { store.trips.filter { $0.id != nextTrip?.id }.prefix(5).map { $0 } }

    // MARK: Cards

    private func nextTripCard(_ trip: Trip) -> some View {
        let km = trip.days.compactMap(\.distanceKm).reduce(0, +)
        let traced = !trip.days.isEmpty && trip.days.allSatisfy { $0.track != nil }
        let map = offlineMaps.status[trip.id]
        let fuelOK = trip.days.contains { !$0.stations.isEmpty }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(countdown(trip)).font(.caption.bold()).foregroundStyle(.orange).textCase(.uppercase)
                    Text(trip.name).font(.title.bold())
                    Text("\(trip.days.count) jour(s) · \(Int(km)) km · \(profileLabel(trip))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: trip.status)
            }
            TripMapView(content: MapContent.from(trip: trip))
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .allowsHitTesting(false)
            HStack(spacing: 8) {
                check("Tracé", ok: traced)
                check("Carte hors ligne", ok: map?.complete == true)
                check("Pleins", ok: fuelOK)
            }
            Button { path.append(trip.id) } label: {
                Label(isToday(trip) ? "Rouler" : "Préparer et voir le trip",
                      systemImage: isToday(trip) ? "location.north.line.fill" : "arrow.right.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 22))
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prêt pour le prochain trip ?").font(.title2.bold())
            Text("Crée un road trip avec Claude (routes, arrêts, adresses, pleins), ou importe un GPX.")
                .foregroundStyle(.secondary)
            Button { tab = .create } label: {
                Label("Créer un trip", systemImage: "plus.circle.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 22))
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            tile("Nouveau trip", "sparkles") { tab = .create }
            tile("Mes trips", "map.fill") { tab = .trips }
            tile("Mes sorties", "point.bottomleft.forward.to.point.topright.scurvepath") { showRides = true }
            tile("Garage", "gauge.with.dots.needle.67percent") { tab = .settings }
        }
    }

    // MARK: Pieces

    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption.bold())
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func check(_ label: String, ok: Bool) -> some View {
        Label(label, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption.bold())
            .foregroundStyle(ok ? .green : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background((ok ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
    }

    private func banner(_ title: String, detail: String, icon: String, color: Color, action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.bold())
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private func compactRow(_ trip: Trip) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name).font(.subheadline.bold())
                Text("\(trip.params.dateStart) · \(trip.days.count) jour(s)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: trip.status)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func isToday(_ trip: Trip) -> Bool {
        let today = ISODate.format(Date())
        return trip.params.dateStart <= today && today <= trip.params.dateEnd
    }

    private func countdown(_ trip: Trip) -> String {
        if isToday(trip) { return "En cours" }
        guard let start = ISODate.parse(trip.params.dateStart),
              let today = ISODate.parse(ISODate.format(Date())) else { return "" }
        let days = Int((start.timeIntervalSince(today) / 86_400).rounded())
        if days < 0 { return "Terminé" }
        return days == 1 ? "Demain" : "Dans \(days) jours"
    }

    private func profileLabel(_ trip: Trip) -> String {
        switch trip.params.routeProfile {
        case .curvy: "routes sinueuses"
        case .fast: "rapide"
        case .adventure: "trail"
        case .enduro: "enduro"
        }
    }
}
