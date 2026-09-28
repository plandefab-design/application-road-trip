import Combine
import Foundation
import TripCore
import UIKit

/// Local, deterministic navigation for one day of a trip (no AI, no companion, no network required).
/// Turn-by-turn from the instructions stored in the trip (computed on the PC before departure);
/// "follow the track" guidance when a day has none (GPX import).
@MainActor
final class NavigationSession: ObservableObject {
    @Published private(set) var snapshot: NavigationSnapshot?
    @Published private(set) var offRoute = false
    @Published private(set) var rejoinDistance: Double?
    @Published private(set) var rejoinBearing: Double?
    @Published private(set) var speedKmh: Double = 0
    @Published private(set) var recorded: [GeoPoint] = []
    /// Next maneuver and its distance, for the top banner (nil: no instructions, or none left).
    @Published private(set) var nextTurn: (instruction: TurnInstruction, distance: Double)?
    /// Next speed camera or hazard ahead, for the banner.
    @Published private(set) var nextAlert: (alert: RoadAlert, distance: Double)?
    /// Rider setting « Annonces radar » (hazards are always announced).
    let camerasEnabled: Bool
    /// Live incidents on the route ahead (TomTom, optional) and the status line shown to the rider.
    @Published private(set) var incidentsAhead: [IncidentAhead] = []
    @Published private(set) var trafficStatus: String?
    private let traffic: TrafficClient?
    private var located: [IncidentAhead] = []
    private var lastTrafficFetch: Date?
    private var trafficTask: Task<Void, Never>?

    let trip: Trip
    let day: TripDay
    let route: Polyline

    private let computer: NavigationComputer
    private var pace: PaceEstimator
    private var detector = OffRouteDetector()
    private var lastProgress: Double?
    private var lastFixTime: Date?
    private var cancellable: AnyCancellable?
    private let location: LocationService
    private let voice: VoiceService
    private let onPaceUpdate: (PaceEstimator) -> Void

    init(trip: Trip, day: TripDay, location: LocationService, voice: VoiceService,
         pace: PaceEstimator, camerasEnabled: Bool, traffic: TrafficClient?,
         onPaceUpdate: @escaping (PaceEstimator) -> Void) {
        self.camerasEnabled = camerasEnabled
        self.traffic = traffic
        let r = day.track ?? Polyline([])
        self.trip = trip
        self.day = day
        self.route = r
        self.location = location
        self.voice = voice
        self.pace = pace
        self.onPaceUpdate = onPaceUpdate

        let fuel: [(name: String, along: Double)] = day.fuelStops.compactMap { f in
            r.locate(f.point).map { (name: f.name, along: $0.distanceAlong) }
        }
        let stops: [(name: String, along: Double, duration: TimeInterval)] = trip.selectedStops(for: day).compactMap { poi in
            guard let p = poi.point, let m = r.locate(p), m.lateralOffset < 2_000 else { return nil }
            let duration: TimeInterval = poi.type == .meal ? 75 * 60 : 0
            return (name: poi.name, along: m.distanceAlong, duration: duration)
        }
        computer = NavigationComputer(route: r, fuelStops: fuel, stops: stops,
                                      plannedDuration: day.drivingTimeMin.map { $0 * 60 },
                                      dayStart: nil)
        if traffic != nil { trafficStatus = "Trafic : en attente du réseau" }
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true   // screen stays on while riding
        location.startNavigation()
        cancellable = location.$lastFix.compactMap { $0 }.sink { [weak self] fix in
            self?.handle(fix)
        }
        voice.say("Navigation démarrée. Étape \(day.index), \(Int(route.length / 1000)) kilomètres.", key: "start")
    }

    func stop() {
        cancellable = nil
        trafficTask?.cancel()
        location.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        onPaceUpdate(pace)
    }

    private func handle(_ fix: LocationService.Fix) {
        recorded.append(fix.point)
        speedKmh = max(0, fix.speed) * 3.6

        guard let snap = computer.snapshot(position: fix.point, lastProgress: lastProgress, now: fix.time, pace: pace) else { return }

        // Learn pace on the segment we are on (local routing speeds until GraphHopper provides real ones).
        if let dt = lastFixTime.map({ fix.time.timeIntervalSince($0) }), fix.speed >= 0,
           let seg = SegmentBuilder.remaining(computer.segments, after: snap.progress).first {
            pace.add(speed: fix.speed, routingSpeed: seg.routingSpeed, roadClass: seg.roadClass, dt: dt)
        }
        lastFixTime = fix.time

        let state = detector.update(lateralOffset: snap.lateralOffset, time: fix.time.timeIntervalSince1970, accuracy: fix.accuracy)
        let wasOff = offRoute
        offRoute = state == .offRoute
        if offRoute {
            // Local rejoin guidance toward the closest point ahead on the track.
            if let target = RejoinGuide.target(from: fix.point, route: route, lastProgress: lastProgress ?? 0) {
                rejoinDistance = target.lateralOffset
                rejoinBearing = Geo.bearing(fix.point, target.projected)
            }
            if !wasOff { voice.say("Hors tracé. Rejoins l'itinéraire.", key: "offroute", cooldown: 30) }
        } else {
            lastProgress = snap.progress
            rejoinDistance = nil
            rejoinBearing = nil
            if wasOff { voice.say("Retour sur l'itinéraire.", key: "onroute", cooldown: 30) }
        }

        if !offRoute, !day.instructions.isEmpty {
            let next = TurnGuide.next(day.instructions, progress: snap.progress)
            nextTurn = next.map { (instruction: $0.instruction, distance: $0.distance) }
            if let a = TurnGuide.announcement(day.instructions, progress: snap.progress, speed: max(0, fix.speed)) {
                voice.say(a.text, key: a.key, cooldown: 3_600)
            }
        }

        if !offRoute, !day.alerts.isEmpty {
            let next = AlertGuide.next(day.alerts, progress: snap.progress, cameras: camerasEnabled)
            if let n = next, n.distance <= AlertGuide.cameraLead {
                nextAlert = (alert: n.alert, distance: n.distance)
            } else {
                nextAlert = nil
            }
            for a in AlertGuide.announcements(day.alerts, progress: snap.progress, cameras: camerasEnabled) {
                voice.say(a.text, key: a.key, cooldown: 3_600)
            }
        }

        if !offRoute {
            refreshTrafficIfNeeded(progress: snap.progress)
            incidentsAhead = located.filter { $0.along > snap.progress }
            for a in TrafficIncidents.announcements(incidentsAhead, progress: snap.progress) {
                voice.say(a.text, key: a.key, cooldown: 3_600)
            }
        }

        if let fuel = snap.nextFuel, fuel.distance < 5_000 {
            voice.say("Plein dans \(Int(fuel.distance / 1000)) kilomètre\(fuel.distance >= 2_000 ? "s" : ""), \(fuel.label).", key: "fuel-\(fuel.label)", cooldown: 900)
        }
        if snap.endOfDay.distance < 200 {
            voice.say("Fin de l'étape \(day.index).", key: "end", cooldown: 3_600)
        }
        snapshot = snap
    }

    /// Every 5 min when a TomTom key is set: incidents on the next 50 km. Located once per fetch (not per GPS
    /// fix) to spare the battery. A failure only changes the status line; guidance never waits for it.
    private func refreshTrafficIfNeeded(progress: Double) {
        guard let traffic, trafficTask == nil else { return }
        if let last = lastTrafficFetch, Date().timeIntervalSince(last) < 300 { return }
        guard let box = TrafficIncidents.boundingBox(route: route, progress: progress) else { return }
        lastTrafficFetch = Date()
        trafficTask = Task { [weak self] in
            do {
                let found = try await traffic.incidents(minLon: box.minLon, minLat: box.minLat, maxLon: box.maxLon, maxLat: box.maxLat)
                guard let self else { return }
                self.located = TrafficIncidents.ahead(found, route: self.route, progress: progress)
                self.trafficStatus = "Trafic à jour \(Format.time(Date()))"
            } catch {
                self?.trafficStatus = "Trafic indisponible (pas de réseau)"
            }
            self?.trafficTask = nil
        }
    }

    /// Recorded track as GPX (after-trip stats, SPEC §4.5).
    func recordedGPX() -> String {
        GPX.write(name: "\(trip.name) — trace réelle jour \(day.index)",
                  tracks: [(name: "Trace réelle", line: Polyline(recorded))], waypoints: [])
    }
}
