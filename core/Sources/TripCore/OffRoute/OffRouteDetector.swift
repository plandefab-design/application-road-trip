import Foundation

/// Off-route detection with hysteresis (SPEC §5.7).
///
/// Off route when lateral offset > `threshold` for ≥ `minDuration` seconds OR ≥ `minSamples` consecutive samples;
/// sooner after a missed turn: offset > `fastThreshold` while riding ≥ `fastHeading`° away from the route's direction
/// for `fastSamples` consecutive samples (about 2 s).
/// Back on route when offset < `recoverThreshold` for `recoverSamples` consecutive samples.
public struct OffRouteDetector: Sendable {
    public enum State: Equatable, Sendable { case onRoute, offRoute }

    public var threshold = 40.0
    public var recoverThreshold = 25.0
    public var minDuration: TimeInterval = 5
    public var minSamples = 3
    public var recoverSamples = 2
    public var fastThreshold = 25.0
    public var fastHeading = 50.0
    public var fastSamples = 2

    public private(set) var state: State = .onRoute
    private var outSince: TimeInterval?
    private var outCount = 0
    private var fastCount = 0
    private var inCount = 0

    public init() {}

    /// - Parameters:
    ///   - lateralOffset: metres between GPS fix and the route
    ///   - time: monotonic timestamp, seconds
    ///   - accuracy: GPS horizontal accuracy, metres (poor fixes are ignored)
    ///   - headingDelta: angle between the rider's course and the route's direction, degrees (nil when slow or unknown)
    @discardableResult
    public mutating func update(lateralOffset: Double, time: TimeInterval, accuracy: Double = 5, headingDelta: Double? = nil) -> State {
        guard accuracy <= 50, lateralOffset.isFinite else { return state }
        switch state {
        case .onRoute:
            if lateralOffset > fastThreshold, let delta = headingDelta, abs(delta) >= fastHeading {
                fastCount += 1
            } else {
                fastCount = 0
            }
            if lateralOffset > threshold {
                outCount += 1
                if outSince == nil { outSince = time }
            } else {
                outCount = 0
                outSince = nil
            }
            if fastCount >= fastSamples || outCount >= minSamples || (outSince.map { time - $0 >= minDuration } ?? false) {
                state = .offRoute
                inCount = 0
                fastCount = 0
            }
        case .offRoute:
            if lateralOffset < recoverThreshold {
                inCount += 1
                if inCount >= recoverSamples {
                    state = .onRoute
                    outCount = 0
                    outSince = nil
                }
            } else {
                inCount = 0
            }
        }
        return state
    }
}

/// Local fallback guidance when off route and the companion is unreachable:
/// target = closest route point that is ahead of the last known progress.
public enum RejoinGuide {
    /// Rejoin point « au plus logique »: among points of the next 15 km of the track (never behind the last
    /// progress), the one minimising crow distance + 30 % of the track skipped; points behind the rider's heading
    /// cost 50 % more (avoids a U-turn when a point ahead is almost as close).
    public static func logicalTarget(from position: GeoPoint, heading: Double?, route: Polyline, lastProgress: Double,
                                     lookAhead: Double = 15_000, step: Double = 200) -> (point: GeoPoint, along: Double)? {
        guard route.length > 0 else { return nil }
        let start = min(max(0, lastProgress), route.length)
        let end = min(route.length, start + lookAhead)
        var best: (point: GeoPoint, along: Double, cost: Double)?
        var along = start
        while along <= end {
            if let p = route.point(at: along) {
                var crow = Geo.distance(position, p)
                if let heading, heading >= 0, crow > 50 {
                    var delta = Geo.bearing(position, p) - heading
                    delta = (delta + 540).truncatingRemainder(dividingBy: 360) - 180
                    if abs(delta) > 100 { crow *= 1.5 }
                }
                let cost = crow + 0.3 * (along - start)
                if best == nil || cost < best!.cost { best = (p, along, cost) }
            }
            along += step
        }
        return best.map { (point: $0.point, along: $0.along) }
    }

    /// A place on the route worth asking a router for the way back.
    public struct Candidate: Equatable, Sendable {
        public let point: GeoPoint
        public let along: Double
        public init(point: GeoPoint, along: Double) {
            self.point = point
            self.along = along
        }
    }

    /// Up to three places to rejoin, asked to the router at once: where the rider left the route (back the way they
    /// came, often the shortest after a missed turn), the most logical point within the next 3 km, and the most
    /// logical one 3 to 15 km ahead. Places closer than 500 m along the route to another are dropped.
    public static func candidates(from position: GeoPoint, heading: Double?, route: Polyline, lastProgress: Double) -> [Candidate] {
        guard route.length > 0 else { return [] }
        let left = min(max(0, lastProgress) + 50, route.length)
        var out: [Candidate] = []
        func add(_ along: Double, _ point: GeoPoint?) {
            guard let point, !out.contains(where: { abs($0.along - along) < 500 }) else { return }
            out.append(Candidate(point: point, along: along))
        }
        add(left, route.point(at: left))
        if let near = logicalTarget(from: position, heading: heading, route: route, lastProgress: left + 600, lookAhead: 2_400) {
            add(near.along, near.point)
        }
        if let far = logicalTarget(from: position, heading: heading, route: route, lastProgress: left + 3_000, lookAhead: 12_000) {
            add(far.along, far.point)
        }
        return out
    }

    /// The way back with the least time to reach the farthest candidate: time to the rejoin point plus the time to
    /// ride the route from there (at `routeSpeed`). Returns the index in `options`; nil when none.
    public static func best(_ options: [(along: Double, seconds: TimeInterval)], routeSpeed: Double = 50 / 3.6) -> Int? {
        guard let far = options.map(\.along).max(), routeSpeed > 0 else { return nil }
        return options.indices.min { a, b in
            options[a].seconds + (far - options[a].along) / routeSpeed < options[b].seconds + (far - options[b].along) / routeSpeed
        }
    }

    public static func target(from position: GeoPoint, route: Polyline, lastProgress: Double) -> PolylineMatch? {
        let ahead = route.slice(from: lastProgress, to: route.length)
        guard let m = ahead.locate(position) else { return nil }
        return PolylineMatch(segmentIndex: m.segmentIndex,
                             distanceAlong: lastProgress + m.distanceAlong,
                             lateralOffset: m.lateralOffset,
                             projected: m.projected)
    }
}
