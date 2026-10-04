import Foundation

/// Roads with a dated seasonal closure and named mountain passes, from OpenStreetMap. Published every day by GitHub
/// (workflow data-pack.yml, built by the companion's `app.data_pack`) so the iPhone chooses a trip's dates without
/// the PC. Compact wire format: closures `[road, [[m1, d1, m2, d2]…], [lat, lon, lat, lon…]]`,
/// passes `[lat, lon, ele or null, name]`.
public struct SeasonPack: Codable, Equatable, Sendable {
    public var version: String
    public var closures: [SeasonalClosure]
    public var passes: [MountainPass]

    public init(version: String, closures: [SeasonalClosure] = [], passes: [MountainPass] = []) {
        self.version = version
        self.closures = closures
        self.passes = passes
    }
}

/// A yearly closing period, from `start` to `end` inclusive (may wrap over the new year: Nov 1 – May 31).
public struct ClosurePeriod: Hashable, Sendable {
    public let startMonth: Int, startDay: Int, endMonth: Int, endDay: Int

    public init(_ startMonth: Int, _ startDay: Int, _ endMonth: Int, _ endDay: Int) {
        self.startMonth = startMonth
        self.startDay = startDay
        self.endMonth = endMonth
        self.endDay = endDay
    }

    public func isClosed(on day: CalendarDay) -> Bool {
        let start = startMonth * 100 + startDay, end = endMonth * 100 + endDay, x = day.month * 100 + day.day
        return start <= end ? (start...end).contains(x) : (x >= start || x <= end)
    }

    /// Days between `day` and the nearest closing or reopening date (any year).
    public func daysFromBoundary(_ day: CalendarDay) -> Int {
        var best = 366
        for (m, d) in [(startMonth, startDay), (endMonth, endDay)] {
            for year in day.year - 1...day.year + 1 {
                if let b = CalendarDay(year: year, month: m, day: d) { best = min(best, abs(day.days(to: b))) }
            }
        }
        return best
    }
}

/// An OSM way closed every year at given dates (`motor_vehicle:conditional=no @ (Nov 1-May 31)`…).
public struct SeasonalClosure: Codable, Equatable, Sendable {
    /// Road number or name, « route » when OSM has neither.
    public let road: String
    public let periods: [ClosurePeriod]
    public let points: [GeoPoint]

    public init(road: String, periods: [ClosurePeriod], points: [GeoPoint]) {
        self.road = road
        self.periods = periods
        self.points = points
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        road = try c.decode(String.self)
        periods = try c.decode([[Int]].self).compactMap { p in p.count == 4 ? ClosurePeriod(p[0], p[1], p[2], p[3]) : nil }
        let flat = try c.decode([Double].self)
        points = stride(from: 0, to: flat.count - 1, by: 2).map { GeoPoint(lat: flat[$0], lon: flat[$0 + 1]) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(road)
        try c.encode(periods.map { [$0.startMonth, $0.startDay, $0.endMonth, $0.endDay] })
        try c.encode(points.flatMap { [$0.lat, $0.lon] })
    }
}

/// A named mountain pass (OSM `mountain_pass=yes`).
public struct MountainPass: Codable, Equatable, Sendable {
    public let point: GeoPoint
    public let ele: Int?
    public let name: String

    public init(point: GeoPoint, ele: Int?, name: String) {
        self.point = point
        self.ele = ele
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        point = GeoPoint(lat: try c.decode(Double.self), lon: try c.decode(Double.self))
        ele = try c.decodeNil() ? nil : try c.decode(Int.self)
        name = try c.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(point.lat)
        try c.encode(point.lon)
        if let ele { try c.encode(ele) } else { try c.encodeNil() }
        try c.encode(name)
    }
}

/// What the season says about a stage's roads, in the road book's words (lines of `mustCheck`, same text as the PC's).
public enum SeasonalChecks {
    public static let closureMark = "📅 "
    public static let weatherMark = "🌦 "
    /// A closed way is on the route when two of its points are this close to the track.
    public static let onRoute = 30.0
    /// A pass names a closed road within this distance.
    public static let passNear = 1_500.0
    /// Just after the reopening or before the closing: still worth checking.
    public static let nearBoundaryDays = 14

    static let monthsFR = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]

    /// « 1er juin », « 15 oct. ».
    public static func frDate(_ month: Int, _ day: Int) -> String {
        "\(day == 1 ? "1er" : String(day)) \(monthsFR[month - 1])"
    }

    /// The closures whose road the track follows (two points within 30 m of it).
    public static func closures(on track: Polyline, among closures: [SeasonalClosure]) -> [SeasonalClosure] {
        guard let box = BoundingBox(track.points, margin: onRoute) else { return [] }
        return closures.filter { c in
            var near = 0
            for p in c.points where box.contains(p) {
                if let m = track.locate(p), m.lateralOffset <= onRoute {
                    near += 1
                    if near >= 2 { return true }
                }
            }
            return false
        }
    }

    /// The passes the track goes over (within `maxOffset` metres).
    public static func passes(on track: Polyline, among passes: [MountainPass], maxOffset: Double = 300) -> [MountainPass] {
        guard let box = BoundingBox(track.points, margin: maxOffset) else { return [] }
        return passes.filter { box.contains($0.point) && (track.locate($0.point)?.lateralOffset ?? .infinity) <= maxOffset }
    }

    /// The stage's closed roads on `day`, or just reopened / about to close: one line per road and period, named
    /// after the highest pass met along the closed stretches. `closures`: those on the stage's route.
    public static func closureWarnings(on day: CalendarDay, closures: [SeasonalClosure], passes: [MountainPass]) -> [String] {
        struct Key: Hashable { let road: String; let period: ClosurePeriod }
        var order: [Key] = []
        var found: [Key: (closed: Bool, pass: MountainPass?)] = [:]
        for c in closures {
            guard !c.points.isEmpty else { continue }
            let mid = c.points[c.points.count / 2]
            let nearest = passes.min { Geo.distance(mid, $0.point) < Geo.distance(mid, $1.point) }
            let pass = nearest.flatMap { Geo.distance(mid, $0.point) <= passNear ? $0 : nil }
            for period in c.periods {
                let closed = period.isClosed(on: day)
                if !closed && period.daysFromBoundary(day) > nearBoundaryDays { continue }
                let key = Key(road: c.road, period: period)
                if found[key] == nil {
                    order.append(key)
                    found[key] = (closed: false, pass: nil)
                }
                var entry = found[key]!
                entry.closed = entry.closed || closed
                if let pass, entry.pass == nil || (pass.ele ?? 0) > (entry.pass?.ele ?? 0) { entry.pass = pass }
                found[key] = entry
            }
        }
        return order.map { key in
            let entry = found[key]!
            let p = key.period
            let label: String
            if let pass = entry.pass { label = key.road == "route" ? pass.name : "\(pass.name) (\(key.road))" }
            else { label = key.road == "route" ? "Une route de l'étape" : key.road }
            let span = "fermé du \(frDate(p.startMonth, p.startDay)) au \(frDate(p.endMonth, p.endDay))"
            let when = frDate(day.month, day.day)
            return entry.closed
                ? "\(closureMark)\(label) : \(span) (OpenStreetMap). Ton passage le \(when) tombe dedans : vérifie l'ouverture auprès du département ou prévois le plan B."
                : "\(closureMark)\(label) : \(span) (OpenStreetMap). Ton passage le \(when) est proche de ces dates : vérifie l'ouverture effective."
        }
    }

    /// A line only when the season deserves attention: rain often, cold mornings or heat.
    public static func weatherLine(stage: Int, day: CalendarDay, place: String, stats: Climate.Stats, years: Int) -> String? {
        var notes: [String] = []
        if stats.rain >= 0.3 { notes.append("pluie \(Int((stats.rain * 10).rounded())) jours sur 10") }
        if stats.low <= 5 { notes.append("\(Int(stats.low.rounded())) °C au petit matin") }
        if stats.high >= 32 { notes.append("\(Int(stats.high.rounded())) °C l'après-midi") }
        guard !notes.isEmpty else { return nil }
        return "\(weatherMark)Météo de saison, jour \(stage) (\(frDate(day.month, day.day)), \(place)) : "
            + "\(notes.joined(separator: ", ")) (Open-Meteo, \(years) dernières années)."
    }
}

/// Latitude/longitude box around points, widened by a margin in metres: a cheap test before projecting on a track.
struct BoundingBox {
    let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double

    init?(_ points: [GeoPoint], margin: Double) {
        guard let first = points.first else { return nil }
        var box = (minLat: first.lat, maxLat: first.lat, minLon: first.lon, maxLon: first.lon)
        for p in points {
            box.minLat = min(box.minLat, p.lat); box.maxLat = max(box.maxLat, p.lat)
            box.minLon = min(box.minLon, p.lon); box.maxLon = max(box.maxLon, p.lon)
        }
        let dLat = margin / 111_195
        let dLon = margin / (111_195 * max(0.1, cos(max(abs(box.minLat), abs(box.maxLat)) * .pi / 180)))
        minLat = box.minLat - dLat; maxLat = box.maxLat + dLat
        minLon = box.minLon - dLon; maxLon = box.maxLon + dLon
    }

    func contains(_ p: GeoPoint) -> Bool { p.lat >= minLat && p.lat <= maxLat && p.lon >= minLon && p.lon <= maxLon }
}
