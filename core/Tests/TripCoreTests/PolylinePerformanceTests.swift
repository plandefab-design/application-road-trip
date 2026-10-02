import XCTest
@testable import TripCore

/// The fast projection gives the same answer as the exact one, and alerts along a route stay right. Synthetic data.
final class PolylinePerformanceTests: XCTestCase {
    /// Reference: exact distance to every segment (the former per-segment computation).
    func reference(_ line: Polyline, _ p: GeoPoint) -> (along: Double, offset: Double) {
        var best = (along: 0.0, offset: Double.infinity)
        for i in 0..<(line.points.count - 1) {
            let a = line.points[i], b = line.points[i + 1]
            let pb = Geo.toLocal(b, origin: a), pp = Geo.toLocal(p, origin: a)
            let len2 = pb.x * pb.x + pb.y * pb.y
            let t = len2 > 0 ? min(max((pp.x * pb.x + pp.y * pb.y) / len2, 0), 1) : 0
            let d = Geo.distance(p, Geo.interpolate(a, b, t))
            if d < best.offset { best = (line.cumulative[i] + (line.cumulative[i + 1] - line.cumulative[i]) * t, d) }
        }
        return best
    }

    func testSameMatchAsTheExactComputation() {
        let line = Fixtures.zigzag(km: 20, legM: 200)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let p = GeoPoint(lat: 44.0 + Double.random(in: -0.01...0.19, using: &rng), lon: 6.0 + Double.random(in: -0.02...0.02, using: &rng))
            let fast = line.locate(p)!, exact = reference(line, p)
            XCTAssertEqual(fast.lateralOffset, exact.offset, accuracy: max(0.5, exact.offset * 0.001))
            if exact.offset < 200 { XCTAssertEqual(fast.distanceAlong, exact.along, accuracy: 2) }
        }
    }

    func testSliceKeepsTheInnerPoints() {
        let line = Fixtures.northLine(km: 10, stepM: 100)
        let s = line.slice(from: 2_050, to: 2_450)
        XCTAssertEqual(s.points.count, 6)                      // 2 050, 2 100 … 2 400, 2 450
        XCTAssertEqual(s.length, 400, accuracy: 0.5)
    }

    func testAlertOnALoopIsMetAtEachPassage() {
        // Out north 10 km, back south on a road 40 m to the east: a camera between both roads at km 5.
        let out = (0...100).map { GeoPoint(lat: 44.0 + Double($0) * 100 / Fixtures.mPerDegLat, lon: 6.0) }
        let back = (0...100).map { GeoPoint(lat: 44.0 + Double(100 - $0) * 100 / Fixtures.mPerDegLat, lon: 6.0005) }
        let loop = Polyline(out + back)
        let camera = PositionedAlert(point: Fixtures.point(onNorthLineAtKm: 5, eastOffsetM: 20),
                                     alert: RoadAlert(along: 0, kind: .speedCamera, label: "radar"))
        let found = FreeRideGuide(alerts: [camera]).along(loop, maxOffset: 40)
        XCTAssertEqual(found.count, 2, "on the way out and on the way back (the roads are 40 m apart)")
        XCTAssertEqual(found[0].along, 5_000, accuracy: 30)
    }
}
