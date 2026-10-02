import Foundation

/// Area of a trip to keep offline (A7): the tracks' bounding box plus a margin for detours and plan B.
public enum OfflineArea {
    public struct Bounds: Equatable, Sendable {
        public let minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    }

    public static func bounds(_ points: [GeoPoint], marginKm: Double = 10) -> Bounds? {
        guard let first = points.first else { return nil }
        var b = (minLat: first.lat, minLon: first.lon, maxLat: first.lat, maxLon: first.lon)
        for p in points.dropFirst() {
            b.minLat = min(b.minLat, p.lat); b.maxLat = max(b.maxLat, p.lat)
            b.minLon = min(b.minLon, p.lon); b.maxLon = max(b.maxLon, p.lon)
        }
        let dLat = marginKm / 111.2
        let dLon = marginKm / (111.2 * max(0.1, cos((b.minLat + b.maxLat) / 2 * .pi / 180)))
        return Bounds(minLat: max(-85, b.minLat - dLat), minLon: max(-180, b.minLon - dLon),
                      maxLat: min(85, b.maxLat + dLat), maxLon: min(180, b.maxLon + dLon))
    }
}

extension OfflineArea {
    /// Days an offline map is kept after the trip's last day (the ride home, a late summary), then freed.
    public static let keepAfterTrip = 7

    /// Offline map ids to delete: trips deleted, and trips ended more than `keepAfterTrip` days before `today`.
    /// Downloadable again from the trip. `packTripIds`: the trips the stored packs belong to.
    public static func stalePacks(_ packTripIds: Set<String>, trips: [Trip], today: Date = Date()) -> Set<String> {
        let limit = today.addingTimeInterval(-Double(keepAfterTrip) * 86_400)
        let kept = trips.filter { trip in
            guard let end = ISODate.parse(trip.params.dateEnd) else { return true }     // no valid date: keep
            return end.addingTimeInterval(86_400) > limit
        }
        return packTripIds.subtracting(kept.map(\.id))
    }
}
