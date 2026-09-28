import XCTest
@testable import TripCore

final class RideProfileTests: XCTestCase {
    func params(_ categories: [BikeCategory?], style: TripStyle? = nil) -> TripParams {
        TripParams(start: Place(name: "A"), dateStart: "2027-06-01", dateEnd: "2027-06-02",
                   bikes: categories.map { Bike(model: "M", rangeKm: 200, category: $0) }, tripStyle: style)
    }

    func testMostRoadBoundBikeDecides() {
        XCTAssertEqual(params([.enduro]).routeProfile, .enduro)
        XCTAssertEqual(params([.trail, .enduro]).routeProfile, .adventure)
        XCTAssertEqual(params([.sport, .enduro]).routeProfile, .curvy)
        XCTAssertEqual(params([nil]).routeProfile, .curvy)
        XCTAssertEqual(params([]).routeProfile, .curvy)
        XCTAssertEqual(params([.enduro], style: .rapide).routeProfile, .fast)
    }

    func testV4FileDecodesAndUnknownValuesAreTolerated() throws {
        let json = """
        {"schemaVersion": 4, "id": "t", "name": "N",
         "params": {"start": {"name": "A"}, "dateStart": "2027-06-01", "dateEnd": "2027-06-02",
                    "bikes": [{"id": "b", "model": "M", "rangeKm": 200, "reserveMarginPct": 15, "category": "hoverbike"}],
                    "tripStyle": "kiff", "level": "legend"}}
        """
        let trip = try TripCodec.decode(Data(json.utf8))
        XCTAssertEqual(trip.schemaVersion, Trip.currentSchemaVersion)
        XCTAssertEqual(trip.params.bikes[0].category, .roadster)
        XCTAssertEqual(trip.params.tripStyle, .kiff)
        XCTAssertEqual(trip.params.level, .confirme)
        let again = try TripCodec.decode(TripCodec.encode(trip))
        XCTAssertEqual(again.params, trip.params)
    }
}
