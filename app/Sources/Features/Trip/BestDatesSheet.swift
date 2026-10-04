import SwiftUI
import TripCore

/// « Trouver la meilleure période » (trip created without dates): the iPhone compares every start date of the next
/// 12 months on the trip's own roads (passes open, weather of the past years, daylight), without the PC; the rider
/// picks one. Needs the network once (closures and weather history are then cached).
struct BestDatesSheet: View {
    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss
    let tripId: String

    @State private var options: [DateOption] = []
    @State private var step: String? = "Cols et routes à fermeture saisonnière…"
    @State private var failure: String?

    private var trip: Trip? { store.trips.first { $0.id == tripId } }

    var body: some View {
        NavigationStack {
            List {
                if let step {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(step).font(.subheadline)
                    }
                    .listRowBackground(Theme.row)
                } else if let failure {
                    Text(failure).font(.subheadline).foregroundStyle(.orange).listRowBackground(Theme.row)
                }
                ForEach(Array(options.enumerated()), id: \.element.id) { rank, option in
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(option.reasons, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.footnote) }
                            ForEach(option.checks, id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                        }
                        .listRowBackground(Theme.row)
                        Button { choose(option) } label: {
                            Label("Partir \(option.label.lowercasingFirst)", systemImage: "calendar.badge.checkmark")
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(rank == 0 ? Theme.accent : .gray)
                        .listRowBackground(Color.clear)
                    } header: {
                        Text(rank == 0 ? "\(option.label) · la meilleure" : option.label)
                    }
                }
            }
            .motoList()
            .navigationTitle("Meilleure période")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        defer { step = nil }
        guard let trip else { return }
        let pack: SeasonPack
        do {
            pack = try await SeasonData.pack()
        } catch {
            failure = "Pas de réseau : il faut internet une fois pour les cols et la météo des années passées."
            return
        }
        let stages = await Task.detached { BestPeriods.stages(of: trip, pack: pack) }.value
        guard !stages.isEmpty else {
            failure = "Calcule d'abord le tracé : la meilleure période dépend des routes de chaque étape."
            return
        }
        let today = CalendarDay(Date(), timeZone: .current)
        var climates: [Climate?] = []
        for (k, stage) in stages.enumerated() {
            step = "Météo des \(Climate.years) dernières années vers \(stage.place) (\(k + 1)/\(stages.count))…"
            climates.append(await SeasonData.climate(at: stage.spot, today: today))
        }
        step = "Comparaison des 12 prochains mois…"
        let found = await Task.detached { BestPeriods.options(trip: trip, stages: stages, climates: climates, today: today) }.value
        if found.isEmpty {
            failure = "Aucune période possible dans les 12 prochains mois : une route du trip reste fermée."
        } else if climates.contains(where: { $0 == nil }) {
            failure = "Météo des années passées indisponible pour une étape : comparée sur les cols et la durée du jour."
        }
        options = found
    }

    private func choose(_ option: DateOption) {
        guard var t = trip, t.fixDates(start: option.start, checks: option.checks) else { return }
        store.save(t)
        dismiss()
    }
}

private extension String {
    var lowercasingFirst: String { prefix(1).lowercased() + dropFirst() }
}
