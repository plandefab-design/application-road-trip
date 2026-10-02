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

final class StalePackTests: XCTestCase {
    func trip(_ id: String, end: String) -> Trip {
        Trip(id: id, name: id, params: TripParams(start: Place(name: "A"), dateStart: end, dateEnd: end))
    }

    func testDeletedAndLongFinishedTripsFreeTheirMaps() {
        let today = ISODate.parse("2027-06-20")!
        let trips = [trip("next", end: "2027-07-01"), trip("lastweek", end: "2027-06-14"), trip("old", end: "2027-05-01"),
                     trip("nodate", end: "")]
        let stale = OfflineArea.stalePacks(["next", "lastweek", "old", "nodate", "deleted"], trips: trips, today: today)
        XCTAssertEqual(stale, ["old", "deleted"])
    }
}
