import Foundation
import TripCore

/// Every speed camera and hazard of the map, kept on the iPhone (Documents/alerts-pack.json) so riding
/// without an itinerary warns about them offline. Downloaded from GitHub (no PC) when a newer version is published.
@MainActor
final class AlertPackStore: ObservableObject {
    /// One pack for the app (read by free rides, refreshed when the app opens).
    static let shared = AlertPackStore()

    @Published private(set) var version: String?
    @Published private(set) var cameraCount = 0
    @Published private(set) var hazardCount = 0
    @Published private(set) var updatedAt: Date?
    private(set) var guide: FreeRideGuide?
    private let file: URL
    private var checkedAt: Date?
    private var refreshing = false

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = docs.appendingPathComponent("alerts-pack.json")
        self.file = file
        // Tens of thousands of cameras: read and indexed off the main thread, the app opens without waiting.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = try? Data(contentsOf: file), let decoded = Self.decode(data) else { return }
            let date = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
            await self?.load(decoded.pack, guide: decoded.guide, date: date)
        }
    }

    nonisolated private static func decode(_ data: Data) -> (pack: AlertPack, guide: FreeRideGuide)? {
        guard let pack = try? JSONDecoder().decode(AlertPack.self, from: data) else { return nil }
        return (pack, FreeRideGuide(alerts: pack.alerts))
    }

    private func load(_ pack: AlertPack, guide: FreeRideGuide, date: Date?) {
        version = pack.version
        cameraCount = pack.cameras.count
        hazardCount = pack.hazards.count
        self.guide = guide
        updatedAt = date
    }

    /// Downloads the pack when GitHub has another version; at most one check an hour. Silent: offline, the
    /// stored pack stays in use. Returns true when it changed.
    @discardableResult
    func refresh() async -> Bool {
        guard !refreshing, checkedAt.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true else { return false }
        refreshing = true
        defer { refreshing = false }
        guard let manifest = try? await DataPack.manifest() else { return false }
        checkedAt = Date()
        guard manifest.alerts.version != version, let data = try? await DataPack.download(manifest.alerts) else { return false }
        guard let decoded = await Task.detached(operation: { Self.decode(data) }).value else { return false }
        try? data.write(to: file, options: .atomic)
        load(decoded.pack, guide: decoded.guide, date: Date())
        return true
    }
}
