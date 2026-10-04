import SwiftUI
import TripCore
import UniformTypeIdentifiers

struct TripsListView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var offlineMaps: OfflineMapStore
    @State private var importing = false
    @State private var creating = false
    @State private var exporting: String?
    @State private var viewing: PDFToShow?
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
                            NavigationLink(value: trip.id) {
                                TripRow(trip: trip)
                                    .overlay(alignment: .trailing) {
                                        if exporting == trip.id { ProgressView() }
                                    }
                            }
                                .swipeActions(edge: .leading) {
                                    Button { favorites.toggleTrip(trip.id) } label: {
                                        Label(favorites.isFavoriteTrip(trip.id) ? "Retirer" : "Favori",
                                              systemImage: favorites.isFavoriteTrip(trip.id) ? "star.slash" : "star.fill")
                                    }
                                    .tint(.yellow)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { delete(trip) } label: { Label("Supprimer", systemImage: "trash") }
                                    Button { Task { await exportPDF(trip) } } label: { Label("PDF", systemImage: "doc.richtext") }
                                        .tint(Theme.accent)
                                }
                                .contextMenu {
                                    Button { Task { await exportPDF(trip) } } label: {
                                        Label("Fiche de route (PDF)", systemImage: "doc.richtext")
                                    }
                                    Button { favorites.toggleTrip(trip.id) } label: {
                                        Label(favorites.isFavoriteTrip(trip.id) ? "Retirer des favoris" : "Ajouter aux favoris", systemImage: "star")
                                    }
                                    Button(role: .destructive) { delete(trip) } label: { Label("Supprimer", systemImage: "trash") }
                                }
                        }
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
            .sheet(item: $viewing) { PDFViewer(url: $0.url, title: $0.title) }
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

    /// Road book PDF of any trip (« validé » when its road book is validated, else marked as a draft), then share.
    /// The trip and its offline map (no orphan pack left taking space).
    private func delete(_ trip: Trip) {
        store.delete(trip)
        Task { await offlineMaps.delete(tripId: trip.id) }
    }

    private func exportPDF(_ trip: Trip) async {
        guard exporting == nil else { return }
        exporting = trip.id
        let book = RoadBook.build(trip, pace: settings.pace, validatedAt: RoadBookValidation.shared.validatedAt(trip))
        let url = await RoadBookPDF.render(book, trip: trip)
        exporting = nil
        viewing = PDFToShow(url: url, title: "Feuille de route")
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
            let when = trip.params.datesToChoose ? "Dates à choisir" : "\(trip.params.dateStart) → \(trip.params.dateEnd)"
            Text("\(when) · \(trip.days.count) étape(s) · \(Int(km)) km")
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
