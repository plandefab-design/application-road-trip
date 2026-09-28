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
