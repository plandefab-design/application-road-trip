import CoreLocation
import Foundation
import MapLibre
import TripCore

/// Offline map of a trip (A7) and its integrity check (A8), with MapLibre offline packs of the same style as
/// the live map, so the map keeps working in airplane mode. Views only use this adapter (CLAUDE.md rule 4).
/// - overview of the whole area (bounding box + 10 km), zoom 0–11;
/// - detail along each day's track, zoom 12–14 (OpenFreeMap's maximum; the map over-zooms beyond).
@MainActor
final class OfflineMapStore: ObservableObject {
    struct Status: Equatable {
        var fraction: Double
        var bytes: UInt64
        var complete: Bool
        var downloading: Bool
        var error: String?
    }

    enum Failure: LocalizedError {
        case noTrack, invalidPack
        var errorDescription: String? {
            switch self {
            case .noTrack: "Aucune étape tracée : calcule d'abord le tracé."
            case .invalidPack: "Téléchargement interrompu par la carte : réessaie."
            }
        }
    }

    /// Status by trip id (nil: nothing downloaded).
    @Published private(set) var status: [String: Status] = [:]

    private struct Context: Codable { let tripId: String; let part: String }
    private var storage: MLNOfflineStorage { MLNOfflineStorage.shared }

    // MARK: Queries

    /// The pack list is nil until MapLibre has read its database (shortly after launch).
    private func loadedPacks() async -> [MLNOfflinePack] {
        for _ in 0..<50 {
            if let packs = storage.packs { return packs }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return storage.packs ?? []
    }

    private func packs(for tripId: String, in all: [MLNOfflinePack]) -> [MLNOfflinePack] {
        all.filter { (try? JSONDecoder().decode(Context.self, from: $0.context))?.tripId == tripId }
    }

    private static func summarize(_ packs: [MLNOfflinePack], downloading: Bool, error: String? = nil) -> Status {
        let done = packs.reduce(UInt64(0)) { $0 + $1.progress.countOfResourcesCompleted }
        let expected = packs.reduce(UInt64(0)) { $0 + max($1.progress.countOfResourcesExpected, 1) }
        let bytes = packs.reduce(UInt64(0)) { $0 + $1.progress.countOfBytesCompleted }
        // Integrity (A8): every resource the region needs is stored.
        let complete = !packs.isEmpty && packs.allSatisfy {
            $0.state == .complete
                || ($0.progress.countOfResourcesExpected > 0 && $0.progress.countOfResourcesCompleted >= $0.progress.countOfResourcesExpected)
        }
        return Status(fraction: min(1, Double(done) / Double(max(expected, 1))), bytes: bytes,
                      complete: complete, downloading: downloading && !complete, error: error)
    }

    /// Re-reads the stored packs of a trip (call when the trip screen appears, and the day before leaving).
    func refresh(tripId: String) async {
        guard status[tripId]?.downloading != true else { return }
        let packs = packs(for: tripId, in: await loadedPacks())
        guard !packs.isEmpty else { status[tripId] = nil; return }
        packs.forEach { $0.requestProgress() }
        try? await Task.sleep(for: .milliseconds(400))
        status[tripId] = Self.summarize(packs, downloading: false)
    }

    // MARK: Download / delete

    /// Downloads (again) the whole trip. Returns when every pack is complete.
    func download(trip: Trip) async throws {
        let tracks = trip.days.compactMap(\.track).filter { !$0.isEmpty }
        guard !tracks.isEmpty, let area = OfflineArea.bounds(tracks.flatMap(\.points)) else { throw Failure.noTrack }
        await delete(tripId: trip.id)          // tracks may have changed since the last download
        status[trip.id] = Status(fraction: 0, bytes: 0, complete: false, downloading: true)

        var regions: [(region: MLNOfflineRegion, part: String)] = []
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: area.minLat, longitude: area.minLon),
                                         ne: CLLocationCoordinate2D(latitude: area.maxLat, longitude: area.maxLon))
        regions.append((MLNTilePyramidOfflineRegion(styleURL: TripMapView.styleURL, bounds: bounds,
                                                    fromZoomLevel: 0, toZoomLevel: 11), "overview"))
        for (i, track) in tracks.enumerated() {
            var coords = track.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let line = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
            regions.append((MLNShapeOfflineRegion(styleURL: TripMapView.styleURL, shape: line,
                                                  fromZoomLevel: 12, toZoomLevel: 14), "day\(i + 1)"))
        }

        var created: [MLNOfflinePack] = []
        do {
            for item in regions {
                let context = try JSONEncoder().encode(Context(tripId: trip.id, part: item.part))
                let pack: MLNOfflinePack = try await withCheckedThrowingContinuation { cont in
                    storage.addPack(for: item.region, withContext: context) { pack, error in
                        if let pack { cont.resume(returning: pack) } else { cont.resume(throwing: error ?? Failure.invalidPack) }
                    }
                }
                pack.resume()
                created.append(pack)
            }
            // MapLibre downloads in the background and retries failed resources itself.
            while true {
                try await Task.sleep(for: .seconds(1))
                let s = Self.summarize(created, downloading: true)
                status[trip.id] = s
                if s.complete { return }
                if created.contains(where: { $0.state == .invalid }) { throw Failure.invalidPack }
            }
        } catch {
            created.forEach { if $0.state != .invalid { $0.suspend() } }
            status[trip.id] = Self.summarize(created, downloading: false, error: error.localizedDescription)
            throw error
        }
    }

    func delete(tripId: String) async {
        for pack in packs(for: tripId, in: await loadedPacks()) {
            await withCheckedContinuation { cont in
                storage.removePack(pack) { _ in cont.resume() }
            }
        }
        status[tripId] = nil
    }
}
