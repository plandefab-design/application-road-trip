import XCTest
@testable import TripCore

final class GPXTests: XCTestCase {
    let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- test -->
    <gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
      <metadata><name>Doc</name></metadata>
      <wpt lat="44.1" lon="6.1"><ele>1200</ele><name>Pause &amp; café</name><type>meal</type></wpt>
      <trk><name>Jour 1</name>
        <trkseg>
          <trkpt lat="44.0" lon="6.0"><ele>500</ele></trkpt>
          <trkpt lat="44.01" lon="6.0"/>
        </trkseg>
        <trkseg>
          <trkpt lat='44.02' lon='6.0'></trkpt>
        </trkseg>
      </trk>
      <rte><name><![CDATA[Route B]]></name>
        <rtept lat="45.0" lon="7.0"/><rtept lat="45.01" lon="7.0"/>
      </rte>
    </gpx>
    """

    func testParse() throws {
        let doc = try GPX.parse(sample)
        XCTAssertEqual(doc.tracks.count, 2)
        XCTAssertEqual(doc.tracks[0].points.count, 3, "trksegs are concatenated")
        XCTAssertEqual(doc.tracks[0].points[0].ele, 500)
        XCTAssertEqual(doc.trackNames, ["Jour 1", "Route B"])
        XCTAssertEqual(doc.waypoints.count, 1)
        XCTAssertEqual(doc.waypoints[0].name, "Pause & café")
        XCTAssertEqual(doc.waypoints[0].type, "meal")
        XCTAssertEqual(doc.waypoints[0].point.ele, 1200)
    }

    func testRejectsInvalidCoordinates() {
        XCTAssertThrowsError(try GPX.parse("<gpx><wpt lat=\"123\" lon=\"6\"/></gpx>"))
        XCTAssertThrowsError(try GPX.parse("<gpx></gpx>"))
    }

    func testWriteThenReadRoundTrip() throws {
        let line = Fixtures.northLine(km: 2, stepM: 250)
        let text = GPX.write(name: "A <&> B", tracks: [(name: "J1", line: line)],
                             waypoints: [GPXWaypoint(point: GeoPoint(lat: 44, lon: 6), name: "Plein \"S\"", type: "fuel")])
        let doc = try GPX.parse(text)
        XCTAssertEqual(doc.tracks.count, 1)
        XCTAssertEqual(doc.tracks[0].points.count, line.points.count)
        XCTAssertEqual(doc.tracks[0].length, line.length, accuracy: 1)
        XCTAssertEqual(doc.waypoints.first?.name, "Plein \"S\"")
    }
}

final class NavigationComputerTests: XCTestCase {
    func testSnapshotTargetsAndETA() {
        let route = Fixtures.northLine(km: 100, stepM: 500)
        let segs = [RouteSegment(distance: route.length, routingSpeed: 20, roadClass: .link)]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let nav = NavigationComputer(route: route, segments: segs,
                                     fuelStops: [(name: "Plein", along: 60_000)],
                                     stops: [(name: "Déjeuner", along: 40_000, duration: 3_600)],
                                     plannedDuration: 5_000 + 3_600 + 600, dayStart: start)
        let pos = Fixtures.point(onNorthLineAtKm: 20, eastOffsetM: 10)
        let s = nav.snapshot(position: pos, lastProgress: nil, now: start.addingTimeInterval(1_000), pace: PaceEstimator())!

        XCTAssertEqual(s.progress, 20_000, accuracy: 5)
        XCTAssertEqual(s.nextStop?.label, "Déjeuner")
        XCTAssertEqual(s.nextStop!.distance, 20_000, accuracy: 5)
        // 20 km at 20 m/s = 1000 s
        XCTAssertEqual(s.nextStop!.eta.timeIntervalSince(start), 2_000, accuracy: 2)
        // Fuel at 60 km: 2000 s driving + 1 h lunch
        XCTAssertEqual(s.nextFuel!.eta.timeIntervalSince(start), 1_000 + 2_000 + 3_600, accuracy: 2)
        // End: 4000 s driving + lunch + fuel 10 min → exactly on plan
        XCTAssertEqual(s.endOfDay.eta.timeIntervalSince(start), 1_000 + 4_000 + 3_600 + 600, accuracy: 2)
        XCTAssertEqual(s.delay!, 0, accuracy: 2)
        XCTAssertFalse(s.arrivesAfterSunset)
    }

    func testSunsetWarningAndPassedTargets() {
        let route = Fixtures.northLine(km: 50, stepM: 500)
        let nav = NavigationComputer(route: route, segments: [RouteSegment(distance: route.length, routingSpeed: 10, roadClass: .curvy)],
                                     fuelStops: [(name: "Plein", along: 10_000)])
        let now = Date(timeIntervalSince1970: 0)
        let s = nav.snapshot(position: Fixtures.point(onNorthLineAtKm: 30), lastProgress: 29_000, now: now,
                             pace: PaceEstimator(), sunset: now.addingTimeInterval(600))!
        XCTAssertNil(s.nextFuel, "Fuel stop already passed")
        XCTAssertTrue(s.arrivesAfterSunset)   // 20 km at 10 m/s = 2000 s > 600 s
    }
}
