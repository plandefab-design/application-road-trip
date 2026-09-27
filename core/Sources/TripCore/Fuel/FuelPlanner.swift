import Foundation

public struct FuelStation: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var point: GeoPoint
    public init(id: String, name: String, point: GeoPoint) {
        self.id = id
        self.name = name
        self.point = point
    }
}

public struct PlannedFuelStop: Equatable, Sendable {
    public let station: FuelStation
    /// Distance along the route where the rider leaves the route, metres.
    public let distanceAlong: Double
    /// Straight-line distance from the route to the station, metres.
    public let detour: Double
}

/// A stretch where no station is reachable within the usable range.
public struct FuelGap: Equatable, Sendable {
    public let from: Double   // metres along route
    public let to: Double
}

public struct FuelPlan: Equatable, Sendable {
    public let stops: [PlannedFuelStop]
    public let gaps: [FuelGap]
    public var isFeasible: Bool { gaps.isEmpty }
}

/// Places fuel stops along a route (SPEC §5.2).
///
/// Assumptions: the tank is full at the start of the route.
/// Invariant (when feasible): every interval start→stop, stop→stop, stop→end ≤ `interval`.
public enum FuelPlanner {
    /// Aim to refuel this far before the theoretical limit.
    public static let anticipation = 20_000.0
    /// Maximum lateral distance from the route to consider a station.
    public static let maxDetour = 3_000.0

    public static func plan(route: Polyline, stations: [FuelStation], interval: Double) -> FuelPlan {
        guard interval > 0, route.length > 0 else { return FuelPlan(stops: [], gaps: []) }

        // Project stations once, keep those close to the route, sort along the route.
        let candidates: [(FuelStation, PolylineMatch)] = stations.compactMap { (st: FuelStation) -> (FuelStation, PolylineMatch)? in
            guard let m = route.locate(st.point), m.lateralOffset <= maxDetour else { return nil }
            return (st, m)
        }.sorted { $0.1.distanceAlong < $1.1.distanceAlong }

        var stops: [PlannedFuelStop] = []
        var gaps: [FuelGap] = []
        var last = 0.0
        let target = max(interval - anticipation, interval * 0.5)

        while route.length - last > interval {
            let reachable = candidates.filter { $0.1.distanceAlong > last + 1 && $0.1.distanceAlong <= last + interval }
            // Prefer the furthest station before the target; otherwise the furthest reachable.
            let beforeTarget = reachable.filter { $0.1.distanceAlong <= last + target }
            if let pick = (beforeTarget.last ?? reachable.last) {
                stops.append(PlannedFuelStop(station: pick.0, distanceAlong: pick.1.distanceAlong, detour: pick.1.lateralOffset))
                last = pick.1.distanceAlong
            } else {
                // No station in range: record the gap and resume at the next station beyond it (if any).
                let next = candidates.first { $0.1.distanceAlong > last + interval }
                let resume = next?.1.distanceAlong ?? route.length
                gaps.append(FuelGap(from: last, to: resume))
                if let next {
                    stops.append(PlannedFuelStop(station: next.0, distanceAlong: next.1.distanceAlong, detour: next.1.lateralOffset))
                    last = next.1.distanceAlong
                } else {
                    break
                }
            }
        }
        return FuelPlan(stops: stops, gaps: gaps)
    }

    /// Next planned fuel stop ahead of `position` (metres along the route).
    public static func next(after position: Double, in plan: FuelPlan) -> PlannedFuelStop? {
        plan.stops.first { $0.distanceAlong > position }
    }
}
