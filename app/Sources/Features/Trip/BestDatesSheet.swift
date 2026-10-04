import SwiftUI
import TripCore

/// « Trouver la meilleure période » (trip created without dates): the PC compares every start date of the next
/// 12 months on the trip's own roads (passes open, weather of the past years, daylight); the rider picks one.
struct BestDatesSheet: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let tripId: String

    @State private var options: [CompanionClient.DateOption] = []
    @State private var loading = true
    @State private var failure: String?

    private var trip: Trip? { store.trips.first { $0.id == tripId } }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Cols, météo des années passées et durée du jour sur tes routes…").font(.subheadline)
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
        defer { loading = false }
        guard let trip else { return }
        guard let client = CompanionClient(urlString: settings.companionURL, token: settings.companionToken) else {
            failure = "Companion non configuré (Réglages › PC)."
            return
        }
        do {
            options = try await client.bestDates(tripId: trip.id, trip: trip)
        } catch let error as CompanionClient.Failure {
            // The PC explains in French (route to compute first, a road closed all year…).
            failure = Self.message(error)
        } catch {
            failure = "PC injoignable : PC allumé ? Tailscale actif ? (\(error.localizedDescription))"
        }
    }

    private static func message(_ error: CompanionClient.Failure) -> String {
        if case .http(_, let body) = error,
           let detail = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["detail"] as? String {
            return detail
        }
        return error.localizedDescription
    }

    private func choose(_ option: CompanionClient.DateOption) {
        guard var t = trip, t.fixDates(start: option.start, checks: option.checks) else { return }
        store.save(t)
        dismiss()
    }
}

private extension String {
    var lowercasingFirst: String { prefix(1).lowercased() + dropFirst() }
}
