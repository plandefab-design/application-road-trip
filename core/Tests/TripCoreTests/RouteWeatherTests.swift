import XCTest
@testable import TripCore

final class RouteWeatherTests: XCTestCase {
    /// Straight synthetic road north, ≈ 111 km.
    let route = Polyline((0...100).map { GeoPoint(lat: 43.0 + Double($0) * 0.01, lon: 5.0) })

    func testSamplesEvery15kmPlusEndAndExtras() {
        let s = RouteWeather.samples(route: route, extra: [40_000, 45_500])
        let d = s.map(\.along)
        XCTAssertEqual(d.first, 0)
        XCTAssertEqual(d.last!, route.length, accuracy: 1)
        XCTAssertTrue(d.contains(40_000))           // a pass or stop is always sampled…
        XCTAssertFalse(d.contains(45_500))          // …unless within 2 km of another point (45 km)
        XCTAssertEqual(d, d.sorted())
        for (a, b) in zip(d, d.dropFirst()) { XCTAssertLessThanOrEqual(b - a, 15_000 + 1) }   // invariant: gap ≤ 15 km
    }

    func testSamplesStartAtProgressAndAreCapped() {
        XCTAssertEqual(RouteWeather.samples(route: route, from: 100_000).first?.along, 100_000)
        XCTAssertEqual(RouteWeather.samples(route: route, maxCount: 3).count, 3)
    }

    func testParseSingleAndMultipleLocations() throws {
        let one = """
        {"hourly": {"time": [0, 3600], "precipitation": [0.0, 1.2], "wind_gusts_10m": [10, 20],
                    "temperature_2m": [12, 11], "visibility": [20000, null]}}
        """
        let parsed = try RouteWeather.parse(Data(one.utf8))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].precipitation, [0.0, 1.2])
        XCTAssertEqual(parsed[0].visibility, [20000, nil])
        let many = "[\(one), \(one)]"
        XCTAssertEqual(try RouteWeather.parse(Data(many.utf8)).count, 2)
    }

    func testHazardsAtPassingTime() {
        let samples = RouteWeather.samples(route: route, maxCount: 2)
        // Fixture forecast: dry at 00:00, rain + gusts at 01:00 (Unix epoch hours).
        let f = RouteWeather.Hourly(times: [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 3_600)],
                                    precipitation: [0, 2.0], gusts: [20, 75], temperature: [12, 3], visibility: [20_000, 500])
        let etas = [Date(timeIntervalSince1970: 600), Date(timeIntervalSince1970: 4_000)]
        let hazards = RouteWeather.hazards(samples: samples, etas: etas, forecasts: [f, f])
        XCTAssertEqual(hazards.count, 1)
        XCTAssertEqual(hazards[0].kinds, [.rain, .wind, .cold, .fog])
        XCTAssertEqual(hazards[0].summary, "Pluie 2,0 mm/h, Rafales 75 km/h, 3 °C, Visibilité réduite")
        // Outside the forecast range: no alert rather than a guess.
        XCTAssertTrue(RouteWeather.hazards(samples: samples, etas: etas.map { $0.addingTimeInterval(86_400) }, forecasts: [f, f]).isEmpty)
    }

    func testRequestURLListsEveryPoint() throws {
        let url = try XCTUnwrap(RouteWeather.requestURL(RouteWeather.samples(route: route, maxCount: 3)))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "latitude" }?.value?.split(separator: ",").count, 3)
        XCTAssertEqual(items.first { $0.name == "forecast_days" }?.value, "16")
    }

    func testEtasIncreaseAlongTheRoute() {
        let samples = RouteWeather.samples(route: route)
        let etas = RouteWeather.etas(samples: samples, route: route, progress: 0, start: Date(timeIntervalSince1970: 0), pace: PaceEstimator())
        XCTAssertEqual(etas.first!.timeIntervalSince1970, 0, accuracy: 1)
        XCTAssertEqual(etas, etas.sorted())
        XCTAssertGreaterThan(etas.last!.timeIntervalSince1970, 3_600)   // > 1 h for 111 km at default speeds
    }
}
