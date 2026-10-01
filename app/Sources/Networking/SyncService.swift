import Foundation
import TripCore

/// iPhone ↔ PC sync (A11), silent and optional: trips (most recent `updatedAt` wins) and ride backups.
/// Runs at launch, when the app comes back to the foreground and after a ride. Never used while riding.
@MainActor
final class SyncService: ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var running = false

    func sync(store: TripStore, rides: RideStore, settings: AppSettings) async {
        guard !running, let client = CompanionClient(urlString: settings.companionURL, token: settings.companionToken) else { return }
        running = true
        defer { running = false }
        do {
            let remote = try await client.listTrips()
            let remoteDates = Dictionary(remote.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
            let plan = TripSync.plan(local: Dictionary(store.trips.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a }),
                                     remote: remoteDates, deleted: store.deletedIds)
            // What failed, in the rider's words (shown under « Synchroniser avec le PC »).
            var failures: [String] = []
            let names = Dictionary(remote.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            func label(_ id: String) -> String {
                "« \(store.trips.first { $0.id == id }?.name ?? names[id] ?? String(id.prefix(8))) »"
            }
            // Deleted on the iPhone: deleted on the PC too; forgotten once the PC no longer has it.
            store.deletedIds = store.deletedIds.filter { remoteDates.keys.contains($0) }
            for id in plan.delete {
                do {
                    try await client.deleteTrip(id)
                    store.deletedIds.remove(id)
                } catch { failures.append("suppression de \(label(id))") }
            }
            for id in plan.push {
                guard let trip = store.trips.first(where: { $0.id == id }) else { continue }
                do { try await client.putTrip(trip) } catch { failures.append("envoi de \(label(id))") }
            }
            for id in plan.pull {
                do { store.save(try await client.getTrip(id), touch: false) } catch { failures.append("\(label(id)) illisible") }
            }
            for var ride in rides.rides where !ride.uploaded {
                do {
                    try await client.putRide(id: ride.id, body: try JSONEncoder().encode(ride))
                    ride.uploaded = true
                    rides.save(ride)
                } catch { failures.append("sauvegarde d'une sortie") }
            }
            var packNote = ""
            do {
                if try await AlertPackStore.shared.refresh(using: client) { packNote = " · radars à jour" }
            } catch { failures.append("base radars") }
            let deletions = plan.delete.isEmpty ? "" : " · 🗑 \(plan.delete.count)"
            let what = "↑ \(plan.push.count) · ↓ \(plan.pull.count)\(deletions)\(packNote)"
            status = failures.isEmpty ? "Synchronisé \(Format.time(Date())) (\(what))"
                : "Synchro partielle : \(failures.prefix(3).joined(separator: ", "))\(failures.count > 3 ? "…" : "")"
        } catch {
            status = "PC injoignable : synchro reportée"
        }
    }
}
