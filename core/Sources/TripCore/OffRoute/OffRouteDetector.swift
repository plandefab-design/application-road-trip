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
    public static func target(from position: GeoPoint, route: Polyline, lastProgress: Double) -> PolylineMatch? {
        let ahead = route.slice(from: lastProgress, to: route.length)
        guard let m = ahead.locate(position) else { return nil }
        return PolylineMatch(segmentIndex: m.segmentIndex,
                             distanceAlong: lastProgress + m.distanceAlong,
                             lateralOffset: m.lateralOffset,
                             projected: m.projected)
    }
}
