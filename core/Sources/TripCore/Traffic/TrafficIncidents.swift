import Foundation

/// Live traffic incident (TomTom Traffic Incident Details v5). Optional while riding: fetched only when
/// the network is available, never required to navigate (CLAUDE.md rule 1).
public struct TrafficIncident: Equatable, Sendable {
    public enum Category: Int, Sendable {
        case unknown = 0, accident = 1, fog = 2, dangerousConditions = 3, rain = 4, ice = 5, jam = 6
        case laneClosed = 7, roadClosed = 8, roadWorks = 9, wind = 10, flooding = 11, brokenDownVehicle = 14

        /// Spoken French label.
        public var label: String {
            switch self {
            case .unknown: "Incident"
            case .accident: "Accident"
            case .fog: "Brouillard"
            case .dangerousConditions: "Conditions dangereuses"
            case .rain: "Forte pluie"
            case .ice: "Verglas"
            case .jam: "Bouchon"
            case .laneClosed: "Voie fermée"
            case .roadClosed: "Route fermée"
            case .roadWorks: "Travaux"
            case .wind: "Vent violent"
            case .flooding: "Inondation"
            case .brokenDownVehicle: "Véhicule en panne"
            }
        }
    }

    public let id: String
    public let category: Category
    public let description: String?
    /// Extra travel time caused by the incident, seconds (nil for closures).
    public let delay: TimeInterval?
    public let geometry: [GeoPoint]

    public init(id: String, category: Category, description: String? = nil, delay: TimeInterval? = nil, geometry: [GeoPoint]) {
        self.id = id
        self.category = category
        self.description = description
        self.delay = delay
        self.geometry = geometry
    }
}

/// An incident located on the route ahead.
public struct IncidentAhead: Equatable, Sendable {
    public let incident: TrafficIncident
    /// Distance from the start of the day's track to the first point of the incident on it, metres.
    public let along: Double
}

public enum TrafficIncidents {
    /// Incidents farther than this from the track are on another road.
    public static let maxOffset = 50.0
    /// Look-ahead distance (SPEC §5.4).
    public static let horizon = 50_000.0
    /// TomTom rejects bounding boxes above 10 000 km².
    public static let maxBoxArea = 10_000.0

    // MARK: Request

    /// Bounding box (minLon, minLat, maxLon, maxLat) of the track ahead, shortened until it fits the API limit.
    public static func boundingBox(route: Polyline, progress: Double, horizon: Double = horizon)
        -> (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)? {
        var ahead = horizon
        while ahead >= 1_000 {
            let piece = route.slice(from: progress, to: min(route.length, progress + ahead))
            guard piece.points.count >= 2 else { return nil }
            let lats = piece.points.map(\.lat), lons = piece.points.map(\.lon)
            let margin = 0.002      // ≈ 200 m, so incidents touching the road are included
            let box = (minLon: lons.min()! - margin, minLat: lats.min()! - margin,
                       maxLon: lons.max()! + margin, maxLat: lats.max()! + margin)
            let heightKm = (box.maxLat - box.minLat) * 111.2
            let widthKm = (box.maxLon - box.minLon) * 111.2 * cos((box.minLat + box.maxLat) / 2 * .pi / 180)
            if heightKm * widthKm <= maxBoxArea { return box }
            ahead /= 2
        }
        return nil
    }

    /// Boxes covering the route from `progress` over `length` metres (whole route by default), one per `piece`,
    /// so traffic can be checked all along the trip, not only on the next kilometres.
    public static func boxes(route: Polyline, from progress: Double = 0, length: Double? = nil, piece: Double = 50_000)
        -> [(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)] {
        let end = min(route.length, progress + (length ?? route.length))
        var out: [(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)] = []
        var start = max(0, progress)
        while start < end - 1 {
            if let b = boundingBox(route: route, progress: start, horizon: min(piece, end - start)) { out.append(b) }
            start += piece
        }
        return out
    }

    // MARK: Response

    /// Parses an Incident Details v5 response (GeoJSON features; Point or LineString geometry).
    public static func parse(_ data: Data) throws -> [TrafficIncident] {
        struct Response: Decodable { let incidents: [Feature?] }
        struct Feature: Decodable { let geometry: Geometry?; let properties: Properties? }
        struct Properties: Decodable {
            let id: String?
            let iconCategory: Int?
            let delay: Double?
            let events: [Event]?
        }
        struct Event: Decodable { let description: String? }
        struct Geometry: Decodable {
            let type: String
            let coordinates: Coordinates
        }
        enum Coordinates: Decodable {
            case point([Double]), line([[Double]])
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let line = try? c.decode([[Double]].self) { self = .line(line) } else { self = .point(try c.decode([Double].self)) }
            }
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.incidents.enumerated().compactMap { i, feature in
            guard let feature, let geometry = feature.geometry else { return nil }
            let pairs: [[Double]]
            switch geometry.coordinates {
            case .point(let p): pairs = [p]
            case .line(let l): pairs = l
            }
            let points = pairs.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[1], lon: $0[0]) : nil }
            guard !points.isEmpty else { return nil }
            let p = feature.properties
            return TrafficIncident(id: p?.id ?? "incident-\(i)",
                                   category: TrafficIncident.Category(rawValue: p?.iconCategory ?? 0) ?? .unknown,
                                   description: p?.events?.compactMap(\.description).first,
                                   delay: p?.delay.flatMap { $0 > 0 ? $0 : nil },
                                   geometry: points)
        }
    }

    // MARK: Filtering and announcements

    /// Incidents touching the track between `progress` and `progress + horizon`, nearest first.
    public static func ahead(_ incidents: [TrafficIncident], route: Polyline, progress: Double,
                             horizon: Double = horizon) -> [IncidentAhead] {
        incidents.compactMap { incident -> IncidentAhead? in
            let hits = incident.geometry.compactMap { p -> Double? in
                guard let m = route.locate(p, hint: progress, window: horizon + 1_000), m.lateralOffset <= maxOffset else { return nil }
                return m.distanceAlong
            }
            guard let first = hits.filter({ $0 > progress && $0 <= progress + horizon }).min() else { return nil }
            return IncidentAhead(incident: incident, along: first)
        }
        .sorted { $0.along < $1.along }
    }

    /// Announced when first seen ahead, then again 1 km before. Keys are unique per incident and phase.
    public static func announcements(_ ahead: [IncidentAhead], progress: Double) -> [TurnGuide.Announcement] {
        ahead.map { item in
            let d = item.along - progress
            let phase = d <= 1_000 ? "near" : "far"
            let delay = item.incident.delay.map { $0 >= 120 ? ", \(Int(($0 / 60).rounded())) minutes de retard" : "" } ?? ""
            return TurnGuide.Announcement(key: "traffic-\(item.incident.id)-\(phase)",
                                          text: "\(item.incident.category.label) \(TurnGuide.lowercasingFirst(TurnGuide.spokenDistance(d)))\(delay)")
        }
    }
}
