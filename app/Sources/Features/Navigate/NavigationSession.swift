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
    private var recordedTimes: [Date] = []
    private var recordedSpeeds: [Double] = []
    /// Summary of the ride, set by `stop()` (nil for a ride shorter than 200 m).
    private(set) var finishedRide: RideLog?
    /// Known legal limit where the rider is (nil = unknown: nothing shown).
    @Published private(set) var speedLimit: Int?
    /// Pause suggested after 1 h 30 of riding (café, viewpoint or water in the next 15 km).
    @Published private(set) var pauseSuggestion: (spot: PauseSpot, distance: Double)?
    private var breaks = BreakTracker()
    private var overLimitSince: Date?
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
    /// Next weather hazard on the route (Open-Meteo every 20 min when online, SPEC §5.3) and its status line.
    @Published private(set) var weatherAhead: RouteWeather.Hazard?
    @Published private(set) var weatherStatus: String?
    private let weather = WeatherClient()
    private var weatherHazards: [RouteWeather.Hazard] = []
    private var lastWeatherFetch: Date?
    private var weatherUpdatedAt: Date?
    private var weatherTask: Task<Void, Never>?

    /// Detour to a place picked « autour de moi »: while active, it replaces the trip guidance.
    @Published private(set) var detour: DetourRoute.Guidance?
    @Published private(set) var detourUpdate: DetourRoute.Guidance.Update?
    private var detourId = ""

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
        weatherTask?.cancel()
        location.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        onPaceUpdate(pace)
        finishedRide = RideStore.log(trip: trip, day: day, points: recorded, times: recordedTimes, speeds: recordedSpeeds)
    }

    /// Road route back to the track while off route (Apple Maps, 5 s, when online); cancelled once back on it.
    @Published private(set) var rejoin: DetourRoute.Guidance?
    @Published private(set) var rejoinUpdate: DetourRoute.Guidance.Update?
    private var rejoinId = ""
    private var rejoinTask: Task<Void, Never>?
    private var rejoinPlannedAt: Date?

    private func planRejoinIfNeeded(from here: GeoPoint, to target: GeoPoint) {
        guard rejoin == nil, rejoinTask == nil else { return }
        if let last = rejoinPlannedAt, Date().timeIntervalSince(last) < 60 { return }
        rejoinPlannedAt = Date()
        rejoinTask = Task { [weak self] in
            let road = await NearbySearch.roadRoute(to: target, name: "Retour au tracé", from: here)
            guard let self else { return }
            self.rejoinTask = nil
            guard let road, self.offRoute else { return }        // offline: the arrow toward the point stays
            self.rejoinId = String(UUID().uuidString.prefix(6))
            self.rejoin = DetourRoute.Guidance(route: road)
            self.voice.say("Itinéraire de retour calculé : \(TurnGuide.spokenDistance(road.track.length).replacingOccurrences(of: "Dans ", with: "")).",
                           key: "\(self.rejoinId)-start", cooldown: 5)
        }
    }

    func startDetour(_ route: DetourRoute) {
        detourId = String(UUID().uuidString.prefix(6))
        detour = DetourRoute.Guidance(route: route)
        detourUpdate = nil
        voice.say(route.isRoad
                  ? "Itinéraire vers \(route.name), \(TurnGuide.spokenDistance(route.track.length).replacingOccurrences(of: "Dans ", with: ""))."
                  : "Pas d'itinéraire sans réseau. Direction \(route.name) à vol d'oiseau.",
                  key: "\(detourId)-start", cooldown: 5)
    }

    func endDetour() {
        detour = nil
        detourUpdate = nil
        detector = OffRouteDetector()
        voice.say("Reprise de l'itinéraire.", key: "\(detourId)-end", cooldown: 5)
    }

    private func handle(_ fix: LocationService.Fix) {
        if let last = recordedTimes.last { breaks.update(speed: fix.speed, dt: fix.time.timeIntervalSince(last)) }
        recorded.append(fix.point)
        recordedTimes.append(fix.time)
        recordedSpeeds.append(fix.speed)
        speedKmh = max(0, fix.speed) * 3.6

        if var d = detour {
            let u = d.update(position: fix.point, speed: max(0, fix.speed))
            detour = d
            detourUpdate = u
            for a in u.announcements { voice.say(a.text, key: "\(detourId)-\(a.key)", cooldown: 3_600) }
            // Cameras and hazards stay announced during the detour (offline pack, direction of travel).
            let heading: Double? = fix.speed >= 2 && fix.course >= 0 ? fix.course : nil
            for a in AlertPackStore.shared.guide?.announcements(position: fix.point, heading: heading, cameras: camerasEnabled) ?? [] {
                voice.say(a.text, key: a.key, cooldown: 600)
            }
            return
        }

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
            let heading: Double? = fix.speed >= 2 && fix.course >= 0 ? fix.course : nil
            // Rejoin point « au plus logique » (ahead, weighing distance vs skipped track, no U-turn).
            if let target = RejoinGuide.logicalTarget(from: fix.point, heading: heading, route: route,
                                                      lastProgress: lastProgress ?? 0) {
                rejoinDistance = Geo.distance(fix.point, target.point)
                rejoinBearing = Geo.bearing(fix.point, target.point)
                planRejoinIfNeeded(from: fix.point, to: target.point)
            }
            if !wasOff { voice.say("Hors tracé. Je cherche le meilleur chemin pour rejoindre l'itinéraire.", key: "offroute", cooldown: 30) }
            if var r = rejoin {
                let u = r.update(position: fix.point, speed: max(0, fix.speed))
                rejoin = r
                rejoinUpdate = u
                for a in u.announcements where a.key != "detour-arrived" {
                    voice.say(a.text, key: "\(rejoinId)-\(a.key)", cooldown: 3_600)
                }
                // Left the rejoin route too: plan again (at most once a minute).
                if r.route.isRoad, let m = r.route.track.locate(fix.point), m.lateralOffset > 100 { rejoinPlannedAt = nil; rejoin = nil }
            }
        } else {
            lastProgress = snap.progress
            rejoinDistance = nil
            rejoinBearing = nil
            rejoin = nil
            rejoinUpdate = nil
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
            speedLimit = SpeedLimits.limit(day.speedLimits, at: snap.progress)
            // Spoken warning when staying over a known limit for 3 s (at most once a minute per limit).
            if let limit = speedLimit, SpeedLimits.isOver(speedKmh: speedKmh, limit: limit) {
                let since = overLimitSince ?? fix.time
                overLimitSince = since
                if fix.time.timeIntervalSince(since) >= 3 {
                    voice.say("Attention, limitation à \(limit).", key: "speed-\(limit)", cooldown: 60)
                }
            } else {
                overLimitSince = nil
            }
            pauseSuggestion = PauseAdvisor.suggestion(day.pauses, progress: snap.progress,
                                                      ridingSinceBreak: breaks.ridingSinceBreak)
            if let p = pauseSuggestion {
                let when = TurnGuide.lowercasingFirst(TurnGuide.spokenDistance(p.distance))
                voice.say("Tu roules depuis plus d'une heure et demie. Pause possible \(when) : \(p.spot.name).",
                          key: "pause", cooldown: 30 * 60)
            }
            refreshTrafficIfNeeded(progress: snap.progress)
            refreshWeatherIfNeeded(progress: snap.progress)
            weatherAhead = weatherHazards.first { $0.along > snap.progress }
            if let h = weatherAhead {
                let when = TurnGuide.lowercasingFirst(TurnGuide.spokenDistance(h.along - snap.progress))
                voice.say("Météo : \(h.summary) prévu \(when), vers \(WeatherClient.hour(h.eta)).",
                          key: "weather-\(Int(h.along / 1000))", cooldown: 3_600)
            }
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

    /// Every 5 min when a TomTom key is set: incidents on the next 200 km (4 requests of 50 km). Located once per
    /// fetch (not per GPS fix) to spare the battery. A failure only changes the status line; guidance never waits.
    private func refreshTrafficIfNeeded(progress: Double) {
        guard let traffic, trafficTask == nil else { return }
        if let last = lastTrafficFetch, Date().timeIntervalSince(last) < 300 { return }
        lastTrafficFetch = Date()
        let route = self.route
        trafficTask = Task { [weak self] in
            do {
                let ahead = try await traffic.alongRoute(route, from: progress, length: 200_000)
                guard let self else { return }
                self.located = ahead
                self.trafficStatus = "Trafic à jour \(Format.time(Date())) · \(ahead.count) incident(s) sur 200 km"
            } catch {
                self?.trafficStatus = "Trafic : \(TomTomTrafficClient.describe(error))"
            }
            self?.trafficTask = nil
        }
    }

    /// Every 20 min when online: forecasts at the passing time of the next ~180 km (12 points, one request).
    /// Offline, the last forecast is kept and shown as « météo du HH:MM ».
    private func refreshWeatherIfNeeded(progress: Double) {
        guard weatherTask == nil else { return }
        if let last = lastWeatherFetch, Date().timeIntervalSince(last) < 20 * 60 { return }
        lastWeatherFetch = Date()
        let samples = RouteWeather.samples(route: route, from: progress, maxCount: 12)
        let etas = RouteWeather.etas(samples: samples, route: route, progress: progress, start: Date(), pace: pace)
        weatherTask = Task { [weak self] in
            guard let self else { return }
            do {
                let forecasts = try await self.weather.forecasts(for: samples, timeout: 5)
                self.weatherHazards = RouteWeather.hazards(samples: samples, etas: etas, forecasts: forecasts)
                self.weatherUpdatedAt = Date()
                self.weatherStatus = "Météo \(Format.time(Date()))"
            } catch {
                self.weatherStatus = self.weatherUpdatedAt.map { "Météo du \(Format.time($0))" } ?? "Météo indisponible"
            }
            self.weatherTask = nil
        }
    }

    /// Recorded track as GPX (after-trip stats, SPEC §4.5).
    func recordedGPX() -> String {
        GPX.write(name: "\(trip.name) — trace réelle jour \(day.index)",
                  tracks: [(name: "Trace réelle", line: Polyline(recorded))], waypoints: [])
    }
}
