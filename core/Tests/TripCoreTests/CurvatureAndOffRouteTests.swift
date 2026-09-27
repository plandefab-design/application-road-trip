import XCTest
@testable import TripCore

final class CurvatureTests: XCTestCase {
    func testStraightLineScoresZero() {
        XCTAssertEqual(Curvature.score(Fixtures.northLine(km: 5)), 0, accuracy: 0.5)
    }

    func testZigzagScoresHigh() {
        let s = Curvature.score(Fixtures.zigzag(km: 3, legM: 30))
        XCTAssertGreaterThan(s, 80)
        XCTAssertLessThanOrEqual(s, 100)
    }

    func testTwistierScoresHigher() {
        let tight = Curvature.degreesPerKm(Fixtures.zigzag(km: 3, legM: 30))
        let loose = Curvature.degreesPerKm(Fixtures.zigzag(km: 3, legM: 300))
        XCTAssertGreaterThan(tight, loose)
    }

    func testDegenerateInput() {
        XCTAssertEqual(Curvature.score(Polyline([])), 0)
        XCTAssertEqual(Curvature.score(Polyline([GeoPoint(lat: 44, lon: 6)])), 0)
    }

    func testSegmentClassification() {
        XCTAssertEqual(SegmentBuilder.classify(curvatureScore: 80), .curvy)
        XCTAssertEqual(SegmentBuilder.classify(curvatureScore: 20), .secondary)
        XCTAssertEqual(SegmentBuilder.classify(curvatureScore: 2), .link)
        let segs = SegmentBuilder.segments(for: Fixtures.northLine(km: 5.5))
        XCTAssertEqual(segs.count, 6)
        XCTAssertEqual(segs.reduce(0) { $0 + $1.distance }, 5_500, accuracy: 1)
        XCTAssertTrue(segs.allSatisfy { $0.roadClass == .link })
    }

    func testRemainingSegments() {
        let segs = [RouteSegment(distance: 1_000, routingSpeed: 10, roadClass: .link),
                    RouteSegment(distance: 1_000, routingSpeed: 10, roadClass: .curvy)]
        let r = SegmentBuilder.remaining(segs, after: 1_500)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].distance, 500, accuracy: 1e-9)
        XCTAssertEqual(r[0].roadClass, .curvy)
    }
}

final class OffRouteTests: XCTestCase {
    func testTriggersAfterThreeSamples() {
        var d = OffRouteDetector()
        XCTAssertEqual(d.update(lateralOffset: 60, time: 0), .onRoute)
        XCTAssertEqual(d.update(lateralOffset: 60, time: 1), .onRoute)
        XCTAssertEqual(d.update(lateralOffset: 60, time: 2), .offRoute)
    }

    func testTriggersAfterDurationWithSparseFixes() {
        var d = OffRouteDetector()
        d.minSamples = 10
        d.update(lateralOffset: 60, time: 0)
        XCTAssertEqual(d.update(lateralOffset: 60, time: 5.1), .offRoute)
    }

    func testSingleOutlierDoesNotTrigger() {
        var d = OffRouteDetector()
        d.update(lateralOffset: 80, time: 0)
        d.update(lateralOffset: 5, time: 1)
        d.update(lateralOffset: 80, time: 2)
        XCTAssertEqual(d.update(lateralOffset: 5, time: 3), .onRoute)
    }

    func testPoorAccuracyIgnored() {
        var d = OffRouteDetector()
        for t in 0..<10 { d.update(lateralOffset: 200, time: Double(t), accuracy: 120) }
        XCTAssertEqual(d.state, .onRoute)
    }

    func testHysteresisOnRecovery() {
        var d = OffRouteDetector()
        for t in 0..<3 { d.update(lateralOffset: 60, time: Double(t)) }
        XCTAssertEqual(d.state, .offRoute)
        XCTAssertEqual(d.update(lateralOffset: 30, time: 3), .offRoute, "30 m is inside the hysteresis band")
        XCTAssertEqual(d.update(lateralOffset: 10, time: 4), .offRoute)
        XCTAssertEqual(d.update(lateralOffset: 10, time: 5), .onRoute)
    }

    func testRejoinTargetIsAheadOfProgress() {
        let line = Fixtures.northLine(km: 10)
        let pos = Fixtures.point(onNorthLineAtKm: 2, eastOffsetM: 300)
        let target = RejoinGuide.target(from: pos, route: line, lastProgress: 4_000)!
        XCTAssertGreaterThanOrEqual(target.distanceAlong, 4_000 - 1)
    }
}
