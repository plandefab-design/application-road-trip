import SwiftUI
import TripCore
import UniformTypeIdentifiers

struct TripsListView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @State private var importing = false
    @State private var creating = false
    @ObservedObject private var favorites = FavoritePlaces.shared

    private static let gpxType = UTType(filenameExtension: "gpx") ?? .xml

    var body: some View {
        NavigationStack {
            Group {
                if store.trips.isEmpty {
                    ContentUnavailableView {
                        Label("Aucun trip", systemImage: "map")
                    } description: {
                        Text("Prépare ton road trip avec Claude (routes, étapes, pleins, repas, hébergements), ou importe un GPX.")
                    } actions: {
                        Button("Nouveau trip") { creating = true }.buttonStyle(.borderedProminent)
                        Button("Importer un fichier") { importing = true }
                    }
                } else {
                    List {
                        ForEach(store.trips) { trip in
                            NavigationLink(value: trip.id) { TripRow(trip: trip) }
                                .swipeActions(edge: .leading) {
                                    Button { favorites.toggleTrip(trip.id) } label: {
                                        Label(favorites.isFavoriteTrip(trip.id) ? "Retirer" : "Favori",
                                              systemImage: favorites.isFavoriteTrip(trip.id) ? "star.slash" : "star.fill")
                                    }
                                    .tint(.yellow)
                                }
                        }
                        .onDelete { idx in idx.map { store.trips[$0] }.forEach(store.delete) }
                    }
                }
            }
            .motoList()
            .navigationTitle("Mes trips")
            .navigationDestination(for: String.self) { id in
                TripDetailView(tripId: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("Importer un GPX ou un trip")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Label("Nouveau", systemImage: "plus.circle.fill").labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
            }
            .sheet(isPresented: $creating) { CreateTripView().environmentObject(store).environmentObject(settings) }
            .sheet(isPresented: $importing) {
                DocumentPicker(types: [Self.gpxType, .json],
                               onPick: { urls in urls.forEach(store.importFile) },
                               onClose: { importing = false })
                    .ignoresSafeArea()
            }
            .alert("Erreur", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
        }
    }
}

struct TripRow: View {
    @ObservedObject private var favorites = FavoritePlaces.shared
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trip.name).font(.headline)
                if favorites.isFavoriteTrip(trip.id) { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                Spacer()
                StatusBadge(status: trip.status)
            }
            let km = trip.days.compactMap(\.distanceKm).reduce(0, +)
            Text("\(trip.params.dateStart) → \(trip.params.dateEnd) · \(trip.days.count) étape(s) · \(Int(km)) km")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct StatusBadge: View {
    let status: TripStatus

    var body: some View {
        Text(label).font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String { Self.label(for: status) }

    static func label(for status: TripStatus) -> String {
        switch status {
        case .draft: "Brouillon"
        case .proposed: "Proposé"
        case .validated: "Validé"
        case .ready: "Prêt"
        case .active: "En cours"
        case .done: "Terminé"
        }
    }

    private var color: Color {
        switch status {
        case .draft, .proposed: .gray
        case .validated: .blue
        case .ready: .green
        case .active: .orange
        case .done: .purple
        }
    }
}
