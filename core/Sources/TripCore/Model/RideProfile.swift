import Foundation

/// Type of motorcycle (garage). Decides which roads are acceptable (schema v5).
public enum BikeCategory: String, Codable, CaseIterable, Sendable {
    case sport, roadster, touring, trail, enduro, custom

    /// Tolerant: an unknown value reads as `roadster` (asphalt only).
    public init(from decoder: Decoder) throws {
        self = BikeCategory(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .roadster
    }

    public var label: String {
        switch self {
        case .sport: "Sportive"
        case .roadster: "Roadster"
        case .touring: "Routière / GT"
        case .trail: "Trail"
        case .enduro: "Enduro"
        case .custom: "Custom / cruiser"
        }
    }

    /// 0 = asphalt only, 1 = gravel roads and good tracks, 2 = tracks sought.
    public var offroadLevel: Int {
        switch self {
        case .sport, .roadster, .touring, .custom: 0
        case .trail: 1
        case .enduro: 2
        }
    }
}

/// What the rider wants from the trip (schema v5).
public enum TripStyle: String, Codable, CaseIterable, Sendable {
    case balade, kiff, rapide, tourisme

    public init(from decoder: Decoder) throws {
        self = TripStyle(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .kiff
    }

    public var label: String {
        switch self {
        case .balade: "Balade"
        case .kiff: "Kiff (virages)"
        case .rapide: "Rapide"
        case .tourisme: "Tourisme"
        }
    }

    /// Legacy `style` value (0 = pure riding … 1 = contemplative), kept in sync for older readers.
    public var styleValue: Double {
        switch self {
        case .kiff: 0.1
        case .rapide: 0.3
        case .balade: 0.7
        case .tourisme: 0.9
        }
    }
}

public enum RiderLevel: String, Codable, CaseIterable, Sendable {
    case debutant, intermediaire, confirme, expert

    public init(from decoder: Decoder) throws {
        self = RiderLevel(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .confirme
    }

    public var label: String {
        switch self {
        case .debutant: "Débutant"
        case .intermediaire: "Intermédiaire"
        case .confirme: "Confirmé"
        case .expert: "Expert"
        }
    }
}

/// GraphHopper profiles on the PC (companion/graphhopper/custom_models).
public enum RouteProfile: String, Sendable {
    case curvy = "moto_curvy", fast = "moto_fast", adventure = "moto_adventure", enduro = "moto_enduro"
}

extension TripParams {
    /// The group rides together: the most road-bound bike decides; « rapide » takes the fastest roads.
    /// Mirrored by the companion (finalize.route_profile).
    public var routeProfile: RouteProfile {
        if tripStyle == .rapide { return .fast }
        switch bikes.compactMap(\.category).map(\.offroadLevel).min() ?? 0 {
        case 2: return .enduro
        case 1: return .adventure
        default: return .curvy
        }
    }
}
