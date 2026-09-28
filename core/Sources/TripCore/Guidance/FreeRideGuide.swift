import Foundation

/// Every speed camera and hazard of the map, compact, stored on the iPhone for riding without an itinerary.
/// Wire format of the companion's GET /alerts-pack.
public struct AlertPack: Codable, Equatable, Sendable {
    public var version: String
    /// [lat, lon, maxspeed or null, 1 = red-light camera]
    public var cameras: [[AlertPackValue]]
    /// [lat, lon, label]
    public var hazards: [[AlertPackValue]]

    public init(version: String, cameras: [[AlertPackValue]] = [], hazards: [[AlertPackValue]] = []) {
        self.version = version
        self.cameras = cameras
        self.hazards = hazards
    }

    /// Decoded alerts (malformed rows skipped).
    public var alerts: [PositionedAlert] {
        var out: [PositionedAlert] = []
        out.reserveCapacity(cameras.count + hazards.count)
        for row in cameras {
            guard row.count >= 2, let lat = row[0].number, let lon = row[1].number else { continue }
            let code = row.count > 3 ? Int(row[3].number ?? 0) : 0
            let kind: RoadAlertKind = code == 1 ? .redLightCamera : code == 2 ? .sectionCamera : .speedCamera
            let fallback = kind == .redLightCamera ? "radar feu rouge" : kind == .sectionCamera ? "radar tronçon" : "radar"
            out.append(PositionedAlert(point: GeoPoint(lat: lat, lon: lon),
                                       alert: RoadAlert(along: 0, kind: kind,
                                                        label: (row.count > 4 ? row[4].text : nil) ?? fallback,
                                                        maxspeed: row.count > 2 ? row[2].number.map { Int($0) } : nil)))
        }
        for row in hazards {
            guard row.count >= 3, let lat = row[0].number, let lon = row[1].number else { continue }
            out.append(PositionedAlert(point: GeoPoint(lat: lat, lon: lon),
                                       alert: RoadAlert(along: 0, kind: .hazard, label: row[2].text ?? "danger")))
        }
        return out
    }
}

/// A JSON scalar of the pack (number, text or null).
public enum AlertPackValue: Codable, Equatable, Sendable {
    case number(Double), text(String), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else { self = .text(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .text(let s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }

    public var number: Double? { if case .number(let d) = self { return d }; return nil }
    public var text: String? { if case .text(let s) = self { return s }; return nil }
}

public struct PositionedAlert: Equatable, Sendable {
    public let point: GeoPoint
    public let alert: RoadAlert
}

/// Alerts around the rider without an itinerary: those AHEAD in the direction of travel, in a narrow corridor
/// (so a parallel road or a camera behind is ignored). Grid index: queries stay fast with Europe's ~100 000 alerts.
public struct FreeRideGuide: Sendable {
    public static let cell = 0.02                 // degrees (≈ 2 km)
    public static let corridor = 60.0             // metres either side of the heading line
    public static let nearCamera = 150.0          // second camera warning

    private let grid: [Int64: [Int]]
    public let alerts: [PositionedAlert]

    public init(alerts: [PositionedAlert]) {
        self.alerts = alerts
        var grid: [Int64: [Int]] = [:]
        for (i, a) in alerts.enumerated() { grid[Self.key(a.point.lat, a.point.lon), default: []].append(i) }
        self.grid = grid
    }

    private static func key(_ lat: Double, _ lon: Double) -> Int64 {
        Int64((lat / cell).rounded(.down)) * 100_000 + Int64((lon / cell).rounded(.down))
    }

    /// Alerts ahead within `range`, nearest first, with their distance along the heading.
    /// `heading` in degrees (GPS course); nil when unknown (stopped) → nothing is ahead.
    public func ahead(of position: GeoPoint, heading: Double?, range: Double = AlertGuide.cameraLead + 100)
        -> [(index: Int, alert: RoadAlert, distance: Double)] {
        guard let heading, heading >= 0 else { return [] }
        let cLat = Int64((position.lat / Self.cell).rounded(.down)), cLon = Int64((position.lon / Self.cell).rounded(.down))
        var out: [(Int, RoadAlert, Double)] = []
        for dLat in -1...1 {
            for dLon in -1...1 {
                for i in grid[(cLat + Int64(dLat)) * 100_000 + cLon + Int64(dLon)] ?? [] {
                    let a = alerts[i]
                    let d = Geo.distance(position, a.point)
                    guard d <= range else { continue }
                    var delta = Geo.bearing(position, a.point) - heading
                    delta = (delta + 540).truncatingRemainder(dividingBy: 360) - 180
                    let along = d * cos(delta * .pi / 180)
                    let lateral = abs(d * sin(delta * .pi / 180))
                    guard along > 0, lateral <= Self.corridor else { continue }
                    out.append((i, a.alert, along))
                }
            }
        }
        return out.sorted { $0.2 < $1.2 }.map { (index: $0.0, alert: $0.1, distance: $0.2) }
    }

    /// Alerts of the pack lying on a route (within `maxOffset` metres), positioned along it, in route order.
    /// Used for any computed route (address, « autour de moi », rejoin) and to refresh a trip's alerts.
    public func along(_ track: Polyline, maxOffset: Double = 40) -> [RoadAlert] {
        guard track.points.count > 1 else { return [] }
        var candidates = Set<Int>()
        var d = 0.0
        while d <= track.length {
            if let p = track.point(at: d) {
                let cLat = Int64((p.lat / Self.cell).rounded(.down)), cLon = Int64((p.lon / Self.cell).rounded(.down))
                for dLat in -1...1 { for dLon in -1...1 { candidates.formUnion(grid[(cLat + Int64(dLat)) * 100_000 + cLon + Int64(dLon)] ?? []) } }
            }
            d += 1_000
        }
        return candidates.compactMap { i -> RoadAlert? in
            let a = alerts[i]
            guard let m = track.locate(a.point), m.lateralOffset <= maxOffset else { return nil }
            var alert = a.alert
            alert.along = m.distanceAlong
            alert.point = a.point
            return alert
        }
        .sorted { $0.along < $1.along }
    }

    /// Alerts within `radius` metres whatever the direction (map display), nearest first.
    public func near(_ position: GeoPoint, radius: Double = 3_000) -> [PositionedAlert] {
        let span = Int64((radius / 111_000 / Self.cell).rounded(.up))
        let cLat = Int64((position.lat / Self.cell).rounded(.down)), cLon = Int64((position.lon / Self.cell).rounded(.down))
        var out: [(PositionedAlert, Double)] = []
        for dLat in -span...span {
            for dLon in -span...span {
                for i in grid[(cLat + dLat) * 100_000 + cLon + dLon] ?? [] {
                    let d = Geo.distance(position, alerts[i].point)
                    if d <= radius { out.append((alerts[i], d)) }
                }
            }
        }
        return out.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Spoken warnings due now: cameras at 500 m then 150 m, hazards at 300 m. Keys are unique per alert and phase.
    public func announcements(position: GeoPoint, heading: Double?, cameras: Bool) -> [TurnGuide.Announcement] {
        ahead(of: position, heading: heading).compactMap { item in
            if item.alert.kind.isCamera {
                guard cameras else { return nil }
                if item.distance <= Self.nearCamera {
                    let limit = item.alert.maxspeed.map { ", limité à \($0)" } ?? ""
                    return .init(key: "free-\(item.index)-near", text: "Radar maintenant\(limit)", urgent: true)
                }
                guard item.distance <= AlertGuide.cameraLead else { return nil }
            } else {
                guard item.distance <= AlertGuide.hazardLead else { return nil }
            }
            return .init(key: "free-\(item.index)", text: AlertGuide.text(for: item.alert, distance: item.distance), urgent: true)
        }
    }
}
