import SwiftUI
import TripCore

/// « Rouler »: one big button to ride now, where to go, favourite places in one tap, the next trip.
/// Warnings only when something needs doing. Big targets, few words: made to be used helmet on.
struct HomeView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var offlineMaps: OfflineMapStore
    @EnvironmentObject private var maintenance: MaintenanceStore
    @EnvironmentObject private var rides: RideStore
    @EnvironmentObject private var sync: SyncService
    @ObservedObject private var saved = FavoritePlaces.shared
    @Binding var tab: RootView.Tab
    @State private var path: [String] = []
    @StateObject private var location = LocationService()
    @State private var voice = VoiceService()
    @State private var ride: Ride?
    @State private var showRides = false
    @State private var pendingRide: RideLog?
    @State private var shownRide: RideLog?

    /// What the riding screen opens with.
    enum Ride: Identifiable {
        case free, address, place(FavoritePlaces.Place)
        var id: String {
            switch self {
            case .free: "free"
            case .address: "address"
            case .place(let p): "place-\(p.id)"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rideButton
                    whereButton
                    if !saved.favorites.isEmpty { favoritesStrip }
                    warnings
                    if let trip = nextTrip { nextTripCard(trip) }
                    bottomRow
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
            .fullScreenCover(item: $ride, onDismiss: finishRide) { ride in
                switch ride {
                case .free, .address:
                    FreeRideView(location: location, voice: voice, camerasEnabled: settings.radarAnnouncements,
                                 traffic: LiveTraffic.client(settings), startWithAddress: ride.id == "address", onFinished: record)
                case .place(let place):
                    FreeRideView(location: location, voice: voice, camerasEnabled: settings.radarAnnouncements,
                                 traffic: LiveTraffic.client(settings), destination: place, onFinished: record)
                }
            }
            .sheet(item: $shownRide) { RideSummaryView(ride: $0) }
        }
    }

    // MARK: Ride

    private var rideButton: some View {
        Button { go(.free) } label: {
            HStack(spacing: 16) {
                Image(systemName: "location.north.line.fill").font(.system(size: 40, weight: .bold))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rouler").font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text(AlertPackStore.shared.guide == nil ? "Synchronise avec le PC pour les radars"
                         : "Radars, dangers et trafic annoncés")
                        .font(.subheadline.weight(.medium)).opacity(0.9)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Balade libre : radars et dangers annoncés, km comptés pour l'entretien")
    }

    private var whereButton: some View {
        Button { go(.address) } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.title2)
                Text("Où tu vas ?").font(.title3.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private var favoritesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(saved.favorites.prefix(8)) { place in
                    Button { go(.place(place)) } label: {
                        Label(place.name, systemImage: "star.fill")
                            .font(.subheadline.bold())
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .background(Color.yellow.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func go(_ r: Ride) {
        voice.enabled = settings.voiceEnabled
        ride = r
    }

    private func record(_ log: RideLog?) {
        guard let log else { return }
        pendingRide = RideFinish.record(log, settings: settings, rides: rides, maintenance: maintenance)
    }

    private func finishRide() {
        guard let log = pendingRide else { return }
        shownRide = log
        pendingRide = nil
        Task { await sync.sync(store: store, rides: rides, settings: settings) }
    }

    // MARK: Warnings (only when something needs doing)

    @ViewBuilder private var warnings: some View {
        if let expiry = SigningInfo.expirationDate, expiry.timeIntervalSinceNow < 2 * 86_400 {
            banner("App à rafraîchir \(expiry.formatted(.relative(presentation: .named)))",
                   detail: "SideStore › Rafraîchir (LocalDevVPN connecté).", icon: "exclamationmark.shield.fill", color: .orange)
        }
        if let urgent = maintenance.mostUrgent(garage: settings.garage) {
            banner("\(urgent.bike.model) : \(urgent.item.label)",
                   detail: urgent.status.text.prefix(1).uppercased() + urgent.status.text.dropFirst(),
                   icon: "wrench.adjustable.fill", color: urgent.status.level >= .due ? .red : .yellow) { tab = .settings }
        }
        if settings.garage.isEmpty || settings.garage.contains(where: { $0.category == nil }) {
            banner("Complète ton garage", detail: "Type de moto et autonomie réelle : routes et pleins en dépendent.",
                   icon: "wrench.and.screwdriver.fill", color: .blue) { tab = .settings }
        }
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
                if action != nil { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            .padding()
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    // MARK: Next trip

    /// Trip in progress, else the next one to come.
    private var nextTrip: Trip? {
        let today = ISODate.format(Date())
        let sorted = store.trips.sorted { $0.params.dateStart < $1.params.dateStart }
        return sorted.first { $0.params.dateStart <= today && today <= $0.params.dateEnd && $0.status != .done }
            ?? sorted.first { $0.params.dateStart > today && $0.status != .done }
    }

    private func nextTripCard(_ trip: Trip) -> some View {
        let km = trip.days.compactMap(\.distanceKm).reduce(0, +)
        let traced = !trip.days.isEmpty && trip.days.allSatisfy { $0.track != nil }
        let mapReady = offlineMaps.status[trip.id]?.complete == true
        return Button { path.append(trip.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(countdown(trip)).font(.caption.bold()).foregroundStyle(.orange).textCase(.uppercase)
                    Spacer()
                    StatusBadge(status: trip.status)
                }
                Text(trip.name).font(.title2.bold())
                Text("\(trip.days.count) étape\(trip.days.count > 1 ? "s" : "") · \(Int(km)) km").foregroundStyle(.secondary)
                TripMapView(content: MapContent.from(trip: trip))
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .allowsHitTesting(false)
                HStack(spacing: 8) {
                    check("Tracé", ok: traced)
                    check("Carte hors ligne", ok: mapReady)
                    check("Cahier validé", ok: RoadBookValidation.shared.validatedAt(trip) != nil)
                }
            }
            .padding()
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }

    private func check(_ label: String, ok: Bool) -> some View {
        Label(label, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption2.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(ok ? .green : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background((ok ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
    }

    private func countdown(_ trip: Trip) -> String {
        let today = ISODate.format(Date())
        if trip.params.dateStart <= today && today <= trip.params.dateEnd { return "En cours" }
        guard let start = ISODate.parse(trip.params.dateStart), let now = ISODate.parse(today) else { return "" }
        let days = Int((start.timeIntervalSince(now) / 86_400).rounded())
        return days == 1 ? "Demain" : "Dans \(days) jours"
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack(spacing: 10) {
            if !settings.sosPhone.isEmpty {
                tile("Petit point", "hand.thumbsup.fill", .green) {
                    Task { await Messaging.sendCheckpoint(to: settings.sosPhone, location: location) }
                }
            }
            tile("Mes sorties", "point.bottomleft.forward.to.point.topright.scurvepath", .purple) { showRides = true }
            tile("Mes trips", "map.fill", .blue) { tab = .trips }
        }
    }

    private func tile(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption.bold())
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
