import Foundation

// trip.json — schema v1. See docs/trip-schema.md.
// Any breaking change: bump `Trip.currentSchemaVersion` and add a migration.

public enum TripStatus: String, Codable, CaseIterable, Sendable {
    case draft, proposed, validated, ready, active, done
}

public enum Verification: String, Codable, Sendable {
    case verified, unverified
}

public enum POIType: String, Codable, CaseIterable, Sendable {
    case meal, lodging, fuel, pass, viewpoint
}

public struct Place: Codable, Hashable, Sendable {
    public var name: String
    public var point: GeoPoint?
    public init(name: String, point: GeoPoint? = nil) {
        self.name = name
        self.point = point
    }
}

public struct Bike: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var model: String
    /// Real-world range with a full tank, km (entered by the rider — never guessed).
    public var rangeKm: Double
    public var consumptionLPer100: Double?
    /// Safety margin applied to the range, percent.
    public var reserveMarginPct: Double

    public init(id: String = UUID().uuidString, model: String, rangeKm: Double,
                consumptionLPer100: Double? = nil, reserveMarginPct: Double = 15) {
        self.id = id
        self.model = model
        self.rangeKm = rangeKm
        self.consumptionLPer100 = consumptionLPer100
        self.reserveMarginPct = reserveMarginPct
    }

    /// Usable range, metres.
    public var usableRangeMeters: Double {
        max(0, rangeKm * 1000 * (1 - reserveMarginPct / 100))
    }
}

public struct RoadPreferences: Codable, Hashable, Sendable {
    public var avoidMotorway: Bool
    public var avoidTrunk: Bool
    /// 1 (don't care) … 5 (curves only).
    public var curvinessLevel: Int

    public init(avoidMotorway: Bool = true, avoidTrunk: Bool = true, curvinessLevel: Int = 4) {
        self.avoidMotorway = avoidMotorway
        self.avoidTrunk = avoidTrunk
        self.curvinessLevel = curvinessLevel
    }
}

public enum Riders: String, Codable, CaseIterable, Sendable {
    case solo, duo
}

public struct MandatoryStop: Codable, Hashable, Sendable {
    public var place: Place
    /// Optional ISO date-time "yyyy-MM-dd'T'HH:mm".
    public var at: String?
    public init(place: Place, at: String? = nil) {
        self.place = place
        self.at = at
    }
}

public struct TripParams: Codable, Hashable, Sendable {
    public var start: Place
    /// nil = loop back to start.
    public var end: Place?
    /// ISO dates "yyyy-MM-dd".
    public var dateStart: String
    public var dateEnd: String
    /// Region ids from Resources/regions.json.
    public var zone: [String]
    public var bikes: [Bike]
    public var riders: Riders
    public var luggage: Bool
    public var maxKmPerDay: Double
    /// 0 = pure riding … 1 = contemplative.
    public var style: Double
    public var budgetPerDayEur: Double?
    public var mandatoryStops: [MandatoryStop]
    public var constraints: String
    public var roads: RoadPreferences
    /// Hard ceiling between fuel stops from the project rules (200 km).
    public var maxFuelIntervalKm: Double

    public init(start: Place, end: Place? = nil, dateStart: String, dateEnd: String,
                zone: [String] = [], bikes: [Bike] = [], riders: Riders = .solo, luggage: Bool = false,
                maxKmPerDay: Double = 300, style: Double = 0.3, budgetPerDayEur: Double? = nil,
                mandatoryStops: [MandatoryStop] = [], constraints: String = "",
                roads: RoadPreferences = RoadPreferences(), maxFuelIntervalKm: Double = 200) {
        self.start = start
        self.end = end
        self.dateStart = dateStart
        self.dateEnd = dateEnd
        self.zone = zone
        self.bikes = bikes
        self.riders = riders
        self.luggage = luggage
        self.maxKmPerDay = maxKmPerDay
        self.style = style
        self.budgetPerDayEur = budgetPerDayEur
        self.mandatoryStops = mandatoryStops
        self.constraints = constraints
        self.roads = roads
        self.maxFuelIntervalKm = maxFuelIntervalKm
    }

    enum CodingKeys: String, CodingKey {
        case start, end, dateStart, dateEnd, zone, bikes, riders, luggage, maxKmPerDay, style
        case budgetPerDayEur, mandatoryStops, constraints, roads, maxFuelIntervalKm
    }

    /// Lenient: only start and dates are mandatory; everything else falls back to the project defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Place.self, forKey: .start)
        end = try c.decodeIfPresent(Place.self, forKey: .end)
        dateStart = try c.decode(String.self, forKey: .dateStart)
        dateEnd = try c.decode(String.self, forKey: .dateEnd)
        zone = try c.decodeIfPresent([String].self, forKey: .zone) ?? []
        bikes = try c.decodeIfPresent([Bike].self, forKey: .bikes) ?? []
        riders = try c.decodeIfPresent(Riders.self, forKey: .riders) ?? .solo
        luggage = try c.decodeIfPresent(Bool.self, forKey: .luggage) ?? false
        maxKmPerDay = try c.decodeIfPresent(Double.self, forKey: .maxKmPerDay) ?? 300
        style = try c.decodeIfPresent(Double.self, forKey: .style) ?? 0.3
        budgetPerDayEur = try c.decodeIfPresent(Double.self, forKey: .budgetPerDayEur)
        mandatoryStops = try c.decodeIfPresent([MandatoryStop].self, forKey: .mandatoryStops) ?? []
        constraints = try c.decodeIfPresent(String.self, forKey: .constraints) ?? ""
        roads = try c.decodeIfPresent(RoadPreferences.self, forKey: .roads) ?? RoadPreferences()
        maxFuelIntervalKm = try c.decodeIfPresent(Double.self, forKey: .maxFuelIntervalKm) ?? 200
    }

    /// Group range = the most limiting bike (SPEC §4.2).
    public var groupUsableRangeMeters: Double? {
        bikes.map(\.usableRangeMeters).min()
    }

    /// Effective max distance between two fuel stops, metres.
    public var fuelIntervalMeters: Double {
        let rule = maxFuelIntervalKm * 1000
        guard let range = groupUsableRangeMeters else { return rule }
        return min(rule, range)
    }
}

public struct POI: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: POIType
    public var name: String
    public var address: String?
    public var phone: String?
    public var website: String?
    public var point: GeoPoint?
    /// URL of the source that backs this POI. No source ⇒ must be `.unverified`.
    public var source: String?
    public var verification: Verification
    public var verifiedAt: String?
    public var note: String?

    public init(id: String = UUID().uuidString, type: POIType, name: String, address: String? = nil,
                phone: String? = nil, website: String? = nil, point: GeoPoint? = nil, source: String? = nil,
                verification: Verification = .unverified, verifiedAt: String? = nil, note: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.address = address
        self.phone = phone
        self.website = website
        self.point = point
        self.source = source
        self.verification = verification
        self.verifiedAt = verifiedAt
        self.note = note
    }

    /// Enforces the "never invent" rule: a POI without a source cannot be verified.
    public func sanitized() -> POI {
        var copy = self
        if (source ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            copy.verification = .unverified
        }
        return copy
    }
}

public struct POIChoice: Codable, Hashable, Sendable {
    public var poiId: String
    public var selected: Bool
    public init(poiId: String, selected: Bool = false) {
        self.poiId = poiId
        self.selected = selected
    }
}

public struct Highlight: Codable, Hashable, Sendable {
    public var name: String
    public var type: POIType
    public var point: GeoPoint?
    public init(name: String, type: POIType = .pass, point: GeoPoint? = nil) {
        self.name = name
        self.type = type
        self.point = point
    }
}

public struct FuelStopRef: Codable, Hashable, Sendable {
    public var name: String
    public var point: GeoPoint
    public var kmFromStart: Double
    public init(name: String, point: GeoPoint, kmFromStart: Double) {
        self.name = name
        self.point = point
        self.kmFromStart = kmFromStart
    }
}

public struct PlanBRef: Codable, Hashable, Sendable {
    public var label: String
    public var routeRef: String
    public init(label: String, routeRef: String) {
        self.label = label
        self.routeRef = routeRef
    }
}

/// Maneuver kinds, mapped from GraphHopper instruction signs by the companion (schema v2).
public enum Maneuver: String, Codable, CaseIterable, Sendable {
    case depart, straight, slightLeft, slightRight, turnLeft, turnRight, sharpLeft, sharpRight
    case keepLeft, keepRight, uTurn, roundabout, via, arrive

    /// Tolerant: an unknown maneuver from a newer companion reads as `straight` instead of failing the whole trip.
    public init(from decoder: Decoder) throws {
        self = Maneuver(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .straight
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

    public init(along: Double, maneuver: Maneuver, text: String, street: String? = nil, exit: Int? = nil) {
        self.along = along
        self.maneuver = maneuver
        self.text = text
        self.street = street
        self.exit = exit
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

    public var id: Int { index }

    public init(index: Int, date: String? = nil, distanceKm: Double? = nil, drivingTimeMin: Double? = nil,
                curvinessScore: Double? = nil, ascentM: Double? = nil, highlights: [Highlight] = [],
                routeRef: String? = nil, track: Polyline? = nil, planBRefs: [PlanBRef] = [],
                fuelStops: [FuelStopRef] = [], meals: [POIChoice] = [], lodging: [POIChoice] = [],
                instructions: [TurnInstruction] = [], alerts: [RoadAlert] = []) {
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
    }

    enum CodingKeys: String, CodingKey {
        case index, date, distanceKm, drivingTimeMin, curvinessScore, ascentM, highlights, routeRef, track
        case planBRefs, fuelStops, meals, lodging, instructions, alerts
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
    }
}

public struct ChecklistItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    /// Relative due date, e.g. "J-15", "J-1".
    public var due: String
    public var done: Bool
    /// true = generated/rechecked automatically by the app.
    public var auto: Bool
    public init(id: String = UUID().uuidString, label: String, due: String, done: Bool = false, auto: Bool = true) {
        self.id = id
        self.label = label
        self.due = due
        self.done = done
        self.auto = auto
    }
}

public enum PackIntegrity: String, Codable, Sendable {
    case ok, missing, unknown
}

public struct OfflinePack: Codable, Hashable, Sendable {
    public var tiles: String?
    public var radars: String?
    public var stations: String?
    public var integrity: PackIntegrity
    public init(tiles: String? = nil, radars: String? = nil, stations: String? = nil, integrity: PackIntegrity = .unknown) {
        self.tiles = tiles
        self.radars = radars
        self.stations = stations
        self.integrity = integrity
    }
}

public struct Trip: Codable, Hashable, Identifiable, Sendable {
    /// v2: `days[].instructions` ; v3: `days[].alerts` (both additive). Older files are migrated on decode.
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var status: TripStatus
    public var params: TripParams
    public var days: [TripDay]
    public var pois: [POI]
    public var checklist: [ChecklistItem]
    public var offlinePack: OfflinePack

    public init(id: String = UUID().uuidString, name: String, status: TripStatus = .draft, params: TripParams,
                days: [TripDay] = [], pois: [POI] = [], checklist: [ChecklistItem] = [],
                offlinePack: OfflinePack = OfflinePack()) {
        self.schemaVersion = Trip.currentSchemaVersion
        self.id = id
        self.name = name
        self.status = status
        self.params = params
        self.days = days
        self.pois = pois
        self.checklist = checklist
        self.offlinePack = offlinePack
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, status, params, days, pois, checklist, offlinePack
    }

    /// Lenient: missing lists / pack default to empty (planner output robustness).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(TripStatus.self, forKey: .status) ?? .draft
        params = try c.decode(TripParams.self, forKey: .params)
        days = try c.decodeIfPresent([TripDay].self, forKey: .days) ?? []
        pois = try c.decodeIfPresent([POI].self, forKey: .pois) ?? []
        checklist = try c.decodeIfPresent([ChecklistItem].self, forKey: .checklist) ?? []
        offlinePack = try c.decodeIfPresent(OfflinePack.self, forKey: .offlinePack) ?? OfflinePack()
    }

    public func poi(id: String) -> POI? { pois.first { $0.id == id } }

    /// Selected meal/lodging POIs for a day, in order.
    public func selectedStops(for day: TripDay) -> [POI] {
        (day.meals + day.lodging).filter(\.selected).compactMap { poi(id: $0.poiId) }
    }
}

// MARK: - JSON I/O

public enum TripCodec {
    public static func decode(_ data: Data) throws -> Trip {
        let trip = try JSONDecoder().decode(Trip.self, from: data)
        guard trip.schemaVersion <= Trip.currentSchemaVersion else {
            throw TripCodecError.unsupportedSchemaVersion(trip.schemaVersion)
        }
        var sanitized = trip
        sanitized.schemaVersion = Trip.currentSchemaVersion   // v1/v2 → v3: only optional fields were added
        sanitized.pois = trip.pois.map { $0.sanitized() }
        return sanitized
    }

    public static func encode(_ trip: Trip) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(trip)
    }
}

public enum TripCodecError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}
