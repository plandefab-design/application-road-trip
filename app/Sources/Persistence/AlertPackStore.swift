import Foundation
import TripCore

/// Every speed camera and hazard of the map, kept on the iPhone (Documents/alerts-pack.json) so riding
/// without an itinerary warns about them offline. Refreshed by the sync when the PC has a newer version.
@MainActor
final class AlertPackStore: ObservableObject {
    /// One pack for the app (read by free rides, refreshed by the sync).
    static let shared = AlertPackStore()

    @Published private(set) var version: String?
    @Published private(set) var cameraCount = 0
    @Published private(set) var hazardCount = 0
    @Published private(set) var updatedAt: Date?
    private(set) var guide: FreeRideGuide?
    private let file: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = docs.appendingPathComponent("alerts-pack.json")
        if let data = try? Data(contentsOf: file), let pack = try? JSONDecoder().decode(AlertPack.self, from: data) {
            load(pack)
            updatedAt = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        }
    }

    private func load(_ pack: AlertPack) {
        version = pack.version
        cameraCount = pack.cameras.count
        hazardCount = pack.hazards.count
        guide = FreeRideGuide(alerts: pack.alerts)
    }

    /// Downloads the pack if the PC has another version. Returns true when it changed.
    @discardableResult
    func refresh(using client: CompanionClient) async throws -> Bool {
        let remote = try await client.alertPackVersion()
        guard !remote.isEmpty, remote != version else { return false }
        let pack = try await client.alertPack()
        let data = try JSONEncoder().encode(pack)
        try data.write(to: file, options: .atomic)
        load(pack)
        updatedAt = Date()
        return true
    }
}
