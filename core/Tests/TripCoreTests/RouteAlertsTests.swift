import XCTest
@testable import TripCore

final class RouteAlertsTests: XCTestCase {
    /// Synthetic 5.5 km road north from (43.0, 5.0).
    let track = Polyline((0...50).map { GeoPoint(lat: 43.0 + Double($0) * 0.001, lon: 5.0) })

    func testPackAlertsOnARoute() {
        let guide = FreeRideGuide(alerts: [
            PositionedAlert(point: GeoPoint(lat: 43.02, lon: 5.0002), alert: RoadAlert(along: 0, kind: .speedCamera, label: "radar", maxspeed: 80)),
            PositionedAlert(point: GeoPoint(lat: 43.01, lon: 5.0), alert: RoadAlert(along: 0, kind: .hazard, label: "verglas")),
            PositionedAlert(point: GeoPoint(lat: 43.03, lon: 5.01), alert: RoadAlert(along: 0, kind: .speedCamera, label: "radar")), // 800 m aside
        ])
        let on = guide.along(track)
        XCTAssertEqual(on.map(\.label), ["verglas", "radar"])            // route order, parallel road ignored
        XCTAssertEqual(on[1].along, 2_224, accuracy: 10)
        XCTAssertEqual(on[1].maxspeed, 80)
        XCTAssertNotNil(on[0].point)
    }

    func testMergeKeepsTheRouteAlertsAndAddsFreshOnes() {
        let trip = [RoadAlert(along: 1_000, kind: .speedCamera, label: "radar", maxspeed: 90)]
        let pack = [RoadAlert(along: 1_030, kind: .speedCamera, label: "radar"),          // same camera: duplicate
                    RoadAlert(along: 1_020, kind: .hazard, label: "chutes de pierres"),  // other family: kept
                    RoadAlert(along: 3_000, kind: .speedCamera, label: "radar tronçon")]
        let merged = AlertGuide.merge(trip, with: pack)
        XCTAssertEqual(merged.map(\.along), [1_000, 1_020, 3_000])
        XCTAssertEqual(merged[0].maxspeed, 90)                             // the route's own alert wins
    }

    func testDetourAnnouncesItsAlerts() {
        var route = DetourRoute.road(name: "Hôtel", destination: track.points.last!, points: track.points,
                                     steps: [(text: "", distance: 5_560), (text: "Arrivée", distance: 0)])
        route.alerts = [RoadAlert(along: 3_000, kind: .speedCamera, label: "radar", maxspeed: 50)]
        var g = DetourRoute.Guidance(route: route)
        let u = g.update(position: GeoPoint(lat: 43.0 + 2_550 / 111_195.0, lon: 5.0), speed: 10)   // 450 m before
        XCTAssertTrue(u.announcements.contains { $0.text == "Radar dans 450 mètres, limité à 50" && $0.key.hasPrefix("detour-") })
    }
}
