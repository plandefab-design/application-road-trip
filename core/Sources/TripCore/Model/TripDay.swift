import Foundation

/// Maneuver kinds, mapped from GraphHopper instruction signs by the companion (schema v2).
public enum Maneuver: String, Codable, CaseIterable, Sendable {
    case depart, straight, slightLeft, slightRight, turnLeft, turnRight, sharpLeft, sharpRight
    case keepLeft, keepRight, uTurn, roundabout, via, arrive

    /// Tolerant: an unknown maneuver from a newer companion reads as `straight` instead of failing the whole trip.
    public init(from decoder: Decoder) throws {
        self = Maneuver(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .straight
    }
}

/// Legal speed limit on a stretch of a day's track (schema v6), from OpenStreetMap via GraphHopper.
public struct SpeedLimitRange: Codable, Hashable, Sendable {
    public var from: Double
    public var to: Double
    public var kmh: Int
    public init(from: Double, to: Double, kmh: Int) { self.from = from; self.to = to; self.kmh = kmh }
}

public enum PauseKind: String, Codable, CaseIterable, Sendable {
    case cafe, viewpoint, water
    public init(from decoder: Decoder) throws {
        self = PauseKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .viewpoint
    }
    public var label: String {
        switch self {
        case .cafe: "Café"
        case .viewpoint: "Point de vue"
        case .water: "Point d'eau"
        }
    }
}

/// Suggested pause spot near a day's track (schema v6), from OpenStreetMap.
public struct PauseSpot: Codable, Hashable, Sendable {
    public var along: Double
    public var kind: PauseKind
    public var name: String
    public var point: GeoPoint?
    public init(along: Double, kind: PauseKind, name: String, point: GeoPoint? = nil) {
        self.along = along; self.kind = kind; self.name = name; self.point = point
    }
}

/// Kind of road alert (schema v3). Unknown kinds read as `hazard`.
public enum RoadAlertKind: String, Codable, CaseIterable, Sendable {
    case speedCamera, redLightCamera, sectionCamera, hazard

    public init(from decoder: Decoder) throws {
        self = RoadAlertKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .hazard
    }

    public var isCamera: Bool { self != .hazard }
}

/// Speed camera or mapped hazard on a day's track, from OpenStreetMap (schema v3).
public struct RoadAlert: Codable, Hashable, Sendable {
    /// Distance from the start of the day's track, metres.
    public var along: Double
    public var kind: RoadAlertKind
    /// French label, e.g. « radar », « chutes de pierres ».
    public var label: String
    public var maxspeed: Int?
    public var point: GeoPoint?

    public init(along: Double, kind: RoadAlertKind, label: String, maxspeed: Int? = nil, point: GeoPoint? = nil) {
        self.along = along
        self.kind = kind
        self.label = label
        self.maxspeed = maxspeed
        self.point = point
    }
}

/// One turn-by-turn instruction of a day, positioned along the day's track (schema v2).
public struct TurnInstruction: Codable, Hashable, Sendable {
    /// Distance from the start of the day's track to the maneuver, metres.
    public var along: Double
    public var maneuver: Maneuver
    /// French text from the routing engine, e.g. « Tournez à gauche sur D943 ».
    public var text: String
    public var street: String?
    /// Roundabout exit number.
    public var exit: Int?
    /// Road number when known, e.g. « D 543 » (schema v7).
    public var ref: String?
    /// Signposted direction, e.g. « Cadenet » (schema v7).
    public var toward: String?

    public init(along: Double, maneuver: Maneuver, text: String, street: String? = nil, exit: Int? = nil,
                ref: String? = nil, toward: String? = nil) {
        self.along = along
        self.maneuver = maneuver
        self.text = text
        self.street = street
        self.exit = exit
        self.ref = ref
        self.toward = toward
    }
}

public struct TripDay: Codable, Hashable, Identifiable, Sendable {
    public var index: Int
    public var date: String?
    public var distanceKm: Double?
    public var drivingTimeMin: Double?
    public var curvinessScore: Double?
    public var ascentM: Double?
    public var highlights: [Highlight]
    /// Navigable route file (GraphHopper /navigate response) relative to the trip folder.
    public var routeRef: String?
    /// Raw geometry (e.g. imported from GPX) — used for display and local off-route guidance.
    public var track: Polyline?
    public var planBRefs: [PlanBRef]
    public var fuelStops: [FuelStopRef]
    public var meals: [POIChoice]
    public var lodging: [POIChoice]
    /// Turn-by-turn guidance along `track` (schema v2; empty for GPX imports and v1 trips).
    public var instructions: [TurnInstruction]
    /// Speed cameras and hazards along `track` (schema v3).
    public var alerts: [RoadAlert]
    /// Fuel stations within 3 km of `track` (schema v4), from OpenStreetMap; `fuelStops` are placed among them.
    public var stations: [FuelStation]
    /// Known legal speed limits along `track` (schema v6).
    public var speedLimits: [SpeedLimitRange]
    /// Cafés, viewpoints and drinking water near `track` (schema v6).
    public var pauses: [PauseSpot]
    /// Road book (schema v8, written by the planner): start and end towns of the stage, recommended departure time
    /// (« 07:30 ») and a one-line note on the stage.
    public var from: String?
    public var to: String?
    public var departure: String?
    public var summary: String?

    public var id: Int { index }

    public init(index: Int, date: String? = nil, distanceKm: Double? = nil, drivingTimeMin: Double? = nil,
                curvinessScore: Double? = nil, ascentM: Double? = nil, highlights: [Highlight] = [],
                routeRef: String? = nil, track: Polyline? = nil, planBRefs: [PlanBRef] = [],
                fuelStops: [FuelStopRef] = [], meals: [POIChoice] = [], lodging: [POIChoice] = [],
                instructions: [TurnInstruction] = [], alerts: [RoadAlert] = [], stations: [FuelStation] = [],
                speedLimits: [SpeedLimitRange] = [], pauses: [PauseSpot] = []) {
        self.speedLimits = speedLimits
        self.pauses = pauses
        self.index = index
        self.date = date
        self.distanceKm = distanceKm
        self.drivingTimeMin = drivingTimeMin
        self.curvinessScore = curvinessScore
        self.ascentM = ascentM
        self.highlights = highlights
        self.routeRef = routeRef
        self.track = track
        self.planBRefs = planBRefs
        self.fuelStops = fuelStops
        self.meals = meals
        self.lodging = lodging
        self.instructions = instructions
        self.alerts = alerts
        self.stations = stations
    }

    enum CodingKeys: String, CodingKey {
        case index, date, distanceKm, drivingTimeMin, curvinessScore, ascentM, highlights, routeRef, track
        case planBRefs, fuelStops, meals, lodging, instructions, alerts, stations, speedLimits, pauses
        case from, to, departure, summary
    }

    /// Lenient: missing lists default to empty (planner output robustness).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        distanceKm = try c.decodeIfPresent(Double.self, forKey: .distanceKm)
        drivingTimeMin = try c.decodeIfPresent(Double.self, forKey: .drivingTimeMin)
        curvinessScore = try c.decodeIfPresent(Double.self, forKey: .curvinessScore)
        ascentM = try c.decodeIfPresent(Double.self, forKey: .ascentM)
        highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
        routeRef = try c.decodeIfPresent(String.self, forKey: .routeRef)
        track = try c.decodeIfPresent(Polyline.self, forKey: .track)
        planBRefs = try c.decodeIfPresent([PlanBRef].self, forKey: .planBRefs) ?? []
        fuelStops = try c.decodeIfPresent([FuelStopRef].self, forKey: .fuelStops) ?? []
        meals = try c.decodeIfPresent([POIChoice].self, forKey: .meals) ?? []
        lodging = try c.decodeIfPresent([POIChoice].self, forKey: .lodging) ?? []
        instructions = try c.decodeIfPresent([TurnInstruction].self, forKey: .instructions) ?? []
        alerts = try c.decodeIfPresent([RoadAlert].self, forKey: .alerts) ?? []
        stations = try c.decodeIfPresent([FuelStation].self, forKey: .stations) ?? []
        speedLimits = try c.decodeIfPresent([SpeedLimitRange].self, forKey: .speedLimits) ?? []
        pauses = try c.decodeIfPresent([PauseSpot].self, forKey: .pauses) ?? []
        from = try c.decodeIfPresent(String.self, forKey: .from)
        to = try c.decodeIfPresent(String.self, forKey: .to)
        departure = try c.decodeIfPresent(String.self, forKey: .departure)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}
