import Foundation

/// Curviness score of a route (SPEC §5.6).
///
/// raw = Σ|Δbearing| / distance (degrees per km) on a geometry resampled every `step` metres.
/// score = min(100, raw / saturation × 100).
/// `saturation` must be calibrated against reference roads (spike S4: Combe de Lourmarin, Bonnette…).
public enum Curvature {
    public static let step = 10.0
    /// Degrees/km considered "maximum twisty" — provisional value, calibrate in S4.
    public static let saturationDegPerKm = 500.0
    /// Ignore heading changes larger than this between two samples (GPS noise / U-turns).
    static let maxDelta = 120.0

    public static func degreesPerKm(_ line: Polyline) -> Double {
        guard line.length > step * 2 else { return 0 }
        let r = line.resampled(every: step)
        var total = 0.0
        var prev: Double?
        for i in 1..<r.points.count {
            guard Geo.distance(r.points[i - 1], r.points[i]) > 1 else { continue }
            let b = Geo.bearing(r.points[i - 1], r.points[i])
            if let p = prev {
                let d = abs(Geo.angleDelta(p, b))
                if d <= maxDelta { total += d }
            }
            prev = b
        }
        return total / (line.length / 1000)
    }

    public static func score(_ line: Polyline) -> Double {
        min(100, degreesPerKm(line) / saturationDegPerKm * 100)
    }
}
