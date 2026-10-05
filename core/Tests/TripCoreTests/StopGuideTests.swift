import XCTest
@testable import TripCore

/// Synthetic places only.
final class StopGuideTests: XCTestCase {
    func at(_ km: Double, east: Double = 0) -> GeoPoint { Fixtures.point(onNorthLineAtKm: km, eastOffsetM: east) }

    func trip() -> Trip {
        let meal = POI(id: "m", type: .meal, name: "Le Cours", point: at(80, east: 300))
        let other = POI(id: "x", type: .meal, name: "Pas choisi", point: at(60))
        let hotel = POI(id: "h", type: .lodging, name: "Les Alizés", point: at(150))
        let day = TripDay(index: 1, track: Fixtures.northLine(km: 150, stepM: 500),
                          fuelStops: [FuelStopRef(name: "Station test", point: at(50, east: 800), kmFromStart: 50)],
                          meals: [POIChoice(poiId: "m", selected: true), POIChoice(poiId: "x")],
                          lodging: [POIChoice(poiId: "h", selected: true)])
        return Trip(name: "T", params: TripParams(start: Place(name: "A"), dateStart: "2027-06-01", dateEnd: "2027-06-01"),
                    days: [day], pois: [meal, other, hotel])
    }

    func testValidatedStopsInRouteOrder() {
        let stops = StopGuide.stops(for: trip().days[0], in: trip())
        XCTAssertEqual(stops.map(\.kind), [.fuel, .meal, .lodging])         // the restaurant not chosen is not a stop
        XCTAssertEqual(stops.map(\.name), ["Station test", "Le Cours", "Les Alizés"])
        XCTAssertEqual(stops[1].along, 80_000, accuracy: 30)
    }

    func testAnnouncedAt5kmThen500mThenOnArrival() {
        let stops = StopGuide.stops(for: trip().days[0], in: trip())
        XCTAssertEqual(StopGuide.announcements(stops, progress: 45_500),
                       [.init(key: "stop-0-far", text: "Ravitaillement dans 4,5 kilomètres : Station test.")])
        XCTAssertEqual(StopGuide.announcements(stops, progress: 79_600).first?.text, "Restaurant Le Cours dans 400 mètres.")
        XCTAssertEqual(StopGuide.announcements(stops, progress: 80_000).first?.text, "Vous êtes arrivé : restaurant Le Cours. Bon appétit !")
        XCTAssertEqual(StopGuide.announcements(stops, progress: 146_000).first?.text, "Hôtel Les Alizés dans 4 kilomètres, fin de l'étape.")
        XCTAssertTrue(StopGuide.announcements(stops, progress: 20_000).isEmpty)
        XCTAssertEqual(StopGuide.next(stops, progress: 60_000)?.stop.name, "Le Cours")
    }

    func testWaypointsOfAFreeRideRoute() {
        let points = (0...40).map { GeoPoint(lat: 43.0 + Double($0) * 0.001, lon: 5.0) }   // ≈ 4.4 km north
        var route = DetourRoute(name: "Arrivée", destination: points.last!, track: Polyline(points), instructions: [], isRoad: true)
        route.stops = [RouteStop(kind: .waypoint, name: "Village test", along: 2_000)]
        var g = DetourRoute.Guidance(route: route)
        let u = g.update(position: GeoPoint(lat: 43.0 + 2_000 / 111_195.0, lon: 5.0), speed: 10)
        XCTAssertTrue(u.announcements.contains { $0.text == "Étape atteinte : Village test." })
        XCTAssertFalse(TurnGuide.isDirection(u.announcements.first { $0.text.hasPrefix("Étape") }!))   // said in alerts mode too
    }

    func testSkipDropsTheNextStopAndResumesBeyondIt() throws {
        let stops = StopGuide.stops(for: trip().days[0], in: trip())
        let s = try XCTUnwrap(StopGuide.skip(stops, progress: 10_000))
        XCTAssertEqual(s.skipped.name, "Station test")
        XCTAssertEqual(s.remaining.map(\.name), ["Le Cours", "Les Alizés"])
        XCTAssertGreaterThan(s.resumeAt, s.skipped.along + StopGuide.arrivedWithin)
        XCTAssertLessThan(s.resumeAt, s.remaining[0].along)
        // Skipping again goes to the following stop; nothing is left after the last one.
        let t = try XCTUnwrap(StopGuide.skip(s.remaining, progress: 10_000))
        XCTAssertEqual(t.skipped.name, "Le Cours")
        let u = try XCTUnwrap(StopGuide.skip(t.remaining, progress: 10_000))
        XCTAssertTrue(u.remaining.isEmpty)
        XCTAssertNil(StopGuide.skip(u.remaining, progress: 10_000))
    }

    func testSkipIgnoresStopsAlreadyPassed() throws {
        let stops = StopGuide.stops(for: trip().days[0], in: trip())
        XCTAssertEqual(StopGuide.skip(stops, progress: 60_000)?.skipped.name, "Le Cours")
    }
}
