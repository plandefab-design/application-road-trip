import SwiftUI
import TripCore

/// ⭐ Favoris: favourite destinations, trips and rides, each started in one tap — with cameras and hazards
/// announced as on every route.
struct FavoritesView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var rides: RideStore
    @EnvironmentObject private var maintenance: MaintenanceStore
    @EnvironmentObject private var sync: SyncService
    @ObservedObject private var saved = FavoritePlaces.shared
    @StateObject private var location = LocationService()
    @State private var voice = VoiceService()

    enum Launch: Identifiable {
        case trip(Trip, TripDay)
        case destination(FavoritePlaces.Place)
        var id: String {
            switch self {
            case .trip(let t, let d): "trip-\(t.id)-\(d.index)"
            case .destination(let p): "dest-\(p.id)"
            }
        }
    }

    @State private var launch: Launch?
    @State private var pendingRide: RideLog?
    @State private var shownRide: RideLog?

    private var favoriteTrips: [Trip] { saved.favoriteTripIds.compactMap { id in store.trips.first { $0.id == id } } }
    private var favoriteRides: [RideLog] { rides.rides.filter(\.isFavorite) }

    var body: some View {
        NavigationStack {
            List {
                if saved.favorites.isEmpty && favoriteTrips.isEmpty && favoriteRides.isEmpty {
                    ContentUnavailableView("Aucun favori", systemImage: "star",
                                           description: Text("Touche ⭐ sur une adresse (Aller à une adresse), un trip ou une sortie (Mes sorties) : il apparaîtra ici, prêt à partir."))
                }
                if !saved.favorites.isEmpty {
                    Section("Destinations") {
                        ForEach(saved.favorites) { p in
                            row(title: p.name, subtitle: p.subtitle, icon: "mappin.circle.fill", tint: .red) {
                                go(.destination(p))
                            }
                        }
                        .onDelete { idx in idx.map { saved.favorites[$0] }.forEach(saved.removeFavorite) }
                    }
                }
                if !favoriteTrips.isEmpty {
                    Section("Trips") {
                        ForEach(favoriteTrips) { trip in
                            let day = trip.days.first { $0.track != nil }
                            row(title: trip.name,
                                subtitle: "\(trip.days.count) jour(s) · \(Int(trip.days.compactMap(\.distanceKm).reduce(0, +))) km" + (day == nil ? " · tracé à calculer" : ""),
                                icon: "map.fill", tint: .orange) {
                                if let day { go(.trip(trip, day)) }
                            }
                            .disabled(day == nil)
                        }
                        .onDelete { idx in idx.map { favoriteTrips[$0].id }.forEach(saved.toggleTrip) }
                    }
                }
                if !favoriteRides.isEmpty {
                    Section("Trajets") {
                        ForEach(favoriteRides) { ride in
                            row(title: ride.tripId == RideStore.freeRideTripId ? "Balade" : ride.tripName,
                                subtitle: "\(ride.summary.startedAt?.formatted(date: .abbreviated, time: .omitted) ?? "") · \(Format.distance(ride.summary.distance)) · \(ride.summary.bends) virages",
                                icon: "point.bottomleft.forward.to.point.topright.scurvepath", tint: .purple) {
                                let trip = ride.asTrip()
                                if let day = trip.days.first { go(.trip(trip, day)) }
                            }
                        }
                        .onDelete { idx in idx.map { favoriteRides[$0] }.forEach(rides.toggleFavorite) }
                    }
                }
            }
            .navigationTitle("Favoris")
            .onAppear {
                location.requestPermissions()
                location.warmUp()
            }
            .fullScreenCover(item: $launch, onDismiss: finish) { launch in
                switch launch {
                case .trip(let trip, let day):
                    NavigationView(trip: trip, day: day, location: location, voice: voice, pace: settings.pace,
                                   camerasEnabled: settings.radarAnnouncements, traffic: LiveTraffic.client(settings), directions: settings.voiceEnabled,
                                   onFinished: record) { settings.pace = $0 }
                case .destination(let place):
                    FreeRideView(location: location, voice: voice, camerasEnabled: settings.radarAnnouncements, traffic: LiveTraffic.client(settings), directions: settings.voiceEnabled,
                                 destination: place, onFinished: record)
                }
            }
            .sheet(item: $shownRide) { RideSummaryView(ride: $0) }
        }
    }

    private func row(title: String, subtitle: String?, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(tint).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Label("Go", systemImage: "location.north.line.fill")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func go(_ l: Launch) {
        launch = l
    }

    private func record(_ ride: RideLog?) {
        guard let ride else { return }
        pendingRide = RideFinish.record(ride, settings: settings, rides: rides, maintenance: maintenance)
    }

    private func finish() {
        guard let ride = pendingRide else { return }
        shownRide = ride
        pendingRide = nil
        Task { await sync.sync(store: store, rides: rides, settings: settings) }
    }
}
