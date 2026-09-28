import XCTest
@testable import TripCore

final class StageTimingTests: XCTestCase {
    let params = TripParams(start: Place(name: "A"), dateStart: "2027-06-01", dateEnd: "2027-06-02",
                            bikes: [Bike(model: "Test", rangeKm: 250)])

    func testSegmentsMatchThePlannedTime() {
        let track = Fixtures.northLine(km: 100)
        let segments = SegmentBuilder.segments(for: track, plannedDuration: 7_200)
        XCTAssertEqual(PaceEstimator().drivingTime(segments), 7_200, accuracy: 1)
        // Without a plan the default speeds stay.
        XCTAssertEqual(SegmentBuilder.segments(for: track, plannedDuration: nil), SegmentBuilder.segments(for: track))
    }

    func testRidingBreaksFuelAndLunch() throws {
        // 5 h planned, one fuel stop: 3 breaks due (every 1 h 30), the fuel stop counts as one → 2 breaks; lunch.
        let day = TripDay(index: 1, date: "2027-06-01", distanceKm: 300, drivingTimeMin: 300,
                          track: Fixtures.northLine(km: 300, stepM: 500),
                          fuelStops: [FuelStopRef(name: "S", point: GeoPoint(lat: 45, lon: 6), kmFromStart: 150)])
        let t = try XCTUnwrap(StageTimer.estimate(day, in: Trip(name: "T", params: params, days: [day])))
        XCTAssertEqual(t.riding, 18_000, accuracy: 1)
        XCTAssertEqual(t.fuelStops, 1)
        XCTAssertEqual(t.breaks, 2)
        XCTAssertEqual(t.meals, 1)
        XCTAssertEqual(t.total, 18_000 + 600 + 1_800 + 4_500, accuracy: 1)
    }

    func testShortDayHasNoLunchAndArrivalFollowsDeparture() throws {
        let day = TripDay(index: 1, date: "2027-06-01", drivingTimeMin: 80)
        let utc = TimeZone(identifier: "UTC")!
        let departure = try XCTUnwrap(StageTimer.defaultDeparture(for: day, timeZone: utc))
        XCTAssertEqual(ISODate.format(departure), "2027-06-01")
        XCTAssertEqual(departure.timeIntervalSince(ISODate.parse("2027-06-01")!), 9 * 3600)
        let t = try XCTUnwrap(StageTimer.estimate(day, in: Trip(name: "T", params: params, days: [day]), departure: departure))
        XCTAssertEqual(t.meals, 0)
        XCTAssertEqual(t.breaks, 0)
        XCTAssertEqual(t.arrival, departure.addingTimeInterval(80 * 60))
    }

    func testNoTrackNoPlanNoEstimate() {
        let day = TripDay(index: 1)
        XCTAssertNil(StageTimer.estimate(day, in: Trip(name: "T", params: params, days: [day])))
    }
}
