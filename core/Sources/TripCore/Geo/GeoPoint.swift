import Foundation

/// WGS84 coordinate. Deliberately independent from CoreLocation so TripCore builds on Windows/Linux.
public struct GeoPoint: Codable, Hashable, Sendable {
    public var lat: Double
    public var lon: Double
    /// Elevation in metres, when known.
    public var ele: Double?

    public init(lat: Double, lon: Double, ele: Double? = nil) {
        self.lat = lat
        self.lon = lon
        self.ele = ele
    }

    public var isValid: Bool {
        lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon)
    }
}

public enum Geo {
    /// Mean Earth radius (IUGG), metres.
    public static let earthRadius = 6_371_008.8

    static func rad(_ deg: Double) -> Double { deg * .pi / 180 }
    static func deg(_ rad: Double) -> Double { rad * 180 / .pi }

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLat = rad(b.lat - a.lat)
        let dLon = rad(b.lon - a.lon)
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.lat)) * cos(rad(b.lat)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from a to b, degrees in [0, 360).
    public static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let φ1 = rad(a.lat), φ2 = rad(b.lat), Δλ = rad(b.lon - a.lon)
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let θ = deg(atan2(y, x))
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Smallest signed angle difference b - a, in (-180, 180].
    public static func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Linear interpolation between two points (accurate enough for segments < a few km).
    public static func interpolate(_ a: GeoPoint, _ b: GeoPoint, _ t: Double) -> GeoPoint {
        let ele: Double?
        if let ea = a.ele, let eb = b.ele { ele = ea + (eb - ea) * t } else { ele = nil }
        return GeoPoint(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t, ele: ele)
    }

    /// Local equirectangular projection around `origin`, metres (x east, y north).
    static func toLocal(_ p: GeoPoint, origin: GeoPoint) -> (x: Double, y: Double) {
        let x = rad(p.lon - origin.lon) * cos(rad(origin.lat)) * earthRadius
        let y = rad(p.lat - origin.lat) * earthRadius
        return (x, y)
    }
}
