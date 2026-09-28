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
            let plan = TripSync.plan(local: Dictionary(uniqueKeysWithValues: store.trips.map { ($0.id, $0.updatedAt) }),
                                     remote: Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0.updatedAt) }))
            var failures = 0
            for id in plan.push {
                guard let trip = store.trips.first(where: { $0.id == id }) else { continue }
                do { try await client.putTrip(trip) } catch { failures += 1 }
            }
            for id in plan.pull {
                do { store.save(try await client.getTrip(id), touch: false) } catch { failures += 1 }
            }
            for var ride in rides.rides where !ride.uploaded {
                do {
                    try await client.putRide(id: ride.id, body: try JSONEncoder().encode(ride))
                    ride.uploaded = true
                    rides.save(ride)
                } catch { failures += 1 }
            }
            var packNote = ""
            do {
                if try await AlertPackStore.shared.refresh(using: client) { packNote = " · radars à jour" }
            } catch { failures += 1 }
            let what = "↑ \(plan.push.count) · ↓ \(plan.pull.count)\(packNote)"
            status = failures == 0 ? "Synchronisé \(Format.time(Date())) (\(what))" : "Synchro partielle (\(failures) erreur(s))"
        } catch {
            status = "PC injoignable : synchro reportée"
        }
    }
}
