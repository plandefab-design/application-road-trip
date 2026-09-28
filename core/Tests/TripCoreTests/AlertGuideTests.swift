import XCTest
@testable import TripCore

final class AlertGuideTests: XCTestCase {
    // Fixture alerts (synthetic positions).
    let alerts = [
        RoadAlert(along: 1_000, kind: .speedCamera, label: "radar", maxspeed: 80),
        RoadAlert(along: 1_200, kind: .hazard, label: "chutes de pierres"),
        RoadAlert(along: 5_000, kind: .redLightCamera, label: "radar feu rouge"),
    ]

    func testCameraAnnouncedAt500m() {
        XCTAssertEqual(AlertGuide.announcements(alerts, progress: 400, cameras: true), [])      // 600 m ahead
        XCTAssertEqual(AlertGuide.announcements(alerts, progress: 500, cameras: true),
                       [.init(key: "alert-0", text: "Radar dans 500 mètres, limité à 80", urgent: true)])
    }

    func testHazardBehindACameraIsNotMasked() {
        // 900 m: camera 100 m ahead (second warning) and hazard 300 m ahead are both due.
        let due = AlertGuide.announcements(alerts, progress: 900, cameras: true)
        XCTAssertEqual(due.map(\.key), ["alert-0-near", "alert-1"])
        XCTAssertEqual(due[0].text, "Radar maintenant, limité à 80")
        XCTAssertEqual(due[1].text, "Attention, chutes de pierres dans 300 mètres")
    }

    func testCamerasCanBeMuted() {
        XCTAssertEqual(AlertGuide.announcements(alerts, progress: 500, cameras: false), [])
        XCTAssertEqual(AlertGuide.next(alerts, progress: 0, cameras: false)?.index, 1)
        XCTAssertEqual(AlertGuide.announcements(alerts, progress: 4_600, cameras: true).first?.text,
                       "Radar feu rouge dans 400 mètres")
    }

    /// Invariant: riding the whole track, every alert is announced exactly once, in order, within its lead.
    func testEachAlertAnnouncedOnceWithinLead() {
        for step in [5.0, 25, 40] {
            var spoken: [String] = []
            var progress = 0.0
            while progress < 6_000 {
                for a in AlertGuide.announcements(alerts, progress: progress, cameras: true) where !spoken.contains(a.key) {
                    let near = a.key.hasSuffix("-near")
                    let i = Int(a.key.dropFirst("alert-".count).split(separator: "-")[0])!
                    let lead = near ? FreeRideGuide.nearCamera : AlertGuide.lead(for: alerts[i].kind)
                    XCTAssertLessThanOrEqual(alerts[i].along - progress, lead)
                    XCTAssertGreaterThan(alerts[i].along - progress, lead - step - 1)
                    spoken.append(a.key)
                }
                progress += step
            }
            XCTAssertEqual(spoken, ["alert-0", "alert-0-near", "alert-1", "alert-2", "alert-2-near"], "step \(step)")
        }
    }

    func testAlertsRoundTripAndUnknownKind() throws {
        let json = """
        {"schemaVersion": 2, "id": "t1", "name": "Mini",
         "params": {"start": {"name": "A"}, "dateStart": "2027-06-01", "dateEnd": "2027-06-01"},
         "days": [{"index": 1, "alerts": [{"along": 10, "kind": "laser", "label": "?"},
                                          {"along": 20, "kind": "speedCamera", "label": "radar", "maxspeed": 90}]}]}
        """
        let trip = try TripCodec.decode(Data(json.utf8))
        XCTAssertEqual(trip.schemaVersion, Trip.currentSchemaVersion)
        XCTAssertEqual(trip.days[0].alerts.map(\.kind), [.hazard, .speedCamera])
        XCTAssertEqual(try TripCodec.decode(TripCodec.encode(trip)).days[0].alerts, trip.days[0].alerts)
    }

    func testRelocatedFixesDriftedDistances() {
        let track = Fixtures.northLine(km: 10)
        let camera = RoadAlert(along: 7_000, kind: .speedCamera, label: "radar",
                               point: Fixtures.point(onNorthLineAtKm: 5, eastOffsetM: 10))   // really at 5 km
        let noPoint = RoadAlert(along: 3_000, kind: .hazard, label: "danger")
        let elsewhere = RoadAlert(along: 8_000, kind: .hazard, label: "ailleurs",
                                  point: Fixtures.point(onNorthLineAtKm: 8, eastOffsetM: 500))
        let out = AlertGuide.relocated([camera, noPoint, elsewhere], on: track)
        XCTAssertEqual(out.map(\.label), ["danger", "radar", "ailleurs"])
        XCTAssertEqual(out[1].along, 5_000, accuracy: 5)
        XCTAssertEqual(out[2].along, 8_000)
    }
}
