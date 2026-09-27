import Foundation

/// Mountain pass metadata. Opening months MUST come from a cited source (never guessed).
public struct ColInfo: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var point: GeoPoint
    public var zone: String
    /// Months (1–12) during which the pass is usually open, per `source`.
    public var usuallyOpenMonths: [Int]
    public var source: String
    public var lastVerified: String

    public init(id: String, name: String, point: GeoPoint, zone: String, usuallyOpenMonths: [Int],
                source: String, lastVerified: String) {
        self.id = id
        self.name = name
        self.point = point
        self.zone = zone
        self.usuallyOpenMonths = usuallyOpenMonths
        self.source = source
        self.lastVerified = lastVerified
    }
}

/// A question the app must ask the rider instead of guessing (SPEC §4.2, project rules).
public struct ConsistencyQuestion: Equatable, Sendable {
    public let code: String
    public let message: String
}

/// Pre-flight checks run on the form BEFORE calling the planner.
public enum ConsistencyChecker {
    /// Straight-line → road distance factor for twisty routes (heuristic, conservative).
    public static let detourFactor = 1.4

    public static func check(_ p: TripParams, cols: [ColInfo] = []) -> [ConsistencyQuestion] {
        var q: [ConsistencyQuestion] = []

        guard let start = ISODate.parse(p.dateStart), let end = ISODate.parse(p.dateEnd) else {
            return [.init(code: "dates.invalid", message: "Les dates du trip sont invalides.")]
        }
        if end < start {
            q.append(.init(code: "dates.order", message: "La date de retour est avant la date de départ."))
        }
        let days = max(1, ISODate.days(from: start, to: end) + 1)

        if p.zone.isEmpty {
            q.append(.init(code: "zone.empty", message: "Quelle zone veux-tu rouler ? (région, massif ou pays)"))
        }
        if p.bikes.isEmpty {
            q.append(.init(code: "bikes.empty", message: "Quelle(s) moto(s) pour ce trip ? L'autonomie est nécessaire pour placer les pleins."))
        } else if let range = p.groupUsableRangeMeters, range < p.maxFuelIntervalKm * 1000 {
            let km = Int(range / 1000)
            q.append(.init(code: "fuel.range",
                           message: "Autonomie utile du groupe ≈ \(km) km : les pleins seront placés tous les \(km) km au lieu de \(Int(p.maxFuelIntervalKm))."))
        }
        if p.maxKmPerDay < 50 {
            q.append(.init(code: "kmday.low", message: "Kilométrage par jour très faible : confirmes-tu \(Int(p.maxKmPerDay)) km/jour ?"))
        }

        // Distance feasibility (one-way trips only; loops depend on the chosen area).
        if let a = p.start.point, let bPlace = p.end, let b = bPlace.point {
            let minKm = Geo.distance(a, b) / 1000 * detourFactor
            let capacity = p.maxKmPerDay * Double(days)
            if minKm > capacity {
                q.append(.init(code: "distance.capacity",
                               message: "≈ \(Int(minKm)) km minimum par routes sinueuses pour \(Int(capacity)) km possibles (\(days) j × \(Int(p.maxKmPerDay)) km). Allonger la durée ou le km/jour ?"))
            }
        }

        // Passes in the chosen zone that are usually closed during the trip.
        let months = Set(monthsCovered(from: start, to: end))
        for col in cols where p.zone.contains(col.zone) {
            let closed = months.subtracting(col.usuallyOpenMonths)
            if !closed.isEmpty {
                q.append(.init(code: "col.closed.\(col.id)",
                               message: "\(col.name) est habituellement fermé à cette période (source : \(col.source), vérifié le \(col.lastVerified)). L'exclure ou changer de dates ?"))
            }
        }
        return q
    }

    static func monthsCovered(from start: Date, to end: Date) -> [Int] {
        guard end >= start else { return [ISODate.month(start)] }
        var result: [Int] = []
        var d = start
        while d <= end {
            let m = ISODate.month(d)
            if result.last != m { result.append(m) }
            d = d.addingTimeInterval(86_400)
        }
        return result
    }
}
