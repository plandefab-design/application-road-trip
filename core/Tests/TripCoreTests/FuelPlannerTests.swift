import XCTest
@testable import TripCore

final class FuelPlannerTests: XCTestCase {
    /// Stations every `everyKm` along a straight north route, offset 200 m east.
    func stations(routeKm: Double, everyKm: Double) -> [FuelStation] {
        stride(from: everyKm, to: routeKm, by: everyKm).map {
            FuelStation(id: "s\(Int($0))", name: "S\(Int($0))", point: Fixtures.point(onNorthLineAtKm: $0, eastOffsetM: 200))
        }
    }

    /// SPEC §5.2 invariant: every interval ≤ limit.
    func assertInvariant(_ plan: FuelPlan, routeLength: Double, interval: Double, file: StaticString = #filePath, line: UInt = #line) {
        var last = 0.0
        for s in plan.stops {
            XCTAssertLessThanOrEqual(s.distanceAlong - last, interval + 1, file: file, line: line)
            last = s.distanceAlong
        }
        XCTAssertLessThanOrEqual(routeLength - last, interval + 1, file: file, line: line)
    }

    func testShortRouteNeedsNoStop() {
        let route = Fixtures.northLine(km: 150, stepM: 500)
        let plan = FuelPlanner.plan(route: route, stations: stations(routeKm: 150, everyKm: 30), interval: 200_000)
        XCTAssertTrue(plan.stops.isEmpty)
        XCTAssertTrue(plan.gaps.isEmpty)
    }

    func testInvariantHoldsOnLongRoute() {
        for (routeKm, every, intervalKm) in [(620.0, 25.0, 200.0), (900.0, 40.0, 180.0), (450.0, 7.0, 170.0)] {
            let route = Fixtures.northLine(km: routeKm, stepM: 500)
            let interval = intervalKm * 1000
            let plan = FuelPlanner.plan(route: route, stations: stations(routeKm: routeKm, everyKm: every), interval: interval)
            XCTAssertTrue(plan.gaps.isEmpty, "route \(routeKm) km")
            assertInvariant(plan, routeLength: route.length, interval: interval)
            XCTAssertTrue(plan.stops.allSatisfy { $0.detour <= FuelPlanner.maxDetour })
        }
    }

    func testAnticipatesBeforeLimit() {
        let route = Fixtures.northLine(km: 400, stepM: 500)
        let plan = FuelPlanner.plan(route: route, stations: stations(routeKm: 400, everyKm: 10), interval: 200_000)
        // First stop should be at or before 180 km (200 - 20 anticipation).
        XCTAssertLessThanOrEqual(plan.stops.first!.distanceAlong, 180_000 + 1)
    }

    func testFarStationsAreIgnored() {
        let route = Fixtures.northLine(km: 300, stepM: 500)
        let far = [FuelStation(id: "far", name: "Far", point: Fixtures.point(onNorthLineAtKm: 150, eastOffsetM: 5_000))]
        let plan = FuelPlanner.plan(route: route, stations: far, interval: 200_000)
        XCTAssertFalse(plan.gaps.isEmpty)
        XCTAssertEqual(plan.gaps.first?.from ?? -1, 0, accuracy: 1e-9)
    }

    func testGapIsReportedThenPlanningResumes() {
        let route = Fixtures.northLine(km: 600, stepM: 500)
        // Stations only at 100 km and 350 km: 100 → 350 is a 250 km gap.
        let st = [100.0, 350.0, 500.0].map {
            FuelStation(id: "s\(Int($0))", name: "S", point: Fixtures.point(onNorthLineAtKm: $0))
        }
        let plan = FuelPlanner.plan(route: route, stations: st, interval: 200_000)
        XCTAssertEqual(plan.gaps.count, 1)
        XCTAssertEqual(plan.gaps[0].from, 100_000, accuracy: 50)
        XCTAssertEqual(plan.gaps[0].to, 350_000, accuracy: 50)
        XCTAssertEqual(plan.stops.map { ($0.distanceAlong / 1000).rounded() }, [100, 350, 500])
    }

    func testNextStop() {
        let route = Fixtures.northLine(km: 500, stepM: 500)
        let plan = FuelPlanner.plan(route: route, stations: stations(routeKm: 500, everyKm: 20), interval: 200_000)
        let next = FuelPlanner.next(after: plan.stops[0].distanceAlong + 1, in: plan)
        XCTAssertEqual(next, plan.stops[1])
    }

    func testGroupRangeUsesMostLimitingBike() {
        let p = Fixtures.params(bikes: [Bike(model: "Big", rangeKm: 300), Bike(model: "Small", rangeKm: 180, reserveMarginPct: 10)])
        XCTAssertEqual(p.groupUsableRangeMeters!, 162_000, accuracy: 1e-6)
        XCTAssertEqual(p.fuelIntervalMeters, 162_000, accuracy: 1e-6)
        let q = Fixtures.params(bikes: [Bike(model: "Big", rangeKm: 400)])
        XCTAssertEqual(q.fuelIntervalMeters, 200_000, accuracy: 1e-6, "Project rule caps at 200 km")
    }
}
