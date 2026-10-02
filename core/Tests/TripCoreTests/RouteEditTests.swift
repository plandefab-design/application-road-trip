import XCTest
@testable import TripCore

/// Synthetic places only.
final class RouteEditTests: XCTestCase {
    func at(_ km: Double, east: Double = 0) -> GeoPoint { Fixtures.point(onNorthLineAtKm: km, eastOffsetM: east) }

    func day() -> TripDay {
        TripDay(index: 1, highlights: [Highlight(name: "P30", point: at(30)), Highlight(name: "P70", point: at(70))],
                track: Fixtures.northLine(km: 100, stepM: 1_000))
    }

    func testTappedPointGoesInRouteOrder() {
        var d = day()
        XCTAssertEqual(RouteEdit.addPassage("P10", at: at(10, east: 2_000), to: &d), 0)
        XCTAssertEqual(RouteEdit.addPassage("P50", at: at(50, east: -5_000), to: &d), 2)
        XCTAssertEqual(RouteEdit.addPassage("P95", at: at(95), to: &d), 4)
        XCTAssertEqual(d.highlights.map(\.name), ["P10", "P30", "P50", "P70", "P95"])
        XCTAssertEqual(d.highlights[0].point, at(10, east: 2_000))
    }

    func testPassagesWithoutPositionKeepTheirPlace() {
        var d = day()
        d.highlights.insert(Highlight(name: "Col sans position"), at: 1)       // P30, ?, P70
        let i = RouteEdit.insertionIndex(of: at(60), in: d)
        XCTAssertEqual(i, 2, "between the unlocated passage and P70, never before a known earlier one")
    }

    func testNoTrackNoPassagesAppends() {
        var d = TripDay(index: 2)
        XCTAssertEqual(RouteEdit.addPassage("Seul", at: at(5), to: &d), 0)
        XCTAssertEqual(RouteEdit.addPassage("Deux", at: at(1), to: &d), 1)      // nothing to compare against: last
    }

    /// Property: whatever the tap, the order of the existing passages never changes and the count grows by one.
    func testExistingOrderIsPreserved() {
        for k in stride(from: -20.0, through: 120.0, by: 7.5) {
            var d = day()
            RouteEdit.addPassage("X", at: at(k, east: k.truncatingRemainder(dividingBy: 2) == 0 ? 3_000 : -1_500), to: &d)
            XCTAssertEqual(d.highlights.filter { $0.name != "X" }.map(\.name), ["P30", "P70"])
            XCTAssertEqual(d.highlights.count, 3)
        }
    }
}
