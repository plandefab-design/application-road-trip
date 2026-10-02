import SwiftUI
import TripCore

/// Every recorded ride (with or without an itinerary), newest first, grouped by month.
struct RidesListView: View {
    @EnvironmentObject private var rides: RideStore
    @State private var shown: RideLog?
    @State private var renaming: RideLog?

    var body: some View {
        List {
            if rides.rides.isEmpty {
                ContentUnavailableView("Aucune sortie enregistrée", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
                                       description: Text("Chaque navigation, avec ou sans itinéraire, est enregistrée ici avec sa trace réelle."))
            } else {
                Section {
                    LabeledContent("Total", value: "\(Format.distance(rides.rides.reduce(0) { $0 + $1.summary.distance })) · \(rides.rides.count) sortie(s)")
                    LabeledContent("Virages", value: "\(rides.rides.reduce(0) { $0 + $1.summary.bends })")
                }
                let favorites = rides.rides.filter(\.isFavorite)
                if !favorites.isEmpty {
                    Section {
                        ForEach(favorites) { ride in
                            Button { shown = ride } label: { row(ride) }.buttonStyle(.plain)
                                .swipeActions(edge: .leading) {
                                    starAction(ride)
                                    renameAction(ride)
                                }
                                .contextMenu { renameAction(ride) }
                        }
                    } header: {
                        Label("Favoris", systemImage: "star.fill")
                    } footer: {
                        Text("Ouvre un favori › « Refaire ce trajet » pour le rouler comme un trip.")
                    }
                }
                ForEach(months, id: \.self) { month in
                    Section(month) {
                        ForEach(rides.rides.filter { monthLabel($0) == month }) { ride in
                            Button { shown = ride } label: { row(ride) }.buttonStyle(.plain)
                                .swipeActions(edge: .leading) {
                                    starAction(ride)
                                    renameAction(ride)
                                }
                                .contextMenu { renameAction(ride) }
                        }
                        .onDelete { idx in
                            let inMonth = rides.rides.filter { monthLabel($0) == month }
                            idx.map { inMonth[$0] }.forEach(rides.delete)
                        }
                    }
                }
            }
        }
        .motoList()
        .navigationTitle("Mes sorties")
        .sheet(item: $shown) { RideSummaryView(ride: $0) }
        .renameRideAlert($renaming, rides: rides)
    }

    private func renameAction(_ ride: RideLog) -> some View {
        Button { renaming = ride } label: { Label("Renommer", systemImage: "pencil") }
            .tint(Theme.info)
    }

    private func starAction(_ ride: RideLog) -> some View {
        Button { rides.toggleFavorite(ride) } label: {
            Label(ride.isFavorite ? "Retirer" : "Favori", systemImage: ride.isFavorite ? "star.slash" : "star.fill")
        }
        .tint(.yellow)
    }

    private var months: [String] {
        var seen: [String] = []
        for r in rides.rides where !seen.contains(monthLabel(r)) { seen.append(monthLabel(r)) }
        return seen
    }

    private func monthLabel(_ ride: RideLog) -> String {
        (ride.summary.startedAt ?? .distantPast).formatted(.dateTime.month(.wide).year()).capitalized
    }

    private func row(_ ride: RideLog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ride.tripId == RideStore.freeRideTripId ? "location.north.line.fill" : "map.fill")
                .foregroundStyle(.orange).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(ride.title)
                    .font(.subheadline.bold())
                Text("\(ride.summary.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "") · \(Format.distance(ride.summary.distance)) · \(ride.summary.bends) virages")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ride.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            Image(systemName: ride.uploaded ? "checkmark.icloud" : "icloud.and.arrow.up").foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// « Renommer » for a ride: the rider's own name (empty = back to « Balade libre » or the trip's name).
    func renameRideAlert(_ ride: Binding<RideLog?>, rides: RideStore) -> some View {
        modifier(RenameRideAlert(ride: ride, rides: rides))
    }
}

private struct RenameRideAlert: ViewModifier {
    @Binding var ride: RideLog?
    let rides: RideStore
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("Nom de la sortie", isPresented: Binding(get: { ride != nil }, set: { if !$0 { ride = nil } })) {
                TextField("Ex. Tour du Luberon", text: $text)
                Button("Enregistrer") {
                    if let ride { rides.rename(ride, to: text) }
                    ride = nil
                }
                Button("Annuler", role: .cancel) { ride = nil }
            } message: {
                Text("Laisse vide pour revenir au nom automatique.")
            }
            .onChange(of: ride?.id) { _, _ in text = ride?.name ?? "" }
    }
}
