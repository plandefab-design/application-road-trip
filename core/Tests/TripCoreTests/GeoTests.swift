import XCTest
@testable import TripCore

final class GeoTests: XCTestCase {
    func testOneDegreeOfLatitude() {
        let d = Geo.distance(GeoPoint(lat: 44, lon: 6), GeoPoint(lat: 45, lon: 6))
        XCTAssertEqual(d, Fixtures.mPerDegLat, accuracy: 1)
    }

    func testBearingCardinals() {
        let o = GeoPoint(lat: 44, lon: 6)
        XCTAssertEqual(Geo.bearing(o, GeoPoint(lat: 45, lon: 6)), 0, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(o, GeoPoint(lat: 44, lon: 7)), 90, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(o, GeoPoint(lat: 43, lon: 6)), 180, accuracy: 0.01)
    }

    func testAngleDeltaWraps() {
        XCTAssertEqual(Geo.angleDelta(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(Geo.angleDelta(10, 350), -20, accuracy: 1e-9)
        XCTAssertEqual(Geo.angleDelta(0, 180), 180, accuracy: 1e-9)
    }

    func testPolylineLengthAndPointAt() {
        let line = Fixtures.northLine(km: 10)
        XCTAssertEqual(line.length, 10_000, accuracy: 1)
        let mid = line.point(at: 5_000)!
        XCTAssertEqual(Geo.distance(line.points[0], mid), 5_000, accuracy: 1)
        XCTAssertEqual(line.point(at: -5), line.points.first)
        XCTAssertEqual(line.point(at: 99_999)!.lat, line.points.last!.lat, accuracy: 1e-12)
    }

    func testLocateProjectsWithLateralOffset() {
        let line = Fixtures.northLine(km: 10)
        let p = Fixtures.point(onNorthLineAtKm: 3.25, eastOffsetM: 30)
        let m = line.locate(p)!
        XCTAssertEqual(m.distanceAlong, 3_250, accuracy: 2)
        XCTAssertEqual(m.lateralOffset, 30, accuracy: 1)
    }

    func testLocateWithHintStaysLocal() {
        let line = Fixtures.northLine(km: 10)
        let p = Fixtures.point(onNorthLineAtKm: 8)
        let m = line.locate(p, hint: 7_900, window: 500)!
        XCTAssertEqual(m.distanceAlong, 8_000, accuracy: 2)
    }

    func testResampleKeepsLength() {
        let line = Fixtures.northLine(km: 2, stepM: 333)
        let r = line.resampled(every: 10)
        XCTAssertEqual(r.length, line.length, accuracy: 0.5)
        XCTAssertGreaterThan(r.points.count, 190)
    }

    func testSlice() {
        let line = Fixtures.northLine(km: 10)
        let s = line.slice(from: 2_000, to: 5_500)
        XCTAssertEqual(s.length, 3_500, accuracy: 1)
        XCTAssertTrue(line.slice(from: 5_000, to: 4_000).points.isEmpty)
    }

    func testAscent() {
        let line = Polyline([
            GeoPoint(lat: 44, lon: 6, ele: 100), GeoPoint(lat: 44.001, lon: 6, ele: 150),
            GeoPoint(lat: 44.002, lon: 6, ele: 120), GeoPoint(lat: 44.003, lon: 6, ele: 200)
        ])
        XCTAssertEqual(line.ascent, 130, accuracy: 1e-9)
    }

    func testPolylineCodableRoundTrip() throws {
        let line = Fixtures.northLine(km: 1)
        let data = try JSONEncoder().encode(line)
        let back = try JSONDecoder().decode(Polyline.self, from: data)
        XCTAssertEqual(back, line)
    }
}
