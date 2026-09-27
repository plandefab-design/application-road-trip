import XCTest
@testable import TripCore

final class PaceEstimatorTests: XCTestCase {
    func testDefaultCoefficientIsOne() {
        let p = PaceEstimator()
        for c in RoadClass.allCases { XCTAssertEqual(p.coefficient(c), 1.0) }
        let t = p.drivingTime([RouteSegment(distance: 36_000, routingSpeed: 10, roadClass: .curvy)])
        XCTAssertEqual(t, 3_600, accuracy: 1e-6)
    }

    func testConvergesTowardActualRatio() {
        var p = PaceEstimator()
        // Rider goes at 70 % of routing speed on curvy roads for 30 minutes, 1 Hz.
        for _ in 0..<1_800 { p.add(speed: 7, routingSpeed: 10, roadClass: .curvy, dt: 1) }
        XCTAssertEqual(p.coefficient(.curvy), 0.7, accuracy: 0.01)
        XCTAssertEqual(p.coefficient(.link), 1.0, "Other classes must not move")
    }

    func testStopsDoNotBiasPace() {
        var p = PaceEstimator()
        for _ in 0..<600 { p.add(speed: 0.5, routingSpeed: 10, roadClass: .secondary, dt: 1) }
        XCTAssertEqual(p.coefficient(.secondary), 1.0)
    }

    func testCoefficientIsClamped() {
        var p = PaceEstimator()
        for _ in 0..<3_600 { p.add(speed: 50, routingSpeed: 10, roadClass: .link, dt: 1) }
        XCTAssertEqual(p.coefficient(.link), PaceEstimator.bounds.upperBound, accuracy: 1e-9)
        let h = PaceEstimator(history: [.curvy: 0.1])
        XCTAssertEqual(h.coefficient(.curvy), PaceEstimator.bounds.lowerBound)
    }

    func testIgnoresAbsurdSamples() {
        var p = PaceEstimator()
        p.add(speed: .nan, routingSpeed: 10, roadClass: .curvy, dt: 1)
        p.add(speed: 10, routingSpeed: 0, roadClass: .curvy, dt: 1)
        p.add(speed: 10, routingSpeed: 10, roadClass: .curvy, dt: 120) // GPS gap
        XCTAssertEqual(p.coefficient(.curvy), 1.0)
    }

    func testRemainingTimeIncludesStopsBeforeTargetOnly() {
        let p = PaceEstimator()
        let segs = [RouteSegment(distance: 10_000, routingSpeed: 10, roadClass: .link),
                    RouteSegment(distance: 10_000, routingSpeed: 10, roadClass: .link)]
        let stops = [PlannedStop(distanceAlong: 5_000, duration: 600),
                     PlannedStop(distanceAlong: 15_000, duration: 600)]
        XCTAssertEqual(p.remainingTime(to: 10_000, segments: segs, stops: stops), 1_000 + 600, accuracy: 1e-6)
        XCTAssertEqual(p.remainingTime(to: 20_000, segments: segs, stops: stops), 2_000 + 1_200, accuracy: 1e-6)
    }

    func testCodableRoundTrip() throws {
        var p = PaceEstimator()
        for _ in 0..<120 { p.add(speed: 8, routingSpeed: 10, roadClass: .curvy, dt: 1) }
        let back = try JSONDecoder().decode(PaceEstimator.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.coefficient(.curvy), p.coefficient(.curvy), accuracy: 1e-12)
    }
}
