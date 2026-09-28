import Foundation

/// Builds routing segments from raw geometry when no GraphHopper speeds are available (GPX import).
/// Default speeds are placeholders until the routing engine provides real ones; the PaceEstimator
/// then corrects them with the rider's actual pace.
public enum SegmentBuilder {
    public static let chunk = 1_000.0
    public static let defaultSpeeds: [RoadClass: Double] = [
        .curvy: 45 / 3.6,
        .secondary: 65 / 3.6,
        .link: 80 / 3.6
    ]

    public static func classify(curvatureScore s: Double) -> RoadClass {
        if s >= 45 { return .curvy }
        if s >= 15 { return .secondary }
        return .link
    }

    public static func segments(for line: Polyline) -> [RouteSegment] {
        guard line.length > 0 else { return [] }
        var out: [RouteSegment] = []
        var d = 0.0
        while d < line.length {
            let e = min(d + chunk, line.length)
            let piece = line.slice(from: d, to: e)
            let c = classify(curvatureScore: Curvature.score(piece))
            out.append(RouteSegment(distance: e - d, routingSpeed: defaultSpeeds[c]!, roadClass: c))
            d = e
        }
        return out
    }

    /// Segments whose total time matches the routing engine's planned time for the day (GraphHopper), keeping
    /// the relative speeds of curvy / secondary / link roads. Without a plan: the default speeds.
    public static func segments(for line: Polyline, plannedDuration: TimeInterval?) -> [RouteSegment] {
        let base = segments(for: line)
        guard let planned = plannedDuration, planned >= 60 else { return base }
        let defaultTime = base.reduce(0) { $0 + $1.distance / $1.routingSpeed }
        guard defaultTime > 0 else { return base }
        let factor = min(max(defaultTime / planned, 0.4), 2.5)      // guards against a corrupt plan
        return base.map { var s = $0; s.routingSpeed *= factor; return s }
    }

    /// Segments remaining after `distanceAlong`.
    public static func remaining(_ segments: [RouteSegment], after distanceAlong: Double) -> [RouteSegment] {
        var acc = 0.0
        var out: [RouteSegment] = []
        for s in segments {
            let end = acc + s.distance
            if end > distanceAlong {
                var piece = s
                piece.distance = end - max(acc, distanceAlong)
                out.append(piece)
            }
            acc = end
        }
        return out
    }
}

/// What the navigation screen shows for one target (fuel, next stop, end of day).
public struct TargetInfo: Equatable, Sendable {
    public let label: String
    public let distance: Double          // metres from current position
    public let eta: Date
}

public struct NavigationSnapshot: Equatable, Sendable {
    public let progress: Double          // metres along today's route
    public let lateralOffset: Double
    public let nextFuel: TargetInfo?
    public let nextStop: TargetInfo?
    public let endOfDay: TargetInfo
    /// Positive = late versus plan, seconds. nil when the day has no planned duration.
    public let delay: TimeInterval?
    public let arrivesAfterSunset: Bool
}

/// Pure computation of the navigation banner values. Called on every GPS fix by the app.
public struct NavigationComputer: Sendable {
    public let route: Polyline
    public let segments: [RouteSegment]
    /// Fuel stops as distances along the route.
    public let fuelStops: [(name: String, along: Double)]
    /// Planned meal/lodging stops along the route, with planned stop duration.
    public let stops: [(name: String, along: Double, duration: TimeInterval)]
    public let plannedDuration: TimeInterval?
    public let dayStart: Date?

    public init(route: Polyline, segments: [RouteSegment]? = nil,
                fuelStops: [(name: String, along: Double)] = [],
                stops: [(name: String, along: Double, duration: TimeInterval)] = [],
                plannedDuration: TimeInterval? = nil, dayStart: Date? = nil) {
        self.route = route
        self.segments = segments ?? SegmentBuilder.segments(for: route, plannedDuration: plannedDuration)
        self.fuelStops = fuelStops.sorted { $0.along < $1.along }
        self.stops = stops.sorted { $0.along < $1.along }
        self.plannedDuration = plannedDuration
        self.dayStart = dayStart
    }

    public func snapshot(position: GeoPoint, lastProgress: Double?, now: Date,
                         pace: PaceEstimator, sunset: Date? = nil) -> NavigationSnapshot? {
        guard let m = route.locate(position, hint: lastProgress) ?? route.locate(position) else { return nil }
        let here = m.distanceAlong
        let ahead = SegmentBuilder.remaining(segments, after: here)
        let plannedAhead = stops.filter { $0.along > here }
            .map { PlannedStop(distanceAlong: $0.along - here, duration: $0.duration) }
        let fuelAhead = fuelStops.filter { $0.along > here }
            .map { PlannedStop(distanceAlong: $0.along - here, duration: PlannedStop.defaultFuelDuration) }
        let allStops = plannedAhead + fuelAhead

        func info(_ label: String, _ along: Double) -> TargetInfo {
            let d = along - here
            let t = pace.remainingTime(to: d, segments: ahead, stops: allStops)
            return TargetInfo(label: label, distance: d, eta: now.addingTimeInterval(t))
        }

        let nextFuel = fuelStops.first { $0.along > here }.map { info($0.name, $0.along) }
        let nextStop = stops.first { $0.along > here }.map { info($0.name, $0.along) }
        let end = info("Fin d'étape", route.length)

        var delay: TimeInterval?
        if let planned = plannedDuration, let start = dayStart {
            let plannedArrival = start.addingTimeInterval(planned)
            delay = end.eta.timeIntervalSince(plannedArrival)
        }
        let afterSunset = sunset.map { end.eta > $0 } ?? false

        return NavigationSnapshot(progress: here, lateralOffset: m.lateralOffset, nextFuel: nextFuel,
                                  nextStop: nextStop, endOfDay: end, delay: delay, arrivesAfterSunset: afterSunset)
    }
}
