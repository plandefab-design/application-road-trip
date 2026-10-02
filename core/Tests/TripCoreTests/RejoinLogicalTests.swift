import XCTest
@testable import TripCore

final class RejoinLogicalTests: XCTestCase {
    // Synthetic road going north then turning east: (43.0,5.0) → (43.05,5.0) → (43.05,5.1).
    let route = Polyline((0...50).map { GeoPoint(lat: 43.0 + Double($0) * 0.001, lon: 5.0) }
                         + (1...80).map { GeoPoint(lat: 43.05, lon: 5.0 + Double($0) * 0.00125) })

    func testNeverBehindTheLastProgress() {
        // Rider 1 km west of the road at km 2, last progress km 3: the target stays at or after km 3.
        let pos = GeoPoint(lat: 43.018, lon: 4.988)
        let t = RejoinGuide.logicalTarget(from: pos, heading: 0, route: route, lastProgress: 3_000)!
        XCTAssertGreaterThanOrEqual(t.along, 3_000)
    }

    func testCutsTheCornerWhenMuchShorter() {
        // Rider inside the bend (north-east of km 3), heading north-east: rejoining after the corner beats
        // going back west to the vertical leg, although it skips some track.
        let pos = GeoPoint(lat: 43.047, lon: 5.03)
        let t = RejoinGuide.logicalTarget(from: pos, heading: 45, route: route, lastProgress: 3_000)!
        XCTAssertGreaterThan(t.along, 5_560)                  // on the eastward leg, after the corner
        XCTAssertLessThan(Geo.distance(pos, t.point), 600)
    }

    func testAvoidsAUTurn() {
        // Rider east of the vertical leg, heading north: a point slightly ahead wins over the nearest one behind.
        let pos = GeoPoint(lat: 43.02, lon: 5.004)
        let withHeading = RejoinGuide.logicalTarget(from: pos, heading: 0, route: route, lastProgress: 1_000)!
        XCTAssertGreaterThanOrEqual(withHeading.point.lat, 43.02 - 0.0005)   // at most ~50 m back (200 m sampling)
    }

    func testEmptyRoute() {
        XCTAssertNil(RejoinGuide.logicalTarget(from: GeoPoint(lat: 43, lon: 5), heading: nil, route: Polyline([]), lastProgress: 0))
    }
}

/// Faster detection after a missed turn, and the way back chosen on real travel times. Synthetic geometry only.
final class RejoinPlanningTests: XCTestCase {
    func testMissedTurnDetectedInTwoFixes() {
        var d = OffRouteDetector()
        XCTAssertEqual(d.update(lateralOffset: 28, time: 0, headingDelta: 85), .onRoute)
        XCTAssertEqual(d.update(lateralOffset: 32, time: 1, headingDelta: 80), .offRoute)
    }

    func testDriftAlongTheRouteIsNotAMissedTurn() {
        var d = OffRouteDetector()
        for t in 0..<6 { XCTAssertEqual(d.update(lateralOffset: 30, time: Double(t), headingDelta: 8), .onRoute) }
        var noisy = OffRouteDetector()
        XCTAssertEqual(noisy.update(lateralOffset: 30, time: 0, headingDelta: 90), .onRoute)
        XCTAssertEqual(noisy.update(lateralOffset: 30, time: 1, headingDelta: 10), .onRoute)    // one odd course only
        XCTAssertEqual(noisy.update(lateralOffset: 30, time: 2, headingDelta: 90), .onRoute)
    }

    func testCandidatesBackNearAndFar() {
        let route = Fixtures.northLine(km: 30, stepM: 100)
        let pos = Fixtures.point(onNorthLineAtKm: 5.3, eastOffsetM: 400)        // turned right at km 5
        let c = RejoinGuide.candidates(from: pos, heading: 90, route: route, lastProgress: 5_000)
        XCTAssertEqual(c.first?.along ?? 0, 5_050, accuracy: 1)                    // where the rider left the route
        XCTAssertEqual(c.count, 3)
        XCTAssertTrue(c.allSatisfy { $0.along >= 5_000 })
        for (a, b) in zip(c, c.dropFirst()) { XCTAssertGreaterThanOrEqual(b.along - a.along, 500) }
        XCTAssertTrue(RejoinGuide.candidates(from: pos, heading: nil, route: Polyline([]), lastProgress: 0).isEmpty)
    }

    func testNearTheEndOnlyDistinctPlaces() {
        let route = Fixtures.northLine(km: 6, stepM: 100)
        let c = RejoinGuide.candidates(from: Fixtures.point(onNorthLineAtKm: 5.5, eastOffsetM: 300), heading: nil,
                                       route: route, lastProgress: 5_400)
        XCTAssertEqual(c.map { $0.along.rounded() }, [5_450, 6_000], "back where the route was left, or straight to its end")
    }

    func testBestIsTheLeastTotalTime() {
        // U-turn back to the missed turn (2 min) beats a long way round to a point further on.
        XCTAssertEqual(RejoinGuide.best([(along: 3_050, seconds: 120), (along: 5_000, seconds: 400), (along: 12_000, seconds: 900)]), 0)
        // A road that joins far ahead quickly wins when going back is slow.
        XCTAssertEqual(RejoinGuide.best([(along: 3_050, seconds: 600), (along: 5_000, seconds: 400), (along: 12_000, seconds: 500)]), 2)
        XCTAssertNil(RejoinGuide.best([]))
    }

    func testDetourProgressWaitsWhileOffTheRoute() {
        let line = Fixtures.northLine(km: 5, stepM: 100)
        let route = DetourRoute(name: "B", destination: line.points.last!, track: line,
                                instructions: [TurnInstruction(along: 3_000, maneuver: .turnRight, text: "")], isRoad: true)
        var g = DetourRoute.Guidance(route: route)
        _ = g.update(position: Fixtures.point(onNorthLineAtKm: 1), speed: 20)
        let off = g.update(position: Fixtures.point(onNorthLineAtKm: 2.9, eastOffsetM: 200), speed: 20)
        XCTAssertEqual(g.progress, 1_000, accuracy: 20, "a parallel road does not move the rider along the route")
        XCTAssertEqual(off.lateralOffset ?? 0, 200, accuracy: 10)
        XCTAssertFalse(off.announcements.contains { $0.key.contains("turn") })
    }
}

/// Roundabouts in Apple Maps' written steps (way back, free ride without the PC): exit number for the banner.
final class WrittenRoundaboutTests: XCTestCase {
    func testExitNumberFromText() {
        XCTAssertEqual(DetourRoute.exitNumber(in: "Au rond-point, prenez la 3e sortie vers D 943"), 3)
        XCTAssertEqual(DetourRoute.exitNumber(in: "Au rond-point, prenez la 1re sortie"), 1)
        XCTAssertEqual(DetourRoute.exitNumber(in: "Au rond-point, prenez la deuxième sortie"), 2)
        XCTAssertEqual(DetourRoute.exitNumber(in: "At the roundabout, take the 2nd exit"), 2)
        XCTAssertNil(DetourRoute.exitNumber(in: "Au rond-point, continuez tout droit"))
    }

    func testAppleRoundaboutKeepsItsTextAndGetsTheNumber() {
        let points = (0...30).map { GeoPoint(lat: 43.0 + Double($0) * 0.001, lon: 5.0) }
        let route = DetourRoute.road(name: "B", destination: points.last!, points: points,
                                     steps: [(text: "", distance: 500), (text: "Au rond-point, prenez la 3e sortie vers D 943", distance: 2_000),
                                             (text: "Arrivée", distance: 0)])
        let ins = route.instructions.first { $0.maneuver == .roundabout }
        XCTAssertEqual(ins?.exit, 3)
        XCTAssertEqual(ins.map { TurnGuide.phrase($0, withRoad: true) }, "au rond-point, prenez la troisième sortie vers D 943")
    }
}
