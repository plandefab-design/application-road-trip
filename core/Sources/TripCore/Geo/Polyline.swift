import Foundation

/// Result of projecting a position onto a polyline.
public struct PolylineMatch: Equatable, Sendable {
    /// Index of the segment [i, i+1] the projection falls on.
    public let segmentIndex: Int
    /// Distance from the start of the polyline to the projected point, metres.
    public let distanceAlong: Double
    /// Distance between the position and the projected point, metres.
    public let lateralOffset: Double
    /// The projected point on the polyline.
    public let projected: GeoPoint
}

/// An ordered list of points with cached cumulative distances.
public struct Polyline: Codable, Hashable, Sendable {
    public let points: [GeoPoint]
    /// cumulative[i] = distance from points[0] to points[i], metres.
    public let cumulative: [Double]

    public init(_ points: [GeoPoint]) {
        self.points = points
        var acc: [Double] = []
        acc.reserveCapacity(points.count)
        var total = 0.0
        for (i, p) in points.enumerated() {
            if i > 0 { total += Geo.distance(points[i - 1], p) }
            acc.append(total)
        }
        self.cumulative = acc
    }

    enum CodingKeys: String, CodingKey { case points }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode([GeoPoint].self, forKey: .points))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
    }

    public var length: Double { cumulative.last ?? 0 }
    public var isEmpty: Bool { points.count < 2 }

    /// Point located `distance` metres from the start (clamped to the polyline).
    public func point(at distance: Double) -> GeoPoint? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return first }
        let d = min(max(distance, 0), length)
        // Binary search for the segment.
        var lo = 0, hi = cumulative.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= d { lo = mid } else { hi = mid }
        }
        let segLen = cumulative[hi] - cumulative[lo]
        let t = segLen > 0 ? (d - cumulative[lo]) / segLen : 0
        return Geo.interpolate(points[lo], points[hi], t)
    }

    /// Resamples the polyline at a fixed step (metres). Keeps first and last points.
    public func resampled(every step: Double) -> Polyline {
        guard step > 0, points.count > 1, length > 0 else { return self }
        var out: [GeoPoint] = []
        var d = 0.0
        while d < length {
            if let p = point(at: d) { out.append(p) }
            d += step
        }
        if let last = points.last { out.append(last) }
        return Polyline(out)
    }

    /// Sub-polyline between two distances along the line.
    public func slice(from start: Double, to end: Double) -> Polyline {
        guard points.count > 1 else { return self }
        let a = min(max(start, 0), length), b = min(max(end, 0), length)
        guard b > a, let pa = point(at: a), let pb = point(at: b) else { return Polyline([]) }
        var out = [pa]
        for (i, p) in points.enumerated() where cumulative[i] > a && cumulative[i] < b {
            out.append(p)
        }
        out.append(pb)
        return Polyline(out)
    }

    /// Projects `p` onto the polyline.
    /// - Parameter hint: optional distance-along to search around first (keeps matching stable on hairpins
    ///   where two distant parts of the road are close in space).
    /// - Parameter window: search radius along the line around `hint`, metres.
    public func locate(_ p: GeoPoint, hint: Double? = nil, window: Double = 2_000) -> PolylineMatch? {
        guard points.count > 1 else { return nil }
        var range = 0..<(points.count - 1)
        if let hint {
            let lo = firstIndex(atOrAfter: hint - window)
            let hi = firstIndex(atOrAfter: hint + window)
            let lower = max(0, min(lo - 1, points.count - 2))
            let upper = min(points.count - 1, max(hi, lower + 1))
            range = lower..<upper
        }
        var best: PolylineMatch?
        for i in range {
            let a = points[i], b = points[i + 1]
            let pa = Geo.toLocal(a, origin: a)
            let pb = Geo.toLocal(b, origin: a)
            let pp = Geo.toLocal(p, origin: a)
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? ((pp.x - pa.x) * dx + (pp.y - pa.y) * dy) / len2 : 0
            t = min(max(t, 0), 1)
            let proj = Geo.interpolate(a, b, t)
            let offset = Geo.distance(p, proj)
            if best == nil || offset < best!.lateralOffset {
                let along = cumulative[i] + (cumulative[i + 1] - cumulative[i]) * t
                best = PolylineMatch(segmentIndex: i, distanceAlong: along, lateralOffset: offset, projected: proj)
            }
        }
        return best
    }

    /// Bearing of the line at a given distance along it.
    public func bearing(at distance: Double) -> Double? {
        guard points.count > 1 else { return nil }
        let i = max(0, min(firstIndex(atOrAfter: distance) - 1, points.count - 2))
        return Geo.bearing(points[i], points[i + 1])
    }

    /// Total positive elevation gain, metres (0 if no elevation data).
    public var ascent: Double {
        var total = 0.0
        for i in 1..<max(points.count, 1) {
            if let a = points[i - 1].ele, let b = points[i].ele, b > a { total += b - a }
        }
        return total
    }

    func firstIndex(atOrAfter d: Double) -> Int {
        var lo = 0, hi = cumulative.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] < d { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
