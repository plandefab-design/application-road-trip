import Foundation
import TripCore

/// Brings the rider back onto a route after a wrong turn, like a road GPS. The wrong turn is noticed within about
/// 2 s (sharp change of direction) or 3 s; Apple Maps is asked for the way back to three places at once (back where
/// the route was left, just ahead, further on) and the one reaching the route soonest overall wins, 4 s at most.
/// It starts asking as soon as the rider drifts away, so the answer is often ready when the wrong turn is confirmed.
/// Offline: an arrow toward the most logical point. Never waits, never asks the PC nor any AI (CLAUDE.md rule 1).
@MainActor
final class RejoinAssistant {
    struct Output {
        var offRoute = false
        var justLeft = false
        var justBack = false
        /// The way back being followed (map, banner) and the guidance along it.
        var route: DetourRoute?
        var update: DetourRoute.Guidance.Update?
        /// No way back yet (computing, offline): direction and distance to the most logical point.
        var arrow: (bearing: Double, distance: Double)?
        /// Turns, cameras and hazards along the way back; say them under `keyPrefix` + key (one way back = new keys).
        var announcements: [TurnGuide.Announcement] = []
        var keyPrefix = ""
        /// « Hors itinéraire… », « Itinéraire de retour… »: directions talk, silent in « alertes uniquement ».
        var status: String?
    }

    static let retryAfter: TimeInterval = 12
    static let timeout: TimeInterval = 4
    /// Leaving the way back as well: asked again after two fixes this far from it.
    static let leftWayBack = 60.0

    let name: String
    private var detector = OffRouteDetector()
    private var guidance: DetourRoute.Guidance?
    private var planId = ""
    private var task: Task<Void, Never>?
    private var lastAsked: Date?
    private var spare: (route: DetourRoute, from: GeoPoint, at: Date)?
    private var awayFromWayBack = 0
    private var newWayBack = false

    init(name: String = "Retour à l'itinéraire") {
        self.name = name
    }

    var isOffRoute: Bool { detector.state == .offRoute }

    func reset() {
        detector = OffRouteDetector()
        guidance = nil
        task?.cancel()
        task = nil
        spare = nil
        lastAsked = nil
        awayFromWayBack = 0
    }

    /// - Parameters:
    ///   - progress: the rider's projection on the route (its direction there is compared with the course)
    ///   - lastProgress: the last progress while on the route (where the way back may start from)
    func update(position: GeoPoint, speed: Double, course: Double, accuracy: Double, time: Date, route: Polyline,
                lateralOffset: Double, progress: Double, lastProgress: Double) -> Output {
        var out = Output()
        let heading: Double? = speed >= 4 && course >= 0 ? course : nil
        let delta: Double? = heading.flatMap { h in route.bearing(at: progress).map { Geo.angleDelta($0, h) } }
        let wasOff = isOffRoute
        detector.update(lateralOffset: lateralOffset, time: time.timeIntervalSince1970, accuracy: accuracy, headingDelta: delta)
        out.offRoute = isOffRoute
        out.justLeft = out.offRoute && !wasOff
        out.justBack = !out.offRoute && wasOff

        guard out.offRoute else {
            if out.justBack {
                guidance = nil
                spare = nil
                task?.cancel()
                task = nil
                lastAsked = nil
                out.status = "Retour sur l'itinéraire."
            }
            // Drifting away in another direction: ask already, the answer is ready if the wrong turn is confirmed.
            if lateralOffset > 25, let d = delta, abs(d) >= 45 {
                ask(from: position, heading: heading, route: route, lastProgress: lastProgress)
            }
            return out
        }

        if out.justLeft {
            out.status = "Hors itinéraire, je recalcule."
            if let s = spare, time.timeIntervalSince(s.at) < 30, Geo.distance(s.from, position) < 400 { adopt(s.route) }
        }
        if var g = guidance {
            let u = g.update(position: position, speed: max(0, speed))
            guidance = g
            awayFromWayBack = (u.lateralOffset ?? 0) > Self.leftWayBack ? awayFromWayBack + 1 : 0
            if awayFromWayBack >= 2 {
                guidance = nil                         // the way back was not taken either: a new one, now
                lastAsked = nil
                awayFromWayBack = 0
            } else {
                out.route = g.route
                out.update = u
                out.announcements = u.announcements.filter { $0.key != "detour-arrived" }
                out.keyPrefix = planId
                if newWayBack {
                    newWayBack = false
                    out.status = "Itinéraire de retour : \(TurnGuide.spokenLength(g.route.track.length))."
                }
            }
        }
        if guidance == nil {
            ask(from: position, heading: heading, route: route, lastProgress: lastProgress)
            if let t = RejoinGuide.logicalTarget(from: position, heading: heading, route: route, lastProgress: lastProgress) {
                out.arrow = (bearing: Geo.bearing(position, t.point), distance: Geo.distance(position, t.point))
            }
        }
        return out
    }

    private func ask(from position: GeoPoint, heading: Double?, route: Polyline, lastProgress: Double) {
        guard task == nil else { return }
        if let last = lastAsked, Date().timeIntervalSince(last) < Self.retryAfter { return }
        let candidates = RejoinGuide.candidates(from: position, heading: heading, route: route, lastProgress: lastProgress)
        guard !candidates.isEmpty else { return }
        lastAsked = Date()
        let name = self.name
        task = Task { [weak self] in
            let legs = await AppleDirections.legs(from: position, to: candidates.map(\.point), timeout: Self.timeout)
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            let answered = legs.indices.compactMap { i in legs[i].map { (index: i, leg: $0) } }
            guard let pick = RejoinGuide.best(answered.map { (along: candidates[$0.index].along, seconds: $0.leg.seconds) })
            else { return }                            // offline: the arrow stays, asked again in 12 s
            let chosen = answered[pick]
            let road = NearbySearch.withAlerts(AppleDirections.route(chosen.leg, name: name,
                                                                     destination: candidates[chosen.index].point))
            if self.isOffRoute, self.guidance == nil {
                self.adopt(road)
            } else if !self.isOffRoute {
                self.spare = (route: road, from: position, at: Date())
            }
        }
    }

    private func adopt(_ route: DetourRoute) {
        planId = "rejoin-" + String(UUID().uuidString.prefix(6))
        guidance = DetourRoute.Guidance(route: route)
        spare = nil
        newWayBack = true
        awayFromWayBack = 0
    }
}

extension RejoinAssistant {
    /// One GPS fix on a guided route (free ride, « autour de moi »).
    struct RouteStep {
        var update: DetourRoute.Guidance.Update
        /// Off the route: the way back (map, banner); nil while on it.
        var back: Output?
        /// What to say, each under its key.
        var spoken: [(announcement: TurnGuide.Announcement, key: String)] = []
        var status: String?
    }

    /// The route's own turns, stops and alerts while on it; the way back to it after a wrong turn.
    func follow(_ guidance: inout DetourRoute.Guidance, fix: LocationService.Fix, routeKey: String) -> RouteStep {
        let u = guidance.update(position: fix.point, speed: max(0, fix.speed))
        var step = RouteStep(update: u)
        guard guidance.route.isRoad, let offset = u.lateralOffset else {
            step.spoken = u.announcements.map { (announcement: $0, key: "\(routeKey)-\($0.key)") }
            return step
        }
        let back = update(position: fix.point, speed: fix.speed, course: fix.course, accuracy: fix.accuracy, time: fix.time,
                          route: guidance.route.track, lateralOffset: offset, progress: guidance.progress,
                          lastProgress: guidance.progress)
        step.status = back.status
        if back.offRoute {
            step.back = back
            step.spoken = back.announcements.map { (announcement: $0, key: "\(back.keyPrefix)-\($0.key)") }
        } else {
            step.spoken = u.announcements.map { (announcement: $0, key: "\(routeKey)-\($0.key)") }
        }
        return step
    }
}
