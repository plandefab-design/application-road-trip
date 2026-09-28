import XCTest
@testable import TripCore

final class RideCompanionTests: XCTestCase {
    func testSpeedLimitLookup() {
        let ranges = [SpeedLimitRange(from: 0, to: 1_000, kmh: 50), SpeedLimitRange(from: 1_000, to: 5_000, kmh: 80),
                      SpeedLimitRange(from: 6_000, to: 9_000, kmh: 90)]
        XCTAssertEqual(SpeedLimits.limit(ranges, at: 500), 50)
        XCTAssertEqual(SpeedLimits.limit(ranges, at: 3_000), 80)
        XCTAssertNil(SpeedLimits.limit(ranges, at: 5_500))        // unknown: nothing shown, nothing guessed
        XCTAssertEqual(SpeedLimits.limit(ranges, at: 9_000), 90)
        XCTAssertNil(SpeedLimits.limit([], at: 10))
        XCTAssertFalse(SpeedLimits.isOver(speedKmh: 84, limit: 80))
        XCTAssertTrue(SpeedLimits.isOver(speedKmh: 86, limit: 80))
        XCTAssertFalse(SpeedLimits.isOver(speedKmh: 135, limit: 130))
    }

    func testBreakTracker() {
        var t = BreakTracker()
        for _ in 0..<100 { t.update(speed: 20, dt: 60) }          // 100 min riding
        XCTAssertEqual(t.ridingSinceBreak, 6_000)
        for _ in 0..<3 { t.update(speed: 0, dt: 60) }             // 3 min at a red light: not a break
        XCTAssertEqual(t.ridingSinceBreak, 6_000)
        for _ in 0..<3 { t.update(speed: 0, dt: 60) }             // 6 min stopped: break
        XCTAssertEqual(t.ridingSinceBreak, 0)
        t.update(speed: 20, dt: 600)                               // gap (tunnel): ignored
        XCTAssertEqual(t.ridingSinceBreak, 0)
    }

    func testPauseSuggestionPrefersACafeOnceAPauseIsDue() {
        let pauses = [PauseSpot(along: 3_000, kind: .water, name: "Fontaine"),
                      PauseSpot(along: 8_000, kind: .viewpoint, name: "Belvédère"),
                      PauseSpot(along: 12_000, kind: .cafe, name: "Café du col"),
                      PauseSpot(along: 25_000, kind: .cafe, name: "Café suivant")]
        XCTAssertNil(PauseAdvisor.suggestion(pauses, progress: 0, ridingSinceBreak: 3_600))
        let s = PauseAdvisor.suggestion(pauses, progress: 0, ridingSinceBreak: 5_400)
        XCTAssertEqual(s?.spot.name, "Café du col")
        XCTAssertEqual(s?.distance, 12_000)
        XCTAssertEqual(PauseAdvisor.suggestion(pauses, progress: 12_500, ridingSinceBreak: 6_000)?.spot.name, "Café suivant")
    }

    func testRideSummary() {
        // Synthetic straight ride north: 11 fixes 111 m apart, 10 s apart (≈ 40 km/h), climbing 10 m each.
        let points = (0...10).map { GeoPoint(lat: 43.0 + Double($0) * 0.001, lon: 5.0, ele: 100 + Double($0) * 10) }
        let times = (0...10).map { Date(timeIntervalSince1970: Double($0) * 10) }
        let s = RideSummary.summarize(points: points, times: times, speeds: Array(repeating: 11.1, count: 11))
        XCTAssertEqual(s.distance, 1_112, accuracy: 5)
        XCTAssertEqual(s.movingTime, 100)
        XCTAssertEqual(s.totalTime, 100)
        XCTAssertEqual(s.ascent ?? 0, 100, accuracy: 0.1)
        XCTAssertEqual(s.bends, 0)
        XCTAssertEqual(s.averageMovingSpeed * 3.6, 40, accuracy: 1)
    }

    func testBendsOnAZigzag() {
        // Synthetic zigzag: legs of ~300 m alternating north-east / north-west = one bend per corner.
        var pts = [GeoPoint(lat: 43.0, lon: 5.0)]
        for i in 0..<8 {
            let last = pts.last!
            pts.append(GeoPoint(lat: last.lat + 0.002, lon: last.lon + (i.isMultiple(of: 2) ? 0.0027 : -0.0027)))
        }
        let bends = RideSummary.bends(in: Polyline(pts))
        XCTAssertGreaterThanOrEqual(bends, 5)
        XCTAssertLessThanOrEqual(bends, 8)
    }

    func testSyncPlan() {
        let plan = TripSync.plan(
            local: ["a": "2027-01-02T10:00:00Z", "b": "2027-01-01T10:00:00Z", "c": nil, "d": "2027-01-01T10:00:00Z", "e": nil],
            remote: ["a": "2027-01-01T10:00:00Z", "b": "2027-01-03T10:00:00Z", "d": "2027-01-01T10:00:00Z",
                     "e": "2027-01-01T10:00:00Z", "f": nil])
        XCTAssertEqual(plan.push, ["a", "c"])     // newer on the phone, or only on the phone
        XCTAssertEqual(plan.pull, ["b", "e", "f"]) // newer on the PC, dated vs undated, or only on the PC
        XCTAssertTrue(TripSync.timestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    }

    func testPauseSpotsRelocatedOnTheTrack() {
        let track = Fixtures.northLine(km: 20)
        let cafe = PauseSpot(along: 12_000, kind: .cafe, name: "Café", point: Fixtures.point(onNorthLineAtKm: 10, eastOffsetM: 80))
        let unknown = PauseSpot(along: 4_000, kind: .water, name: "Eau")
        let out = PauseAdvisor.relocated([cafe, unknown], on: track)
        XCTAssertEqual(out.map(\.name), ["Eau", "Café"])
        XCTAssertEqual(out[1].along, 10_000, accuracy: 5)
    }
}
