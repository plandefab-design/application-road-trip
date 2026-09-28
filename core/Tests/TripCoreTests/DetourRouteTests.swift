import XCTest
@testable import TripCore

final class DetourRouteTests: XCTestCase {
    func testManeuverFromText() {
        XCTAssertEqual(DetourRoute.maneuver(from: "Tournez à gauche sur D943"), .turnLeft)
        XCTAssertEqual(DetourRoute.maneuver(from: "Tournez à droite"), .turnRight)
        XCTAssertEqual(DetourRoute.maneuver(from: "Serrez à gauche"), .slightLeft)
        XCTAssertEqual(DetourRoute.maneuver(from: "Au rond-point, prenez la 2e sortie"), .roundabout)
        XCTAssertEqual(DetourRoute.maneuver(from: "Faites demi-tour"), .uTurn)
        XCTAssertEqual(DetourRoute.maneuver(from: "Turn sharp right onto Main St"), .sharpRight)
        XCTAssertEqual(DetourRoute.maneuver(from: "Continuez tout droit"), .straight)
    }

    func testRoadRoutePositionsManeuversAtTheEndOfPreviousSteps() {
        let points = (0...20).map { GeoPoint(lat: 43.0 + Double($0) * 0.001, lon: 5.0) }
        let route = DetourRoute.road(name: "Station", destination: points.last!, points: points, steps: [
            (text: "", distance: 0),
            (text: "Tournez à droite sur D1", distance: 800),
            (text: "Tournez à gauche", distance: 1_200),
            (text: "Vous êtes arrivé", distance: 0),
        ])
        XCTAssertEqual(route.instructions.map(\.maneuver), [.turnRight, .turnLeft, .arrive])
        XCTAssertEqual(route.instructions.map(\.along), [0, 800, 2_000])
        XCTAssertTrue(route.isRoad)
        // The first real turn is announced like any trip instruction.
        XCTAssertEqual(TurnGuide.next(route.instructions, progress: 500)?.instruction.text, "Tournez à gauche")
    }

    func testGuidanceAlongARoadRouteThenArrival() {
        let points = (0...30).map { GeoPoint(lat: 43.0 + Double($0) * 0.001, lon: 5.0) }   // ≈ 3.3 km north
        var g = DetourRoute.Guidance(route: .road(name: "Station", destination: points.last!, points: points, steps: [
            (text: "", distance: 2_000), (text: "Tournez à gauche", distance: 1_336), (text: "Arrivée", distance: 0),
        ]))
        let start = g.update(position: points[0], speed: 10)
        XCTAssertEqual(start.remaining, 3_336, accuracy: 10)
        XCTAssertNil(start.bearing)
        let before = g.update(position: GeoPoint(lat: 43.0 + 1_750 / 111_195.0, lon: 5.0), speed: 10)   // 250 m before the turn
        XCTAssertEqual(before.announcements.first?.key, "detour-turn-0-soon")
        let end = g.update(position: points.last!, speed: 5)
        XCTAssertEqual(end.announcements.last?.text, "Vous êtes arrivé : Station.")
        XCTAssertTrue(g.arrived)
        XCTAssertTrue(g.update(position: points.last!, speed: 0).announcements.isEmpty)   // said once
    }

    func testGuidanceStraightLineGivesDirection() {
        var g = DetourRoute.Guidance(route: .straight(name: "Hôtel", from: GeoPoint(lat: 43, lon: 5), to: GeoPoint(lat: 43.01, lon: 5)))
        let u = g.update(position: GeoPoint(lat: 43, lon: 5), speed: 10)
        XCTAssertEqual(u.bearing ?? -1, 0, accuracy: 0.5)            // due north
        XCTAssertEqual(u.remaining, 1_112, accuracy: 5)
    }

    func testStraightFallback() {
        let r = DetourRoute.straight(name: "Hôtel", from: GeoPoint(lat: 43, lon: 5), to: GeoPoint(lat: 43.01, lon: 5))
        XCTAssertFalse(r.isRoad)
        XCTAssertEqual(r.track.length, 1_112, accuracy: 5)
        XCTAssertTrue(r.instructions.isEmpty)
    }
}
