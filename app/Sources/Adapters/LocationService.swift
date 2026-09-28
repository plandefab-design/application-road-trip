import CoreLocation
import Foundation
import TripCore

/// GPS adapter: converts CoreLocation fixes into TripCore types.
/// High-accuracy + background updates only while navigating (battery, SPEC §9).
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Fix: Equatable {
        let point: GeoPoint
        let speed: Double          // m/s, -1 if unknown
        let course: Double         // degrees, -1 if unknown
        let accuracy: Double       // metres
        let time: Date
    }

    @Published private(set) var lastFix: Fix?
    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager: CLLocationManager

    override init() {
        let m = CLLocationManager()
        manager = m
        authorization = m.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Ask permissions BEFORE starting to ride (never during navigation — CLAUDE.md rule 9).
    func requestPermissions() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    private var navigating = false

    /// Keeps the GPS warm while the app is open (low accuracy, little battery), so riding starts with a position.
    func warmUp() {
        guard !navigating,
              manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.startUpdatingLocation()
    }

    func startNavigation() {
        navigating = true
        // Start from the last known position right away (recent enough), the precise fixes follow.
        if lastFix == nil, let loc = manager.location, Date().timeIntervalSince(loc.timestamp) < 120 {
            lastFix = Fix(point: GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude),
                          speed: -1, course: -1, accuracy: loc.horizontalAccuracy, time: loc.timestamp)
        }
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    /// Where the rider is now: the last fix if recent, else one fresh fix (≤ 10 s), else the last known one.
    func currentPosition(maxAge: TimeInterval = 60) async -> GeoPoint? {
        if let f = lastFix, Date().timeIntervalSince(f.time) < maxAge { return f.point }
        let before = lastFix?.time
        manager.requestLocation()
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(200))
            if let f = lastFix, f.time != before { return f.point }
        }
        return lastFix?.point ?? manager.location.map { GeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
    }

    func stop() {
        navigating = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        let fix = Fix(point: GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                                      ele: loc.verticalAccuracy >= 0 ? loc.altitude : nil),
                      speed: loc.speed, course: loc.course, accuracy: loc.horizontalAccuracy, time: loc.timestamp)
        Task { @MainActor in self.lastFix = fix }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient GPS errors are ignored; navigation keeps the last known state.
    }
}
