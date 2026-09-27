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

    func startNavigation() {
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

    func stop() {
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
