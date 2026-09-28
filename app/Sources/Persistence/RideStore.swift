import Foundation
import TripCore

/// A ride actually ridden: summary + real track (thinned), kept on the iPhone and backed up on the PC.
struct RideLog: Codable, Identifiable, Equatable {
    let id: String
    let tripId: String
    let tripName: String
    let day: Int
    let summary: RideSummary
    let track: [GeoPoint]
    var uploaded: Bool = false
}

/// Rides saved in Documents/rides (one file each), newest first.
@MainActor
final class RideStore: ObservableObject {
    @Published private(set) var rides: [RideLog] = []
    private let folder: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("rides", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        rides = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? decoder.decode(RideLog.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.summary.startedAt ?? .distantPast) > ($1.summary.startedAt ?? .distantPast) }
    }

    func save(_ ride: RideLog) {
        guard let data = try? JSONEncoder().encode(ride) else { return }
        try? data.write(to: folder.appendingPathComponent("\(ride.id).json"), options: .atomic)
        if let i = rides.firstIndex(where: { $0.id == ride.id }) { rides[i] = ride } else { rides.insert(ride, at: 0) }
    }

    func delete(_ ride: RideLog) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(ride.id).json"))
        rides.removeAll { $0.id == ride.id }
    }

    func rides(for tripId: String) -> [RideLog] { rides.filter { $0.tripId == tripId } }

    /// Builds the log of a finished ride; nil for a ride shorter than 200 m (test start, mistake).
    static func log(trip: Trip, day: TripDay, points: [GeoPoint], times: [Date], speeds: [Double]) -> RideLog? {
        let summary = RideSummary.summarize(points: points, times: times, speeds: speeds)
        guard summary.distance >= 200 else { return nil }
        let stamp = Int((summary.startedAt ?? Date()).timeIntervalSince1970)
        let thinned = points.enumerated().filter { $0.offset % 3 == 0 || $0.offset == points.count - 1 }.map(\.element)
        return RideLog(id: "\(trip.id.prefix(8))-j\(day.index)-\(stamp)", tripId: trip.id, tripName: trip.name,
                       day: day.index, summary: summary, track: thinned)
    }
}
