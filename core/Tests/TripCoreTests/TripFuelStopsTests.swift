import XCTest
@testable import TripCore

final class TripFuelStopsTests: XCTestCase {
    /// Straight synthetic road north, 0.01° steps (≈ 1.11 km), ≈ 333 km long.
    let track = Polyline((0...300).map { GeoPoint(lat: 43.0 + Double($0) * 0.01, lon: 5.0) })

    func trip(stations: [FuelStation], rangeKm: Double = 200) -> Trip {
        let bike = Bike(model: "Test", rangeKm: rangeKm, reserveMarginPct: 0)
        let params = TripParams(start: Place(name: "A"), dateStart: "2027-06-01", dateEnd: "2027-06-01", bikes: [bike])
        return Trip(name: "T", params: params, days: [TripDay(index: 1, track: track, stations: stations)])
    }

    func station(_ km: Double) -> FuelStation {
        FuelStation(id: "s\(Int(km))", name: "Station \(Int(km))", point: GeoPoint(lat: 43.0 + km / 111.195, lon: 5.001))
    }

    func testStopsPlacedOnEmbeddedStationsRespectRange() {
        var t = trip(stations: [60, 120, 170, 250, 300].map(station))
        let warnings = t.planFuelStops()
        XCTAssertEqual(warnings, [])
        let kms = [0.0] + t.days[0].fuelStops.map(\.kmFromStart) + [track.length / 1000]
        for (a, b) in zip(kms, kms.dropFirst()) {
            XCTAssertLessThanOrEqual(b - a, 200 + 1, "interval \(a)→\(b)")   // invariant: ≤ usable range
        }
        XCTAssertFalse(t.days[0].fuelStops.isEmpty)
    }

    func testGapIsReported() {
        var t = trip(stations: [30].map(station))
        let warnings = t.planFuelStops()
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("aucune station entre le km"))
    }

    func testDayWithoutStationDataKeepsItsStops() {
        var t = trip(stations: [])
        t.days[0].fuelStops = [FuelStopRef(name: "Existante", point: GeoPoint(lat: 44, lon: 5), kmFromStart: 150)]
        let warnings = t.planFuelStops()
        XCTAssertEqual(t.days[0].fuelStops.map(\.name), ["Existante"])
        XCTAssertTrue(warnings[0].contains("aucune station connue"))
    }
}
