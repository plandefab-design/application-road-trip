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

    init(guide: FreeRideGuide?, camerasEnabled: Bool, location: LocationService, voice: VoiceService) {
        self.guide = guide
        self.hasPack = guide != nil
        self.camerasEnabled = camerasEnabled
        self.location = location
        self.voice = voice
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
        location.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        finishedRide = RideStore.log(tripId: RideStore.freeRideTripId, tripName: "Balade libre", day: 0,
                                     points: points, times: times, speeds: speeds)
    }

    /// Guided detour to a place picked « autour de moi » (voice turns, arrival); cameras stay announced.
    @Published private(set) var detour: DetourRoute.Guidance?
    @Published private(set) var detourUpdate: DetourRoute.Guidance.Update?
    private var detourId = ""

    func startDetour(_ route: DetourRoute) {
        detourId = String(UUID().uuidString.prefix(6))
        detour = DetourRoute.Guidance(route: route)
        detourUpdate = nil
        voice.say(route.isRoad ? "Itinéraire vers \(route.name)." : "Pas d'itinéraire sans réseau. Direction \(route.name) à vol d'oiseau.",
                  key: "\(detourId)-start", cooldown: 5)
    }

    func endDetour() {
        detour = nil
        detourUpdate = nil
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
            let u = d.update(position: fix.point, speed: max(0, fix.speed), cameras: camerasEnabled)
            detour = d
            detourUpdate = u
            for a in u.announcements { voice.say(a.text, key: "\(detourId)-\(a.key)", cooldown: 3_600) }
        }
        if points.count % 15 == 0 || points.count == 1 {
            trackPreview = points
            nearbyAlerts = (guide?.near(fix.point) ?? [])
                .filter { camerasEnabled || !$0.alert.kind.isCamera }
                .map { MapContent.AlertDot(point: $0.point, isCamera: $0.alert.kind.isCamera) }
        }

        // GPS course is only meaningful when moving.
        let heading: Double? = fix.speed >= 2 && fix.course >= 0 ? fix.course : nil
        guard let guide else { nextAlert = nil; return }
        // On a road detour its own alerts are announced along it; otherwise the ones ahead in the direction of travel.
        if detour?.route.isRoad != true {
            for a in guide.announcements(position: fix.point, heading: heading, cameras: camerasEnabled) {
                voice.say(a.text, key: a.key, cooldown: 600)      // same alert again only after 10 min (way back)
            }
        }
        nextAlert = guide.ahead(of: fix.point, heading: heading)
            .first { camerasEnabled || !$0.alert.kind.isCamera }
            .map { (alert: $0.alert, distance: $0.distance) }
    }
}
