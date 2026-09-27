import Foundation
@testable import TripCore

/// Synthetic geometry only — no real-world facts.
enum Fixtures {
    /// ≈ metres per degree of latitude with Geo.earthRadius.
    static let mPerDegLat = 2 * Double.pi * Geo.earthRadius / 360

    /// Straight line going north from (lat0, lon0), `km` long, one point every `stepM` metres.
    static func northLine(km: Double, stepM: Double = 100, lat0: Double = 44.0, lon0: Double = 6.0) -> Polyline {
        let n = Int(km * 1000 / stepM)
        return Polyline((0...n).map { GeoPoint(lat: lat0 + Double($0) * stepM / mPerDegLat, lon: lon0) })
    }

    /// Zig-zag heading north with 90° turns every `legM` metres (very twisty).
    static func zigzag(km: Double, legM: Double = 30, lat0: Double = 44.0, lon0: Double = 6.0) -> Polyline {
        var pts = [GeoPoint(lat: lat0, lon: lon0)]
        let mPerDegLon = mPerDegLat * cos(lat0 * .pi / 180)
        let legs = Int(km * 1000 / legM)
        var lat = lat0, lon = lon0
        for i in 0..<legs {
            // alternate north-east / north-west diagonals
            let d = legM / sqrt(2)
            lat += d / mPerDegLat
            lon += (i % 2 == 0 ? d : -d) / mPerDegLon
            pts.append(GeoPoint(lat: lat, lon: lon))
        }
        return Polyline(pts)
    }

    static func point(onNorthLineAtKm km: Double, eastOffsetM: Double = 0, lat0: Double = 44.0, lon0: Double = 6.0) -> GeoPoint {
        let mPerDegLon = mPerDegLat * cos(lat0 * .pi / 180)
        return GeoPoint(lat: lat0 + km * 1000 / mPerDegLat, lon: lon0 + eastOffsetM / mPerDegLon)
    }

    static func params(bikes: [Bike] = [Bike(model: "Test", rangeKm: 250)]) -> TripParams {
        TripParams(start: Place(name: "A", point: GeoPoint(lat: 44, lon: 6)),
                   end: Place(name: "B", point: GeoPoint(lat: 45, lon: 6)),
                   dateStart: "2027-06-01", dateEnd: "2027-06-03",
                   zone: ["FR-ALPES-SUD"], bikes: bikes)
    }
}
