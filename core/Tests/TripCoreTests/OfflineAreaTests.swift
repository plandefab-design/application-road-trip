import XCTest
@testable import TripCore

final class OfflineAreaTests: XCTestCase {
    func testBoundsContainEveryPointWithMargin() throws {
        let points = [GeoPoint(lat: 44.0, lon: 5.0), GeoPoint(lat: 44.5, lon: 6.0), GeoPoint(lat: 43.8, lon: 5.5)]
        let b = try XCTUnwrap(OfflineArea.bounds(points, marginKm: 10))
        for p in points {
            XCTAssertTrue((b.minLat...b.maxLat).contains(p.lat) && (b.minLon...b.maxLon).contains(p.lon))
        }
        XCTAssertEqual(43.8 - b.minLat, 10 / 111.2, accuracy: 1e-9)
        XCTAssertGreaterThan(b.maxLon - 6.0, 10 / 111.2)   // longitude degrees are shorter than latitude ones
    }

    func testEmptyTrackHasNoArea() {
        XCTAssertNil(OfflineArea.bounds([]))
    }
}
