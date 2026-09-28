import CoreLocation
import Foundation
import MapKit
import TripCore

/// « Autour de moi »: nearest fuel stations, hotels, restaurants or cafés, and a road route to the chosen one.
/// Apple Maps search and directions (free, no key) need the network: 5 s timeout (CLAUDE.md rule 1), with an
/// offline fallback on what the trip already contains and a straight-line direction.
enum NearbySearch {
    enum Category: String, CaseIterable, Identifiable {
        case fuel, hotel, restaurant, cafe
        var id: String { rawValue }

        var label: String {
            switch self {
            case .fuel: "Essence"
            case .hotel: "Hôtels"
            case .restaurant: "Restos"
            case .cafe: "Cafés"
            }
        }

        var icon: String {
            switch self {
            case .fuel: "fuelpump.fill"
            case .hotel: "bed.double.fill"
            case .restaurant: "fork.knife"
            case .cafe: "cup.and.saucer.fill"
            }
        }

        fileprivate var poi: MKPointOfInterestCategory {
            switch self {
            case .fuel: .gasStation
            case .hotel: .hotel
            case .restaurant: .restaurant
            case .cafe: .cafe
            }
        }
    }

    struct Place: Identifiable, Equatable {
        let id: String
        let name: String
        let point: GeoPoint
        let address: String?
        let phone: String?
        let distance: Double
        /// true = found offline in the trip data.
        let fromTrip: Bool
    }

    static let timeout: TimeInterval = 5

    /// Online results (Apple Maps), else the trip's own places of that kind; nearest first, at most 15.
    static func search(_ category: Category, around here: GeoPoint, trip: Trip?) async -> (places: [Place], online: Bool) {
        if let online = await withTimeout({ try await appleSearch(category, around: here) }), !online.isEmpty {
            return (online, true)
        }
        return (offline(category, around: here, trip: trip), false)
    }

    private static func appleSearch(_ category: Category, around here: GeoPoint) async throws -> [Place] {
        let request = MKLocalPointsOfInterestRequest(center: CLLocationCoordinate2D(latitude: here.lat, longitude: here.lon),
                                                     radius: 15_000)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category.poi])
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap { item -> Place? in
            let c = item.placemark.coordinate
            let p = GeoPoint(lat: c.latitude, lon: c.longitude)
            let address = [item.placemark.thoroughfare, item.placemark.locality].compactMap { $0 }.joined(separator: ", ")
            return Place(id: "\(item.name ?? "")-\(c.latitude)-\(c.longitude)", name: item.name ?? category.label,
                         point: p, address: address.isEmpty ? nil : address, phone: item.phoneNumber,
                         distance: Geo.distance(here, p), fromTrip: false)
        }
        .sorted { $0.distance < $1.distance }
        .prefix(15).map { $0 }
    }

    /// What the trip already knows, usable without network.
    static func offline(_ category: Category, around here: GeoPoint, trip: Trip?) -> [Place] {
        guard let trip else { return [] }
        var found: [(String, GeoPoint, String?)] = []
        switch category {
        case .fuel:
            found = trip.days.flatMap(\.stations).map { ($0.name, $0.point, nil) }
        case .hotel:
            found = trip.pois.filter { $0.type == .lodging }.compactMap { p in p.point.map { (p.name, $0, p.address) } }
        case .restaurant:
            found = trip.pois.filter { $0.type == .meal }.compactMap { p in p.point.map { (p.name, $0, p.address) } }
        case .cafe:
            found = trip.days.flatMap(\.pauses).filter { $0.kind == .cafe }.compactMap { p in p.point.map { (p.name, $0, nil) } }
        }
        var seen = Set<String>()
        return found.compactMap { name, point, address in
            let key = "\(name)-\(Int(point.lat * 1e4))-\(Int(point.lon * 1e4))"
            guard seen.insert(key).inserted else { return nil }
            return Place(id: key, name: name, point: point, address: address, phone: nil,
                         distance: Geo.distance(here, point), fromTrip: true)
        }
        .sorted { $0.distance < $1.distance }
        .prefix(15).map { $0 }
    }

    /// Road route from here (Apple Maps directions), else a straight line (offline).
    static func route(to place: Place, from here: GeoPoint) async -> DetourRoute {
        let road = await withTimeout { () -> DetourRoute in
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: here.lat, longitude: here.lon)))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: place.point.lat, longitude: place.point.lon)))
            request.transportType = .automobile
            let response = try await MKDirections(request: request).calculate()
            guard let r = response.routes.first else { throw URLError(.cannotFindHost) }
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: r.polyline.pointCount)
            r.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: r.polyline.pointCount))
            return DetourRoute.road(name: place.name, destination: place.point,
                                    points: coords.map { GeoPoint(lat: $0.latitude, lon: $0.longitude) },
                                    steps: r.steps.map { (text: $0.instructions, distance: $0.distance) })
        }
        return road ?? DetourRoute.straight(name: place.name, from: here, to: place.point)
    }

    /// Runs `work`, giving up after `timeout` seconds or on error (nil).
    private static func withTimeout<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
