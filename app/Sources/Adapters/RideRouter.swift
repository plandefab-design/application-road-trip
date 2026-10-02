import Foundation
import MapKit
import TripCore

/// Route choice of the free ride, like a road GPS.
enum RideMode: String, CaseIterable, Identifiable {
    case curvy, nomotorway, fast
    var id: String { rawValue }

    var label: String {
        switch self {
        case .curvy: "Route sinueuse"
        case .nomotorway: "Sans autoroute"
        case .fast: "Le plus rapide"
        }
    }

    var hint: String {
        switch self {
        case .curvy: "Virages et petites routes : ni autoroute, ni nationale rectiligne"
        case .nomotorway: "Le plus rapide sans autoroute"
        case .fast: "Autoroutes autorisées"
        }
    }

    var icon: String {
        switch self {
        case .curvy: "point.topleft.down.to.point.bottomright.curvepath"
        case .nomotorway: "road.lanes"
        case .fast: "bolt.fill"
        }
    }
}

/// Road route through the rider's stops: the PC's moto routing (GraphHopper, true curvy profile) when it answers,
/// else Apple Maps leg by leg (motorways avoided unless « le plus rapide »), else a straight line (offline).
enum RideRouter {
    struct Result {
        let route: DetourRoute
        /// Expected riding time, minutes (nil: straight line, offline).
        let minutes: Double?
        /// What was used when it is not the PC's moto routing, in the rider's words.
        let note: String?
    }

    @MainActor
    static func route(from here: GeoPoint, through stops: [FavoritePlaces.Place], mode: RideMode, settings: AppSettings) async -> Result {
        guard let last = stops.last else {
            return Result(route: .straight(name: "Destination", from: here, to: here), minutes: nil, note: nil)
        }
        let points = [here] + stops.map(\.point)
        if let pc = CompanionClient(urlString: settings.companionURL, token: settings.companionToken),
           let r = try? await pc.rideRoute(points: points, mode: mode.rawValue), r.track.count > 1 {
            var route = DetourRoute(name: last.name, destination: last.point, track: Polyline(r.track),
                                    instructions: r.instructions, isRoad: true)
            route.stops = zip(stops.dropLast(), r.via).map { RouteStop(kind: .waypoint, name: $0.name, along: $1) }
            return Result(route: NearbySearch.withAlerts(route), minutes: r.timeMin, note: nil)
        }
        if let viaApple = await apple(points: points, names: stops.map(\.name), avoidMotorways: mode != .fast) {
            let note = mode == .curvy ? "PC injoignable : itinéraire Apple Plans sans autoroute, pas le profil sinueux."
                                      : "PC injoignable : itinéraire Apple Plans."
            return Result(route: NearbySearch.withAlerts(viaApple.route), minutes: viaApple.minutes, note: note)
        }
        return Result(route: .straight(name: last.name, from: here, to: last.point), minutes: nil,
                      note: "Pas de réseau : direction de \(last.name) à vol d'oiseau.")
    }

    /// One Apple Maps leg, as plain values.
    private struct Leg: Sendable {
        let points: [GeoPoint]
        let steps: [Step]
        let seconds: Double
    }

    private struct Step: Sendable {
        let text: String
        let distance: Double
    }

    /// Apple Maps leg by leg (MKDirections has no waypoints), legs joined into one route; nil if a leg fails.
    private static func apple(points: [GeoPoint], names: [String], avoidMotorways: Bool) async -> (route: DetourRoute, minutes: Double)? {
        var track: [GeoPoint] = []
        var steps: [(text: String, distance: Double)] = []
        var stops: [RouteStop] = []
        var seconds = 0.0
        let legs = Array(zip(points, points.dropFirst()))
        for (i, (a, b)) in legs.enumerated() {
            guard let leg = await withTimeout({ try await appleLeg(from: a, to: b, avoidMotorways: avoidMotorways) }) else { return nil }
            track += leg.points
            // Each leg ends with « arrivée à destination »: on an intermediate leg that arrival is the stop itself,
            // announced by StopGuide (« Étape atteinte »), so its text is dropped (its length is kept).
            var legSteps = leg.steps.map { (text: $0.text, distance: $0.distance) }
            if i < legs.count - 1, !legSteps.isEmpty { legSteps[legSteps.count - 1].text = "" }
            steps += legSteps
            seconds += leg.seconds
            // Position on the joined track itself (what the guidance measures).
            if i < legs.count - 1 { stops.append(RouteStop(kind: .waypoint, name: names[i], along: Polyline(track).length)) }
        }
        guard let end = points.last else { return nil }
        var route = DetourRoute.road(name: names.last ?? "Destination", destination: end, points: track, steps: steps)
        route.stops = stops
        return (route: route, minutes: seconds / 60)
    }

    private static func appleLeg(from a: GeoPoint, to b: GeoPoint, avoidMotorways: Bool) async throws -> Leg {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)))
        request.transportType = .automobile
        request.highwayPreference = avoidMotorways ? .avoid : .any
        guard let r = try await MKDirections(request: request).calculate().routes.first else { throw URLError(.cannotFindHost) }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: r.polyline.pointCount)
        r.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: r.polyline.pointCount))
        return Leg(points: coords.map { GeoPoint(lat: $0.latitude, lon: $0.longitude) },
                   steps: r.steps.map { Step(text: $0.instructions, distance: $0.distance) },
                   seconds: r.expectedTravelTime)
    }

    /// 8 s per leg at most (riding: never waited for longer).
    private static func withTimeout<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await work() }
            group.addTask { try? await Task.sleep(for: .seconds(8)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
