import Foundation

/// A route to a place picked « autour de moi » (fuel, hotel, restaurant…), built from any routing service's
/// geometry and written steps, so the usual guidance (TurnGuide) works on it.
public struct DetourRoute: Equatable, Sendable {
    public let name: String
    public let destination: GeoPoint
    public let track: Polyline
    public let instructions: [TurnInstruction]
    /// false = no route available (offline): straight line, direction only.
    public let isRoad: Bool
    /// Cameras and hazards on this route (from the iPhone's latest pack), announced along it.
    public var alerts: [RoadAlert] = []
    /// Intermediate stops of a route with several destinations (« Étape atteinte : … »).
    public var stops: [RouteStop] = []

    public init(name: String, destination: GeoPoint, track: Polyline, instructions: [TurnInstruction], isRoad: Bool) {
        self.name = name
        self.destination = destination
        self.track = track
        self.instructions = instructions
        self.isRoad = isRoad
    }

    /// Steps given as (text, length in metres) in order: each maneuver sits where the previous steps end.
    public static func road(name: String, destination: GeoPoint, points: [GeoPoint], steps: [(text: String, distance: Double)]) -> DetourRoute {
        var along = 0.0
        var instructions: [TurnInstruction] = []
        for (i, step) in steps.enumerated() {
            let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let maneuver: Maneuver = i == 0 ? .depart : (i == steps.count - 1 ? .arrive : maneuver(from: text))
                instructions.append(TurnInstruction(along: along, maneuver: maneuver, text: text,
                                                    exit: maneuver == .roundabout ? exitNumber(in: text) : nil))
            }
            along += max(0, step.distance)
        }
        return DetourRoute(name: name, destination: destination, track: Polyline(points), instructions: instructions, isRoad: true)
    }

    /// Offline fallback: straight line from here to the place (direction and distance only).
    public static func straight(name: String, from: GeoPoint, to: GeoPoint) -> DetourRoute {
        DetourRoute(name: name, destination: to, track: Polyline([from, to]), instructions: [], isRoad: false)
    }

    /// Guidance state along the detour, fed with every GPS fix.
    public struct Guidance: Sendable {
        public let route: DetourRoute
        public private(set) var progress = 0.0
        public private(set) var arrived = false

        public struct Update: Sendable {
            public let remaining: Double
            public let nextTurn: (instruction: TurnInstruction, distance: Double)?
            /// Direction to the place when there is no road route (offline), degrees.
            public let bearing: Double?
            public let announcements: [TurnGuide.Announcement]
            /// Next intermediate stop and its distance (routes with several destinations).
            public var nextStop: (stop: RouteStop, distance: Double)? = nil
            /// Distance between the rider and the route, metres (nil: straight line); off-route detection.
            public var lateralOffset: Double? = nil
        }

        /// Beyond this distance from the route the rider is not on it: progress waits (no turn skipped on a road
        /// running alongside).
        public static let onRouteOffset = 50.0

        public init(route: DetourRoute) { self.route = route }

        public mutating func update(position: GeoPoint, speed: Double, cameras: Bool = true) -> Update {
            let direct = Geo.distance(position, route.destination)
            var remaining = direct
            var offset: Double?
            if route.isRoad, let m = route.track.locate(position, hint: progress, window: 3_000) ?? route.track.locate(position) {
                offset = m.lateralOffset
                if m.lateralOffset <= Self.onRouteOffset { progress = max(progress, m.distanceAlong) }
                remaining = max(0, route.track.length - progress)
            }
            // Keys prefixed so they never collide with the trip's own announcements.
            var announcements = TurnGuide.announcement(route.instructions, progress: progress, speed: speed)
                .map { [TurnGuide.Announcement(key: "detour-\($0.key)", text: $0.text, urgent: $0.urgent)] } ?? []
            // Cameras and hazards positioned along this route (500 m / 150 m / 300 m like on a trip).
            if route.isRoad {
                announcements += AlertGuide.announcements(route.alerts, progress: progress, cameras: cameras)
                    .map { TurnGuide.Announcement(key: "detour-\($0.key)", text: $0.text, urgent: $0.urgent) }
                announcements += StopGuide.announcements(route.stops, progress: progress)
                    .map { TurnGuide.Announcement(key: "detour-\($0.key)", text: $0.text) }
            }
            if !arrived && (direct < 50 || (route.isRoad && remaining < 30)) {
                arrived = true
                announcements.append(.init(key: "detour-arrived", text: "Vous êtes arrivé : \(route.name)."))
            }
            let next = TurnGuide.next(route.instructions, progress: progress).map { (instruction: $0.instruction, distance: $0.distance) }
            var update = Update(remaining: remaining, nextTurn: next,
                                bearing: route.isRoad ? nil : Geo.bearing(position, route.destination), announcements: announcements)
            update.nextStop = StopGuide.next(route.stops, progress: progress)
            update.lateralOffset = offset
            return update
        }
    }

    /// Roundabout exit written in a direction: « prenez la 3e sortie », « la deuxième sortie », « take the 2nd exit ».
    public static func exitNumber(in text: String) -> Int? {
        let t = text.lowercased()
        if let r = t.range(of: #"(\d+)\s*(e|re|er|ème|eme|st|nd|rd|th)\b"#, options: .regularExpression),
           let n = Int(t[r].prefix { $0.isNumber }), (1...12).contains(n) {
            return n
        }
        let words = ["première": 1, "premiere": 1, "deuxième": 2, "deuxieme": 2, "seconde": 2, "troisième": 3, "troisieme": 3,
                     "quatrième": 4, "quatrieme": 4, "cinquième": 5, "cinquieme": 5, "sixième": 6, "sixieme": 6,
                     "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6]
        return words.first { t.contains("\($0.key) sortie") || t.contains("\($0.key) exit") }?.value
    }

    /// Maneuver from a written direction (French or English), for the banner arrow and the voice timing.
    public static func maneuver(from text: String) -> Maneuver {
        let t = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        if has("rond-point", "roundabout", "giratoire") { return .roundabout }
        if has("demi-tour", "u-turn", "make a u") { return .uTurn }
        if has("arriv", "destination") { return .arrive }
        let left = has("gauche", "left"), right = has("droite", "right")
        if has("légèrement", "legerement", "slight", "serrez", "keep", "restez") {
            return left ? .slightLeft : right ? .slightRight : .straight
        }
        if has("fort", "sharp", "serré") {
            if left { return .sharpLeft }
            if right { return .sharpRight }
        }
        if left { return .turnLeft }
        if right { return .turnRight }
        return .straight
    }
}
