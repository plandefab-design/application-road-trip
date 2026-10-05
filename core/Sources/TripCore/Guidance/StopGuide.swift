import Foundation

/// A stop the rider makes on the route: a fuel stop, the chosen restaurant, the night's hotel, or a waypoint of a
/// free-ride route with several stops.
public struct RouteStop: Equatable, Sendable {
    public enum Kind: String, Sendable { case fuel, meal, lodging, waypoint }
    public let kind: Kind
    public let name: String
    /// Distance along the route, metres.
    public let along: Double

    public init(kind: Kind, name: String, along: Double) {
        self.kind = kind
        self.name = name
        self.along = along
    }

    /// « restaurant Le Cours », « hôtel Les Alizés », « Station Total »: the place as spoken.
    public var spokenName: String {
        let lower = name.lowercased()
        switch kind {
        case .meal: return ["restaurant", "auberge", "bistrot", "brasserie", "café", "crêperie", "pizzeria", "chez "]
            .contains(where: lower.hasPrefix) ? name : "restaurant \(name)"
        case .lodging: return ["hôtel", "hotel", "gîte", "gite", "auberge", "chambre", "camping"].contains(where: lower.hasPrefix) ? name : "hôtel \(name)"
        case .fuel, .waypoint: return name
        }
    }
}

/// The validated stops of a ride, announced like a GPS announces a waypoint: about 5 km before, 500 m before, and on
/// arrival (« Vous êtes arrivé au restaurant Le Cours. Bon appétit ! »). Pure and offline.
public enum StopGuide {
    public static let farWarning = 5_000.0
    public static let nearWarning = 500.0
    public static let arrivedWithin = 80.0

    /// Stops of a stage located on its track: fuel stops, the chosen restaurants and the chosen hotel, in route order.
    public static func stops(for day: TripDay, in trip: Trip, maxOffset: Double = 2_000) -> [RouteStop] {
        guard let track = day.track, !track.isEmpty else { return [] }
        func along(_ p: GeoPoint?) -> Double? {
            guard let p, let m = track.locate(p), m.lateralOffset <= maxOffset else { return nil }
            return m.distanceAlong
        }
        var out: [RouteStop] = day.fuelStops.compactMap { f in along(f.point).map { RouteStop(kind: .fuel, name: f.name, along: $0) } }
        for poi in trip.selectedStops(for: day) {
            guard poi.type == .meal || poi.type == .lodging, let a = along(poi.point) else { continue }
            out.append(RouteStop(kind: poi.type == .meal ? .meal : .lodging, name: poi.name, along: a))
        }
        return out.sorted { $0.along < $1.along }
    }

    /// Next stop not yet reached, with its distance.
    public static func next(_ stops: [RouteStop], progress: Double) -> (stop: RouteStop, distance: Double)? {
        stops.first { $0.along - progress > -arrivedWithin }.map { ($0, max(0, $0.along - progress)) }
    }

    /// The rider drops the next stop (fuel, restaurant, hotel, waypoint): what is left, and where the route resumes,
    /// just beyond the dropped stop, so a way back never leads to the stop that was given up. Stops at the same place
    /// are dropped together. nil when no stop is left.
    public static func skip(_ stops: [RouteStop], progress: Double) -> (skipped: RouteStop, resumeAt: Double, remaining: [RouteStop])? {
        guard let next = next(stops, progress: progress)?.stop else { return nil }
        let resumeAt = next.along + arrivedWithin + 20
        return (next, resumeAt, stops.filter { $0.along > resumeAt })
    }

    /// Announcements due at `progress`; keys are unique per stop and phase.
    public static func announcements(_ stops: [RouteStop], progress: Double) -> [TurnGuide.Announcement] {
        stops.enumerated().compactMap { i, stop in
            let d = stop.along - progress
            if abs(d) <= arrivedWithin {
                return .init(key: "stop-\(i)-arrived", text: arrival(stop))
            }
            guard d > 0 else { return nil }
            if d <= nearWarning {
                return .init(key: "stop-\(i)-near", text: "\(sentenceCase(stop.spokenName)) \(TurnGuide.lowercasingFirst(TurnGuide.spokenDistance(d))).")
            }
            if d <= farWarning {
                return .init(key: "stop-\(i)-far", text: ahead(stop, d))
            }
            return nil
        }
    }

    static func ahead(_ stop: RouteStop, _ d: Double) -> String {
        let when = TurnGuide.lowercasingFirst(TurnGuide.spokenDistance(d))
        switch stop.kind {
        case .fuel: return "Ravitaillement \(when) : \(stop.name)."
        case .meal: return "Pause déjeuner \(when) : \(stop.spokenName)."
        case .lodging: return "\(sentenceCase(stop.spokenName)) \(when), fin de l'étape."
        case .waypoint: return "Étape \(when) : \(stop.name)."
        }
    }

    static func arrival(_ stop: RouteStop) -> String {
        switch stop.kind {
        case .fuel: return "Ravitaillement : \(stop.name). Fais le plein."
        case .meal: return "Vous êtes arrivé : \(stop.spokenName). Bon appétit !"
        case .lodging: return "Vous êtes arrivé : \(stop.spokenName). Fin de l'étape."
        case .waypoint: return "Étape atteinte : \(stop.name)."
        }
    }

    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
