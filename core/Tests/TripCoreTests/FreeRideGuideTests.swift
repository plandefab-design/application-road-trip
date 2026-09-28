import XCTest
@testable import TripCore

final class FreeRideGuideTests: XCTestCase {
    // Synthetic alerts on a road going due north from (43.0, 5.0); 0.001° of latitude ≈ 111 m.
    let pack = AlertPack(version: "1", cameras: [
        [.number(43.004), .number(5.0), .number(80), .number(0)],       // on the road, ≈ 445 m ahead
        [.number(43.004), .number(5.002), .number(90), .number(0)],     // ≈ 160 m to the east: parallel road
        [.number(42.997), .number(5.0), .null, .number(0)],             // behind the rider
        [.number(43.010), .number(5.0), .null, .number(1)],             // red-light camera further on
        [.text("bad")],                                                  // malformed: skipped
    ], hazards: [
        [.number(43.0025), .number(5.0), .text("chutes de pierres")],   // ≈ 278 m ahead
    ])

    func testPackDecoding() throws {
        XCTAssertEqual(pack.alerts.count, 5)
        let json = #"{"version":"7","cameras":[[43.1,5.2,null,0]],"hazards":[[43.2,5.3,"verglas"]]}"#
        let decoded = try JSONDecoder().decode(AlertPack.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.alerts.map(\.alert.kind), [.speedCamera, .hazard])
        XCTAssertNil(decoded.alerts[0].alert.maxspeed)
        XCTAssertEqual(decoded.alerts[1].alert.label, "verglas")
    }

    func testOnlyAlertsAheadInTheCorridor() {
        let guide = FreeRideGuide(alerts: pack.alerts)
        let here = GeoPoint(lat: 43.0, lon: 5.0)
        let ahead = guide.ahead(of: here, heading: 0)
        XCTAssertEqual(ahead.map(\.alert.kind), [.hazard, .speedCamera])   // parallel road and camera behind ignored
        XCTAssertEqual(ahead[1].distance, 445, accuracy: 5)
        XCTAssertTrue(guide.ahead(of: here, heading: 180).map(\.alert.maxspeed).contains(nil))  // riding south: the one behind
        XCTAssertTrue(guide.ahead(of: here, heading: nil).isEmpty)                             // stopped: no heading
    }

    func testAnnouncements() {
        let guide = FreeRideGuide(alerts: pack.alerts)
        let texts = guide.announcements(position: GeoPoint(lat: 43.0, lon: 5.0), heading: 0, cameras: true).map(\.text)
        XCTAssertEqual(texts, ["Attention, chutes de pierres dans 300 mètres", "Radar dans 450 mètres, limité à 80"])
        XCTAssertEqual(guide.announcements(position: GeoPoint(lat: 43.0, lon: 5.0), heading: 0, cameras: false).count, 1)
        let near = guide.announcements(position: GeoPoint(lat: 43.003, lon: 5.0), heading: 2, cameras: true)
        XCTAssertTrue(near.contains { $0.text == "Radar maintenant, limité à 80" && $0.key.hasSuffix("-near") })
    }

    /// Invariant: riding north along the road, each alert ahead is announced once per phase, never one behind.
    func testRideAlongAnnouncesEachOnce() {
        let guide = FreeRideGuide(alerts: pack.alerts)
        var spoken: [String] = []
        var lat = 42.999
        while lat < 43.012 {
            for a in guide.announcements(position: GeoPoint(lat: lat, lon: 5.0), heading: 0, cameras: true) where !spoken.contains(a.key) {
                spoken.append(a.key)
            }
            lat += 0.0002   // ≈ 22 m per fix
        }
        XCTAssertEqual(spoken.filter { !$0.hasSuffix("-near") }.count, 3)   // hazard, camera, red-light camera
        XCTAssertEqual(spoken.filter { $0.hasSuffix("-near") }.count, 2)
        XCTAssertFalse(spoken.contains("free-1") || spoken.contains("free-2"))  // parallel road, camera behind
    }
}
