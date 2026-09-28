import Foundation

/// Off-route detection with hysteresis (SPEC §5.7).
///
/// Off route when lateral offset > `threshold` for ≥ `minDuration` seconds OR ≥ `minSamples` consecutive samples.
/// Back on route when offset < `recoverThreshold` for `recoverSamples` consecutive samples.
public struct OffRouteDetector: Sendable {
    public enum State: Equatable, Sendable { case onRoute, offRoute }

    public var threshold = 40.0
    public var recoverThreshold = 25.0
    public var minDuration: TimeInterval = 5
    public var minSamples = 3
    public var recoverSamples = 2

    public private(set) var state: State = .onRoute
    private var outSince: TimeInterval?
    private var outCount = 0
    private var inCount = 0

    public init() {}

    /// - Parameters:
    ///   - lateralOffset: metres between GPS fix and the route
    ///   - time: monotonic timestamp, seconds
    ///   - accuracy: GPS horizontal accuracy, metres (poor fixes are ignored)
    @discardableResult
    public mutating func update(lateralOffset: Double, time: TimeInterval, accuracy: Double = 5) -> State {
        guard accuracy <= 50, lateralOffset.isFinite else { return state }
        switch state {
        case .onRoute:
            if lateralOffset > threshold {
                outCount += 1
                if outSince == nil { outSince = time }
                if outCount >= minSamples || time - (outSince ?? time) >= minDuration {
                    state = .offRoute
                    inCount = 0
                }
            } else {
                outCount = 0
                outSince = nil
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

    public static func target(from position: GeoPoint, route: Polyline, lastProgress: Double) -> PolylineMatch? {
        let ahead = route.slice(from: lastProgress, to: route.length)
        guard let m = ahead.locate(position) else { return nil }
        return PolylineMatch(segmentIndex: m.segmentIndex,
                             distanceAlong: lastProgress + m.distanceAlong,
                             lateralOffset: m.lateralOffset,
                             projected: m.projected)
    }
}
