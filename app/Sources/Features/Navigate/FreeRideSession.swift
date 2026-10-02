import Combine
import Foundation
import TripCore
import UIKit

/// Riding without an itinerary: spoken warnings for cameras and hazards ahead (offline pack), distance and time,
/// recorded track for the ride summary and the maintenance odometer. No network, no PC.
@MainActor
final class FreeRideSession: ObservableObject {
    @Published private(set) var speedKmh: Double = 0
    @Published private(set) var distance: Double = 0          // metres ridden
    @Published private(set) var startedAt = Date()
    @Published private(set) var nextAlert: (alert: RoadAlert, distance: Double)?
    @Published private(set) var trackPreview: [GeoPoint] = [] // refreshed every 15 fixes (map)
    /// Cameras and hazards within 3 km, for the map (refreshed with the track preview).
    @Published private(set) var nearbyAlerts: [MapContent.AlertDot] = []
    let hasPack: Bool

    private var points: [GeoPoint] = []
    private var times: [Date] = []
    private var speeds: [Double] = []
    private(set) var finishedRide: RideLog?

    private let guide: FreeRideGuide?
    private let camerasEnabled: Bool
    private let location: LocationService
    private let voice: VoiceService
    private var cancellable: AnyCancellable?

    /// Live incidents around (TomTom + official feeds via the PC), optional: refreshed every 5 min when online.
    private let traffic: TrafficClient?
    /// Nearest live incident ahead within 1 km, as spoken (« Accident dans 600 mètres »), for the badge.
    @Published private(set) var incidentAhead: String?
    private var incidents: [TrafficIncident] = []
    private var lastTrafficFetch: Date?
    private var trafficTask: Task<Void, Never>?

    /// false = « alertes uniquement » on a route to a place: directions silent, alerts still spoken.
    @Published private(set) var directionsSpoken: Bool

    func setDirections(_ on: Bool) {
        guard on != directionsSpoken else { return }
        directionsSpoken = on
        voice.say(on ? "Directions vocales activées." : "Alertes uniquement. Radars, dangers et accidents restent annoncés.",
                  key: "mode-\(on)", cooldown: 2)
    }

    init(guide: FreeRideGuide?, camerasEnabled: Bool, traffic: TrafficClient?, directions: Bool = true,
         location: LocationService, voice: VoiceService) {
        self.directionsSpoken = directions
        self.guide = guide
        self.hasPack = guide != nil
        self.camerasEnabled = camerasEnabled
        self.traffic = traffic
        self.location = location
        self.voice = voice
    }

    /// Incidents in a ~40 km square around the rider (one request per source), every 5 min. Never waited for.
    private func refreshTrafficIfNeeded(around p: GeoPoint) {
        guard let traffic, trafficTask == nil else { return }
        if let last = lastTrafficFetch, Date().timeIntervalSince(last) < 300 { return }
        lastTrafficFetch = Date()
        let dLat = 0.18, dLon = 0.18 / max(0.2, cos(p.lat * .pi / 180))
        trafficTask = Task { [weak self] in
            let found = try? await traffic.incidents(minLon: p.lon - dLon, minLat: p.lat - dLat, maxLon: p.lon + dLon, maxLat: p.lat + dLat)
            guard let self else { return }
            if let found { self.incidents = found }             // offline: the last list stays
            self.trafficTask = nil
        }
    }

    func start() {
        startedAt = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        location.startNavigation()
        cancellable = location.$lastFix.compactMap { $0 }.sink { [weak self] fix in self?.handle(fix) }
        voice.say(hasPack ? "Balade libre. Radars et dangers actifs." : "Balade libre. Base radars absente : synchronise avec le PC.",
                  key: "free-start")
    }

    func stop() {
        cancellable = nil
        trafficTask?.cancel()
        location.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        finishedRide = RideStore.log(tripId: RideStore.freeRideTripId, tripName: "Balade libre", day: 0,
                                     points: points, times: times, speeds: speeds)
    }

    /// Guided detour to a place picked « autour de moi » (voice turns, arrival); cameras stay announced.
    @Published private(set) var detour: DetourRoute.Guidance?
    @Published private(set) var detourUpdate: DetourRoute.Guidance.Update?
    private var detourId = ""
    /// Off the route after a wrong turn: the way back to it (nil while on it).
    @Published private(set) var detourBack: RejoinAssistant.Output?
    private let wayBack = RejoinAssistant()

    func startDetour(_ route: DetourRoute) {
        detourId = String(UUID().uuidString.prefix(6))
        detour = DetourRoute.Guidance(route: route)
        detourUpdate = nil
        detourBack = nil
        wayBack.reset()
        let via = route.stops.isEmpty ? "" : ", \(route.stops.count) étape\(route.stops.count > 1 ? "s" : "")"
        voice.say(route.isRoad ? "Itinéraire vers \(route.name)\(via), \(TurnGuide.spokenLength(route.track.length))."
                               : "Pas d'itinéraire sans réseau. Direction \(route.name) à vol d'oiseau.",
                  key: "\(detourId)-start", cooldown: 5)
    }

    func endDetour() {
        detour = nil
        detourUpdate = nil
        detourBack = nil
        wayBack.reset()
    }

    private func handle(_ fix: LocationService.Fix) {
        guard fix.accuracy >= 0, fix.accuracy <= 150 else { return }
        speedKmh = max(0, fix.speed) * 3.6
        // Only precise fixes are recorded (km, track): imprecise ones would inflate the distance.
        if fix.accuracy <= 50 {
            if let last = points.last { distance += Geo.distance(last, fix.point) }
            points.append(fix.point)
            times.append(fix.time)
            speeds.append(fix.speed)
        }
        if var d = detour {
            // On the route: its turns, stops and alerts. After a wrong turn: the way back to it (see RejoinAssistant).
            let step = wayBack.follow(&d, fix: fix, routeKey: detourId, cameras: camerasEnabled)
            detour = d
            detourUpdate = step.update
            detourBack = step.back
            if let status = step.status, directionsSpoken { voice.say(status, key: "status-\(status)", cooldown: 20) }
            for s in step.spoken where directionsSpoken || !TurnGuide.isDirection(s.announcement) {
                voice.say(s.announcement.text, key: s.key, cooldown: 3_600, priority: s.announcement.urgent ? .urgent : .normal)
            }
        }
        if points.count % 15 == 0 || points.count == 1 {
            trackPreview = points
            nearbyAlerts = (guide?.near(fix.point) ?? [])
                .filter { camerasEnabled || !$0.alert.kind.isCamera }
                .map { MapContent.AlertDot(point: $0.point, isCamera: $0.alert.kind.isCamera) }
        }

        // GPS course is only meaningful when moving.
        let heading: Double? = fix.speed >= 2 && fix.course >= 0 ? fix.course : nil
        refreshTrafficIfNeeded(around: fix.point)
        let incidentWarnings = TrafficIncidents.announcementsAhead(incidents, position: fix.point, heading: heading)
        for a in incidentWarnings {
            voice.say(a.text, key: a.key, cooldown: 1_800, priority: a.urgent ? .urgent : .info)
        }
        incidentAhead = incidentWarnings.first?.text
        guard let guide else { nextAlert = nil; return }
        // On a road route its own alerts are announced along it (and along the way back to it); otherwise, or off it
        // before the way back is known, the ones ahead in the direction of travel.
        if detour?.route.isRoad != true || (detourBack != nil && detourBack?.route == nil) {
            for a in guide.announcements(position: fix.point, heading: heading, cameras: camerasEnabled) {
                voice.say(a.text, key: a.key, cooldown: 600, priority: .urgent)   // again only after 10 min (way back)
            }
        }
        nextAlert = guide.ahead(of: fix.point, heading: heading)
            .first { camerasEnabled || !$0.alert.kind.isCamera }
            .map { (alert: $0.alert, distance: $0.distance) }
    }
}
