import XCTest
@testable import TripCore

/// Trips created without dates (schema v9). Synthetic trip only.
final class TripDatesTests: XCTestCase {
    func flexibleTrip() -> Trip {
        var params = TripParams(start: Place(name: "A"), dateStart: "2027-01-10", dateEnd: "2027-01-12")
        params.flexibleDates = true
        return Trip(name: "T", params: params, days: [TripDay(index: 1), TripDay(index: 2), TripDay(index: 3)],
                    mustCheck: ["Réserver le refuge", "📅 Col test : fermé du 1er oct. au 15 juin (OpenStreetMap)."])
    }

    func testFlexibleDatesRoundTripAndOldFilesStayFixed() throws {
        let trip = flexibleTrip()
        XCTAssertTrue(trip.params.datesToChoose)
        XCTAssertEqual(trip.params.dayCount, 3)
        let back = try TripCodec.decode(TripCodec.encode(trip))
        XCTAssertTrue(back.params.datesToChoose)
        XCTAssertEqual(back.schemaVersion, 9)
        let old = try TripCodec.decode(Data("""
        {"schemaVersion": 8, "id": "t", "name": "Ancien", "status": "draft",
         "params": {"start": {"name": "A"}, "dateStart": "2027-06-01", "dateEnd": "2027-06-02"}}
        """.utf8))
        XCTAssertFalse(old.params.datesToChoose)
        XCTAssertFalse(String(decoding: try TripCodec.encode(old), as: UTF8.self).contains("flexibleDates"))
    }

    func testFixingTheChosenPeriod() {
        var trip = flexibleTrip()
        XCTAssertTrue(trip.fixDates(start: "2027-06-14", checks: ["🌦 Météo de saison, jour 1 : pluie 4 jours sur 10."]))
        XCTAssertEqual(trip.params.dateStart, "2027-06-14")
        XCTAssertEqual(trip.params.dateEnd, "2027-06-16")
        XCTAssertEqual(trip.days.map(\.date), ["2027-06-14", "2027-06-15", "2027-06-16"])
        XCTAssertFalse(trip.params.datesToChoose)
        XCTAssertEqual(trip.mustCheck, ["Réserver le refuge", "🌦 Météo de saison, jour 1 : pluie 4 jours sur 10."])
        XCTAssertFalse(trip.fixDates(start: "bientôt"))
    }

    func testRoadBookWaitsForTheDates() {
        XCTAssertTrue(RoadBook.blockers(flexibleTrip()).contains { $0.hasPrefix("Dates à choisir") })
        XCTAssertEqual(RoadBook.period(flexibleTrip().params), "à choisir (3 jours)")
    }

    func testOfflineMapOfAnUndatedTripIsKept() {
        let trip = flexibleTrip()
        let stale = OfflineArea.stalePacks([trip.id], trips: [trip], today: ISODate.parse("2028-01-01")!)
        XCTAssertTrue(stale.isEmpty)
    }
}
