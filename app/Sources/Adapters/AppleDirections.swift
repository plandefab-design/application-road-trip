import MapKit
import TripCore

/// Apple Maps directions (free, no key), as plain values, never waited for longer than asked.
enum AppleDirections {
    struct Leg: Sendable {
        let points: [GeoPoint]
        let steps: [Step]
        let seconds: Double
    }

    struct Step: Sendable {
        let text: String
        let distance: Double
    }

    /// One road leg; nil when Apple has no answer within `timeout` seconds (offline, poor network).
    static func leg(from a: GeoPoint, to b: GeoPoint, avoidMotorways: Bool = false, timeout: TimeInterval) async -> Leg? {
        await Deadline.run(timeout) { try await request(from: a, to: b, avoidMotorways: avoidMotorways) } ?? nil
    }

    /// Several destinations asked at once (one request each); each answer arrived within `timeout` seconds, in order.
    static func legs(from a: GeoPoint, to targets: [GeoPoint], timeout: TimeInterval) async -> [Leg?] {
        await withTaskGroup(of: (Int, Leg?).self) { group in
            for (i, target) in targets.enumerated() {
                group.addTask { (i, await leg(from: a, to: target, timeout: timeout)) }
            }
            var out = [Leg?](repeating: nil, count: targets.count)
            for await (i, leg) in group { out[i] = leg }
            return out
        }
    }

    /// The route as a guidance route (turn by turn from Apple's written steps).
    static func route(_ leg: Leg, name: String, destination: GeoPoint) -> DetourRoute {
        DetourRoute.road(name: name, destination: destination, points: leg.points,
                         steps: leg.steps.map { (text: $0.text, distance: $0.distance) })
    }

    private static func request(from a: GeoPoint, to b: GeoPoint, avoidMotorways: Bool) async throws -> Leg? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)))
        request.transportType = .automobile
        request.highwayPreference = avoidMotorways ? .avoid : .any
        guard let r = try await MKDirections(request: request).calculate().routes.first else { return nil }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: r.polyline.pointCount)
        r.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: r.polyline.pointCount))
        return Leg(points: coords.map { GeoPoint(lat: $0.latitude, lon: $0.longitude) },
                   steps: r.steps.map { Step(text: $0.instructions, distance: $0.distance) },
                   seconds: r.expectedTravelTime)
    }
}
