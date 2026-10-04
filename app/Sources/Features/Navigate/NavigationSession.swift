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
    /// Lean angle from the gyroscope (its own refresh, observed by the badge only).
    let lean = LeanMeter()
    /// Precise fixes only (≤ 50 m): the recorded track and the odometer are not inflated by GPS noise.
    private(set) var recorded: [GeoPoint] = []
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
    /// The day's cameras and hazards, completed at start with the iPhone's latest pack (a trip prepared weeks
    /// ago still gets the new cameras, e.g. the daily official French list).
    let alerts: [RoadAlert]
    /// The map's fixed part (route, places, alerts); the view adds what moves (detour, way back).
    let baseMap: MapContent
    /// Pause spots re-positioned on the track (same fix as the alerts).
    private let pauses: [PauseSpot]
    /// Validated stops of the day on the track (fuel, chosen restaurant, hotel), announced like GPS waypoints.
    let stops: [RouteStop]
    /// Next stop within 5 km (or just reached), for the banner.
    @Published private(set) var nextStop: (stop: RouteStop, distance: Double)?

    private let computer: NavigationComputer
    private var pace: PaceEstimator
    private var lastProgress: Double?
    private var lastFixTime: Date?
    private var cancellable: AnyCancellable?
    private let location: LocationService
    private let voice: VoiceService
    private let onPaceUpdate: (PaceEstimator) -> Void

    init(trip: Trip, day: TripDay, location: LocationService, voice: VoiceService,
         pace: PaceEstimator, traffic: TrafficClient?, directions: Bool = true,
         onPaceUpdate: @escaping (PaceEstimator) -> Void) {
        self.directionsSpoken = directions
        self.traffic = traffic
        let r = day.track ?? Polyline([])
        self.trip = trip
        self.day = day
        self.route = r
        let alerts = AlertGuide.merge(AlertGuide.relocated(day.alerts, on: r), with: AlertPackStore.shared.guide?.along(r) ?? [])
        self.alerts = alerts
        // What does not move on the map, built once: the day's route, its places, its cameras and hazards.
        var base = MapContent.from(trip: trip, highlightDay: day.index)
        base.lines = base.lines.filter { $0.id == "day\(day.index)" }
        base.alerts = alerts.compactMap { a in a.point.map { MapContent.AlertDot(point: $0, isCamera: a.kind.isCamera) } }
        base.followUser = true
        self.baseMap = base
        self.pauses = PauseAdvisor.relocated(day.pauses, on: r)
        self.stops = StopGuide.stops(for: day, in: trip)
        self.location = location
        self.voice = voice
        self.pace = pace
        self.onPaceUpdate = onPaceUpdate

        // The same validated stops feed the voice (StopGuide) and the times on the cards (fuel, stop, arrival).
        computer = NavigationComputer(route: r,
                                      fuelStops: stops.filter { $0.kind == .fuel }.map { (name: $0.name, along: $0.along) },
                                      stops: stops.filter { $0.kind == .meal || $0.kind == .lodging }.map {
                                          (name: $0.name, along: $0.along, duration: $0.kind == .meal ? StageTimer.mealStop : 0)
                                      },
                                      plannedDuration: day.drivingTimeMin.map { $0 * 60 },
                                      dayStart: nil)
        if traffic != nil { trafficStatus = "Trafic : en attente du réseau" }
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true   // screen stays on while riding
        location.startNavigation()
        lean.start()
        cancellable = location.$lastFix.compactMap { $0 }.sink { [weak self] fix in
            self?.handle(fix)
        }
        voice.say(directionsSpoken ? "Navigation démarrée. Étape \(day.index), \(Int(route.length / 1000)) kilomètres."
                  : "Alertes uniquement : radars, dangers et accidents annoncés, sans les directions.", key: "start")
        ActiveRide.shared.start(tripId: trip.id, day: day.index)
    }

    func stop() {
        cancellable = nil
        trafficTask?.cancel()
        weatherTask?.cancel()
        location.stop()
        lean.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        onPaceUpdate(pace)
        finishedRide = RideStore.log(trip: trip, day: day, points: recorded, times: recordedTimes, speeds: recordedSpeeds,
                                     lean: lean.summary)
        // Arrived: nothing to rejoin. Left before the end: the home screen offers « Reprendre ».
        if let snap = snapshot, snap.endOfDay.distance < 300 { ActiveRide.shared.finish() }
    }

    /// Way back to the track after a wrong turn (Apple Maps, several places asked at once, 4 s max, when online).
    @Published private(set) var rejoinRoute: DetourRoute?
    @Published private(set) var rejoinUpdate: DetourRoute.Guidance.Update?
    private let wayBack = RejoinAssistant(name: "Retour au tracé")
    /// Off the detour (« autour de moi »): its own way back.
    @Published private(set) var detourBack: RejoinAssistant.Output?
    private let detourWayBack = RejoinAssistant(name: "Retour vers la destination")

    /// « Hors itinéraire… », « Itinéraire de retour… », « Retour sur l'itinéraire »: said with the directions.
    private func sayStatus(_ status: String?) {
        guard let status, directionsSpoken else { return }
        voice.say(status, key: "status-\(status)", cooldown: 20)
    }

    func startDetour(_ route: DetourRoute) {
        detourId = String(UUID().uuidString.prefix(6))
        detour = DetourRoute.Guidance(route: route)
        detourUpdate = nil
        detourBack = nil
        detourWayBack.reset()
        voice.say(route.isRoad
                  ? "Itinéraire vers \(route.name), \(TurnGuide.spokenLength(route.track.length))."
                  : "Pas d'itinéraire sans réseau. Direction \(route.name) à vol d'oiseau.",
                  key: "\(detourId)-start", cooldown: 5)
    }

    func endDetour() {
        detour = nil
        detourUpdate = nil
        detourBack = nil
        wayBack.reset()
        voice.say("Reprise de l'itinéraire.", key: "\(detourId)-end", cooldown: 5)
    }

    /// false = « alertes uniquement »: the route is followed silently (banner kept), cameras, hazards, incidents,
    /// fuel and weather are still spoken.
    @Published private(set) var directionsSpoken: Bool

    func setDirections(_ on: Bool) {
        guard on != directionsSpoken else { return }
        directionsSpoken = on
        voice.say(on ? "Directions vocales activées." : "Alertes uniquement. Radars, dangers et accidents restent annoncés.",
                  key: "mode-\(on)", cooldown: 2)
    }

    /// Camera, hazard or turn from TripCore: urgent ones cut traffic or weather messages.
    private func say(_ a: TurnGuide.Announcement, key: String? = nil, cooldown: TimeInterval = 3_600) {
        if !directionsSpoken, TurnGuide.isDirection(a) { return }     // « alertes uniquement »: alerts only
        voice.say(a.text, key: key ?? a.key, cooldown: cooldown, priority: a.urgent ? .urgent : .normal)
    }

    /// Cameras and hazards of the iPhone's pack ahead in the direction of travel, when the rider is on a road
    /// the day's alerts do not cover (off route without a road back, straight-line detour).
    private func announcePackAhead(_ fix: LocationService.Fix) {
        let heading: Double? = fix.speed >= 2 && fix.course >= 0 ? fix.course : nil
        for a in AlertPackStore.shared.guide?.announcements(position: fix.point, heading: heading) ?? [] {
            say(a, cooldown: 600)
        }
    }

    private func handle(_ fix: LocationService.Fix) {
        // A fix worse than 150 m (indoor, first seconds) would place the rider on the wrong road.
        guard fix.accuracy >= 0, fix.accuracy <= 150 else { return }
        if let last = recordedTimes.last { breaks.update(speed: fix.speed, dt: fix.time.timeIntervalSince(last)) }
        if fix.accuracy <= 50 {
            recorded.append(fix.point)
            recordedTimes.append(fix.time)
            recordedSpeeds.append(fix.speed)
        }
        speedKmh = max(0, fix.speed) * 3.6
        lean.setSpeed(fix.speed)

        if var d = detour {
            let step = detourWayBack.follow(&d, fix: fix, routeKey: detourId)
            detour = d
            detourUpdate = step.update
            detourBack = step.back
            sayStatus(step.status)
            for s in step.spoken { say(s.announcement, key: s.key) }
            // Road detour: its cameras and hazards are announced along it (above). Straight line (offline):
            // the pack's alerts ahead in the direction of travel.
            if !d.route.isRoad { announcePackAhead(fix) }
            return
        }

        guard let snap = computer.snapshot(position: fix.point, lastProgress: lastProgress, now: fix.time, pace: pace) else { return }

        // Learn pace on the segment we are on (local routing speeds until GraphHopper provides real ones).
        if let dt = lastFixTime.map({ fix.time.timeIntervalSince($0) }), fix.speed >= 0,
           let seg = SegmentBuilder.remaining(computer.segments, after: snap.progress).first {
            pace.add(speed: fix.speed, routingSpeed: seg.routingSpeed, roadClass: seg.roadClass, dt: dt)
        }
        lastFixTime = fix.time

        // Wrong turn: the way back to the most logical point of the track (see RejoinAssistant).
        let back = wayBack.update(position: fix.point, speed: max(0, fix.speed), course: fix.course, accuracy: fix.accuracy,
                                  time: fix.time, route: route, lateralOffset: snap.lateralOffset, progress: snap.progress,
                                  lastProgress: lastProgress ?? 0)
        offRoute = back.offRoute
        sayStatus(back.status)
        if offRoute {
            rejoinRoute = back.route
            rejoinUpdate = back.update
            rejoinDistance = back.arrow?.distance
            rejoinBearing = back.arrow?.bearing
            for a in back.announcements { say(a, key: "\(back.keyPrefix)-\(a.key)") }
            // No road back yet (offline, computing): cameras and hazards still announced on the road taken.
            if back.route == nil { announcePackAhead(fix) }
        } else {
            lastProgress = snap.progress
            rejoinRoute = nil
            rejoinUpdate = nil
            rejoinDistance = nil
            rejoinBearing = nil
        }

        if !offRoute, !day.instructions.isEmpty {
            let next = TurnGuide.next(day.instructions, progress: snap.progress)
            nextTurn = next.map { (instruction: $0.instruction, distance: $0.distance) }
            if let a = TurnGuide.announcement(day.instructions, progress: snap.progress, speed: max(0, fix.speed)) { say(a) }
        }

        if !offRoute, !alerts.isEmpty {
            let next = AlertGuide.next(alerts, progress: snap.progress)
            if let n = next, n.distance <= AlertGuide.cameraLead {
                nextAlert = (alert: n.alert, distance: n.distance)
            } else {
                nextAlert = nil
            }
            for a in AlertGuide.announcements(alerts, progress: snap.progress) { say(a) }
        }

        if !offRoute {
            speedLimit = SpeedLimits.limit(day.speedLimits, at: snap.progress)
            // Spoken warning when staying over a known limit for 3 s (at most once a minute per limit).
            if let limit = speedLimit, SpeedLimits.isOver(speedKmh: speedKmh, limit: limit) {
                let since = overLimitSince ?? fix.time
                overLimitSince = since
                if fix.time.timeIntervalSince(since) >= 3 {
                    voice.say("Attention, limitation à \(limit).", key: "speed-\(limit)", cooldown: 60, priority: .urgent)
                }
            } else {
                overLimitSince = nil
            }
            pauseSuggestion = PauseAdvisor.suggestion(pauses, progress: snap.progress,
                                                      ridingSinceBreak: breaks.ridingSinceBreak)
            if let p = pauseSuggestion {
                let when = TurnGuide.lowercasingFirst(TurnGuide.spokenDistance(p.distance))
                voice.say("Tu roules depuis plus d'une heure et demie. Pause possible \(when) : \(p.spot.name).",
                          key: "pause", cooldown: 30 * 60, priority: .info)
            }
            refreshTrafficIfNeeded(progress: snap.progress)
            refreshWeatherIfNeeded(progress: snap.progress)
            weatherAhead = weatherHazards.first { $0.along > snap.progress }
            if let h = weatherAhead {
                let when = TurnGuide.lowercasingFirst(TurnGuide.spokenDistance(h.along - snap.progress))
                voice.say("Météo : \(h.summary) prévu \(when), vers \(WeatherClient.hour(h.eta)).",
                          key: "weather-\(Int(h.along / 1000))", cooldown: 3_600, priority: .info)
            }
            incidentsAhead = located.filter { $0.along > snap.progress }
            // Serious incident close by: urgent (cuts other messages); first warnings and roadworks: info.
            for a in TrafficIncidents.announcements(incidentsAhead, progress: snap.progress) {
                voice.say(a.text, key: a.key, cooldown: 3_600, priority: a.urgent ? .urgent : .info)
            }
        }

        // Validated stops (fuel, restaurant, hotel): 5 km, 500 m, arrival. Said in « alertes uniquement » too.
        if !offRoute {
            for a in StopGuide.announcements(stops, progress: snap.progress) { say(a) }
            nextStop = StopGuide.next(stops, progress: snap.progress).flatMap { $0.distance <= StopGuide.farWarning ? $0 : nil }
        } else {
            nextStop = nil
        }
        // The hotel at the end of the track already says « fin de l'étape ».
        let endsAtHotel = stops.last.map { $0.kind == .lodging && route.length - $0.along < 500 } ?? false
        if snap.endOfDay.distance < 200, !endsAtHotel {
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
}
