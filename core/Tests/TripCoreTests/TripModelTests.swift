import XCTest
@testable import TripCore

final class TripModelTests: XCTestCase {
    func sampleTrip() -> Trip {
        let meal = POI(id: "m1", type: .meal, name: "Restaurant fictif", source: "https://example.org/fiche", verification: .verified)
        let hotel = POI(id: "h1", type: .lodging, name: "Hôtel fictif")
        let track = Fixtures.northLine(km: 180, stepM: 1_000)
        let day = TripDay(index: 1, date: "2027-06-01", distanceKm: 180, track: track,
                          fuelStops: [FuelStopRef(name: "S", point: Fixtures.point(onNorthLineAtKm: 150), kmFromStart: 150)],
                          meals: [POIChoice(poiId: "m1", selected: true)],
                          lodging: [POIChoice(poiId: "h1", selected: true)])
        return Trip(id: "t1", name: "Test", params: Fixtures.params(), days: [day], pois: [meal, hotel])
    }

    func testValidTripHasNoErrors() {
        let issues = TripValidator.validate(sampleTrip())
        XCTAssertTrue(TripValidator.isValid(sampleTrip()), issues.description)
    }

    func testJSONRoundTrip() throws {
        let trip = sampleTrip()
        let back = try TripCodec.decode(TripCodec.encode(trip))
        XCTAssertEqual(back, trip)
    }

    func testDecodeForcesUnverifiedWithoutSource() throws {
        var trip = sampleTrip()
        trip.pois[1].verification = .verified   // no source!
        let back = try TripCodec.decode(JSONEncoder().encode(trip))
        XCTAssertEqual(back.poi(id: "h1")?.verification, .unverified)
    }

    func testValidatorFlagsVerifiedWithoutSource() {
        var trip = sampleTrip()
        trip.pois[1].verification = .verified
        XCTAssertTrue(TripValidator.validate(trip).contains { $0.code == "pois.source" })
    }

    func testRejectsFutureSchema() throws {
        var trip = sampleTrip()
        trip.schemaVersion = 99
        XCTAssertThrowsError(try TripCodec.decode(JSONEncoder().encode(trip))) {
            XCTAssertEqual($0 as? TripCodecError, .unsupportedSchemaVersion(99))
        }
    }

    func testValidatorFlagsFuelGapAndBadRefs() {
        var trip = sampleTrip()
        trip.days[0].distanceKm = 450
        // 0 → 210 km (> 200) then 210 → 450 km (240 km to arrival)
        trip.days[0].fuelStops = [FuelStopRef(name: "late", point: GeoPoint(lat: 44, lon: 6), kmFromStart: 210)]
        trip.days[0].meals.append(POIChoice(poiId: "ghost"))
        let codes = Set(TripValidator.validate(trip).map(\.code))
        XCTAssertTrue(codes.contains("days.fuel"))
        XCTAssertTrue(codes.contains("days.fuel.end"))
        XCTAssertTrue(codes.contains("days.poiRef"))
    }

    func testValidatorFlagsDates() {
        var trip = sampleTrip()
        trip.params.dateEnd = "2027-05-01"
        XCTAssertTrue(TripValidator.validate(trip).contains { $0.code == "params.dates" })
        trip.params.dateEnd = "2027-02-31"
        XCTAssertTrue(TripValidator.validate(trip).contains { $0.code == "params.dateEnd" })
    }

    func testSelectedStops() {
        let trip = sampleTrip()
        XCTAssertEqual(trip.selectedStops(for: trip.days[0]).map(\.id), ["m1", "h1"])
    }

    func testISODate() {
        let d = ISODate.parse("2027-06-01")!
        XCTAssertEqual(ISODate.format(d), "2027-06-01")
        XCTAssertEqual(ISODate.days(from: d, to: ISODate.parse("2027-06-09")!), 8)
        XCTAssertNil(ISODate.parse("2027-13-01"))
        XCTAssertNil(ISODate.parse("hello"))
    }

    func testCatalogLoads() {
        XCTAssertFalse(Catalog.regions().isEmpty)
        XCTAssertFalse(Catalog.bikeModels().isEmpty)
        XCTAssertTrue(Catalog.cols().allSatisfy { !$0.source.isEmpty })
    }
}

final class ConsistencyTests: XCTestCase {
    func testCoherentParamsProduceNoBlockingQuestion() {
        let q = ConsistencyChecker.check(Fixtures.params())
        XCTAssertTrue(q.isEmpty, q.map(\.message).joined(separator: "\n"))
    }

    func testCapacityQuestion() {
        var p = Fixtures.params()
        p.end = Place(name: "Far", point: GeoPoint(lat: 50, lon: 6))   // ≈ 667 km straight line
        p.maxKmPerDay = 150
        XCTAssertTrue(ConsistencyChecker.check(p).contains { $0.code == "distance.capacity" })
    }

    func testMissingZoneAndBikes() {
        var p = Fixtures.params(bikes: [])
        p.zone = []
        let codes = Set(ConsistencyChecker.check(p).map(\.code))
        XCTAssertTrue(codes.isSuperset(of: ["zone.empty", "bikes.empty"]))
    }

    func testShortRangeBikeQuestion() {
        let p = Fixtures.params(bikes: [Bike(model: "Small", rangeKm: 150)])
        XCTAssertTrue(ConsistencyChecker.check(p).contains { $0.code == "fuel.range" })
    }

    func testClosedPassQuestionUsesProvidedData() {
        let col = ColInfo(id: "c1", name: "Col fictif", point: GeoPoint(lat: 44.5, lon: 6.5), zone: "FR-ALPES-SUD",
                          usuallyOpenMonths: [7, 8, 9], source: "https://example.org/source", lastVerified: "2026-09-28")
        let q = ConsistencyChecker.check(Fixtures.params(), cols: [col])   // trip in June
        XCTAssertTrue(q.contains { $0.code == "col.closed.c1" })
        var summer = Fixtures.params()
        summer.dateStart = "2027-07-10"; summer.dateEnd = "2027-07-12"
        XCTAssertFalse(ConsistencyChecker.check(summer, cols: [col]).contains { $0.code == "col.closed.c1" })
    }

    func testMonthsCovered() {
        let a = ISODate.parse("2027-05-30")!, b = ISODate.parse("2027-07-02")!
        XCTAssertEqual(ConsistencyChecker.monthsCovered(from: a, to: b), [5, 6, 7])
    }
}

final class LenientDecodingTests: XCTestCase {
    func testMinimalPlannerJSONDecodes() throws {
        let json = """
        {"schemaVersion": 1, "id": "t9", "name": "Mini",
         "params": {"start": {"name": "Aix"}, "dateStart": "2027-06-01", "dateEnd": "2027-06-02"},
         "days": [{"index": 1, "distanceKm": 210}]}
        """
        let trip = try TripCodec.decode(Data(json.utf8))
        XCTAssertEqual(trip.status, .draft)
        XCTAssertEqual(trip.params.maxFuelIntervalKm, 200)
        XCTAssertEqual(trip.days[0].fuelStops, [])
        XCTAssertEqual(trip.offlinePack.integrity, .unknown)
    }
}
