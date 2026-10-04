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
    /// Garage bike credited with the km (« Ma moto »).
    var bikeId: String?
    var uploaded: Bool = false
    /// Marked ⭐ by the rider (optional so older ride files still decode).
    var favorite: Bool?
    /// Name given by the rider (« Tour du Luberon »); nil = the automatic one.
    var name: String?

    var isFavorite: Bool { favorite == true }

    /// What the lists and the summary show: the rider's name, else « Balade libre » or « Trip · jour 2 ».
    var title: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return tripId == RideStore.freeRideTripId ? "Balade libre" : "\(tripName) · jour \(day)"
    }

    /// A trip built from the real recorded track, to ride it again (« Refaire ce trajet »).
    func asTrip() -> Trip {
        let first = track.first, last = track.last
        let loop = first.flatMap { f in last.map { Geo.distance(f, $0) < 1_000 } } ?? true
        let today = ISODate.format(Date())
        let label = name.flatMap { $0.isEmpty ? nil : $0 } ?? (tripId == RideStore.freeRideTripId ? "Balade" : tripName)
        let date = summary.startedAt?.formatted(.dateTime.day().month(.abbreviated)) ?? ""
        let params = TripParams(start: Place(name: "Départ", point: first),
                                end: loop ? nil : Place(name: "Arrivée", point: last),
                                dateStart: today, dateEnd: today)
        let day = TripDay(index: 1, date: today, distanceKm: (summary.distance / 1000).rounded(),
                          drivingTimeMin: (summary.movingTime / 60).rounded(), track: Polyline(track))
        return Trip(name: "⭐ \(label) du \(date)", status: .ready, params: params, days: [day])
    }
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

    func toggleFavorite(_ ride: RideLog) {
        guard var r = rides.first(where: { $0.id == ride.id }) else { return }
        r.favorite = !r.isFavorite
        save(r)
    }

    /// Rider's own name (empty = back to the automatic one); saved again on the PC at the next sync.
    func rename(_ ride: RideLog, to name: String) {
        guard var r = rides.first(where: { $0.id == ride.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        r.name = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
        r.uploaded = false
        save(r)
    }

    /// Builds the log of a finished ride; nil for a ride shorter than 200 m (test start, mistake).
    static func log(trip: Trip, day: TripDay, points: [GeoPoint], times: [Date], speeds: [Double], lean: LeanSummary? = nil,
                    bikeId: String? = nil) -> RideLog? {
        log(tripId: trip.id, tripName: trip.name, day: day.index, points: points, times: times, speeds: speeds, lean: lean, bikeId: bikeId)
    }

    /// Ride without an itinerary (« balade libre »).
    static let freeRideTripId = "free-ride"

    static func log(tripId: String, tripName: String, day: Int, points: [GeoPoint], times: [Date], speeds: [Double],
                    lean: LeanSummary? = nil, bikeId: String? = nil) -> RideLog? {
        var summary = RideSummary.summarize(points: points, times: times, speeds: speeds)
        summary.lean = lean
        guard summary.distance >= 200 else { return nil }
        let stamp = Int((summary.startedAt ?? Date()).timeIntervalSince1970)
        let thinned = points.enumerated().filter { $0.offset % 3 == 0 || $0.offset == points.count - 1 }.map(\.element)
        return RideLog(id: "\(tripId.prefix(8))-j\(day)-\(stamp)", tripId: tripId, tripName: tripName,
                       day: day, summary: summary, track: thinned, bikeId: bikeId)
    }
}
