import XCTest
@testable import TripCore

final class TrafficIncidentsTests: XCTestCase {
    // Synthetic straight road going north, 0.001° steps (≈ 111 m) over ≈ 22 km.
    let route = Polyline((0...200).map { GeoPoint(lat: 43.0 + Double($0) * 0.001, lon: 5.0) })

    func testParseTomTomV5Response() throws {
        // Shape of the documented Incident Details v5 response (values are fixtures).
        let json = """
        {"incidents": [
          {"type": "Feature",
           "properties": {"id": "a1", "iconCategory": 1, "delay": 420, "events": [{"description": "Accident", "code": 201}]},
           "geometry": {"type": "LineString", "coordinates": [[5.0, 43.05], [5.0, 43.051]]}},
          {"type": "Feature", "properties": {"iconCategory": 99},
           "geometry": {"type": "Point", "coordinates": [5.0, 43.1]}},
          null
        ]}
        """
        let incidents = try TrafficIncidents.parse(Data(json.utf8))
        XCTAssertEqual(incidents.count, 2)
        XCTAssertEqual(incidents[0].category, .accident)
        XCTAssertEqual(incidents[0].delay, 420)
        XCTAssertEqual(incidents[0].geometry.count, 2)
        XCTAssertEqual(incidents[1].category, .unknown)
        XCTAssertEqual(incidents[1].id, "incident-1")
    }

    func testOnlyIncidentsOnTheRouteAheadAreKept() {
        let onRoute = TrafficIncident(id: "on", category: .roadWorks, geometry: [GeoPoint(lat: 43.05, lon: 5.0)])
        let otherRoad = TrafficIncident(id: "off", category: .jam, geometry: [GeoPoint(lat: 43.05, lon: 5.01)])  // ~800 m aside
        let behind = TrafficIncident(id: "behind", category: .accident, geometry: [GeoPoint(lat: 43.01, lon: 5.0)])
        let ahead = TrafficIncidents.ahead([otherRoad, behind, onRoute], route: route, progress: 2_000)
        XCTAssertEqual(ahead.map(\.incident.id), ["on"])
        XCTAssertEqual(ahead[0].along, 5_560, accuracy: 30)
    }

    func testAnnouncementsFarThenNear() {
        let incident = TrafficIncident(id: "x", category: .accident, delay: 600, geometry: [])
        let item = IncidentAhead(incident: incident, along: 10_000)
        XCTAssertEqual(TrafficIncidents.announcements([item], progress: 0),
                       [.init(key: "traffic-x-far", text: "Accident dans 10 kilomètres, 10 minutes de retard")])
        XCTAssertEqual(TrafficIncidents.announcements([item], progress: 9_200).first?.key, "traffic-x-near")
    }

    func testBoundingBoxRespectsTheApiLimit() throws {
        let box = try XCTUnwrap(TrafficIncidents.boundingBox(route: route, progress: 0))
        XCTAssertLessThan(box.minLat, 43.0)
        XCTAssertGreaterThan(box.maxLat, 43.2)
        // A diagonal 400 km line would exceed 10 000 km²: the look-ahead is shortened.
        let long = Polyline((0...400).map { GeoPoint(lat: 43.0 + Double($0) * 0.01, lon: 1.0 + Double($0) * 0.01) })
        let b = try XCTUnwrap(TrafficIncidents.boundingBox(route: long, progress: 0, horizon: 400_000))
        let area = (b.maxLat - b.minLat) * 111.2 * (b.maxLon - b.minLon) * 111.2 * cos((b.minLat + b.maxLat) / 2 * .pi / 180)
        XCTAssertLessThanOrEqual(area, TrafficIncidents.maxBoxArea)
    }

    func testBoxesCoverTheWholeRoute() {
        // Synthetic 111 km road north.
        let road = Polyline((0...100).map { GeoPoint(lat: 43.0 + Double($0) * 0.01, lon: 5.0) })
        let boxes = TrafficIncidents.boxes(route: road)
        XCTAssertEqual(boxes.count, 3)                                   // 50 + 50 + 11 km
        XCTAssertLessThan(boxes.first!.minLat, 43.0)
        XCTAssertGreaterThan(boxes.last!.maxLat, 44.0)
        XCTAssertEqual(TrafficIncidents.boxes(route: road, from: 100_000).count, 1)
        XCTAssertEqual(TrafficIncidents.boxes(route: road, from: 0, length: 60_000).count, 2)
    }

    func testFarWarningOnlyWithin20kmAndNeverForRoadworks() {
        let far = IncidentAhead(incident: TrafficIncident(id: "a", category: .accident, geometry: []), along: 30_000)
        let works = IncidentAhead(incident: TrafficIncident(id: "w", category: .roadWorks, geometry: []), along: 5_000)
        XCTAssertTrue(TrafficIncidents.announcements([far, works], progress: 0).isEmpty)
        let near = TrafficIncidents.announcements([works], progress: 4_200)
        XCTAssertEqual(near.map(\.key), ["traffic-w-near"])
        XCTAssertFalse(near[0].urgent)                       // roadworks never cut a camera warning
    }

    func testNearDangerIsUrgentAndBurstIsLimited() {
        let items = (0..<5).map { i in
            IncidentAhead(incident: TrafficIncident(id: "o\(i)", category: .obstacle, geometry: []), along: Double(2_000 + i * 1_000))
        }
        let said = TrafficIncidents.announcements(items, progress: 1_500)
        XCTAssertEqual(said.map(\.key), ["traffic-o0-near", "traffic-o1-far"])
        XCTAssertTrue(said[0].urgent)
        XCTAssertEqual(said[0].text, "Obstacle sur la route dans 500 mètres")
    }

    func testMergedDropsTheSameEventFromAnotherSource() {
        let tomtom = TrafficIncident(id: "tt", category: .accident, geometry: [GeoPoint(lat: 44.0, lon: 6.0)])
        let official = TrafficIncident(id: "fr-1", category: .accident, geometry: [GeoPoint(lat: 44.002, lon: 6.0)])  // ~220 m
        let other = TrafficIncident(id: "fr-2", category: .jam, geometry: [GeoPoint(lat: 44.002, lon: 6.0)])
        XCTAssertEqual(TrafficIncidents.merged([[tomtom], [official, other, other]]).map(\.id), ["tt", "fr-2"])
    }

    func testCameraAndTurnNowAreUrgent() {
        let camera = RoadAlert(along: 400, kind: .speedCamera, label: "radar")
        XCTAssertTrue(AlertGuide.announcements([camera], progress: 0).allSatisfy(\.urgent))
        let turn = TurnInstruction(along: 50, maneuver: .turnLeft, text: "Tournez à gauche")
        XCTAssertEqual(TurnGuide.announcement([turn], progress: 30, speed: 5)?.urgent, true)     // 20 m: the order
        XCTAssertEqual(TurnGuide.announcement([turn], progress: -150, speed: 5)?.urgent, false)  // 200 m: preparation
    }

    func testFreeRideAnnouncesOnlyIncidentsAheadWithin1km() {
        let here = Fixtures.point(onNorthLineAtKm: 0)
        let ahead = TrafficIncident(id: "a", category: .accident, geometry: [Fixtures.point(onNorthLineAtKm: 0.6)])
        let behind = TrafficIncident(id: "b", category: .jam, geometry: [Fixtures.point(onNorthLineAtKm: -0.5)])
        let tooFar = TrafficIncident(id: "c", category: .obstacle, geometry: [Fixtures.point(onNorthLineAtKm: 3)])
        let said = TrafficIncidents.announcementsAhead([behind, ahead, tooFar], position: here, heading: 0)
        XCTAssertEqual(said, [.init(key: "traffic-a-near", text: "Accident dans 600 mètres", urgent: true)])
        XCTAssertTrue(TrafficIncidents.announcementsAhead([ahead], position: here, heading: nil).isEmpty)   // stopped
    }
}
