import XCTest
@testable import TripCore

/// Bison Futé and DGT feeds read on the iPhone. Synthetic snippets in the shape of the two feeds (no real event).
final class OfficialEventsTests: XCTestCase {
    let v2 = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>
    <d2LogicalModel xmlns:ns2="http://datex2.eu/schema/2/2_0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <ns2:payloadPublication>
     <ns2:situation id="s1"><ns2:headerInformation><ns2:informationStatus>real</ns2:informationStatus></ns2:headerInformation>
      <ns2:situationRecord xsi:type="ns2:Accident" id="r1">
       <ns2:accidentType>accident</ns2:accidentType>
       <ns2:groupOfLocations><ns2:point><ns2:pointCoordinates><ns2:latitude>44.1</ns2:latitude><ns2:longitude>6.1</ns2:longitude></ns2:pointCoordinates>
        <ns2:name><ns2:descriptor><ns2:values><ns2:value lang="fr">Village</ns2:value></ns2:values></ns2:descriptor></ns2:name>
        <ns2:name><ns2:descriptor><ns2:values><ns2:value lang="fr">N85</ns2:value></ns2:values></ns2:descriptor></ns2:name>
       </ns2:point></ns2:groupOfLocations>
      </ns2:situationRecord>
      <ns2:situationRecord xsi:type="ns2:MaintenanceWorks" id="r2">
       <ns2:validity><ns2:validityTimeSpecification><ns2:overallEndTime>2020-01-01T00:00:00+01:00</ns2:overallEndTime></ns2:validityTimeSpecification></ns2:validity>
       <ns2:roadMaintenanceType>roadworks</ns2:roadMaintenanceType>
       <ns2:latitude>44.2</ns2:latitude><ns2:longitude>6.2</ns2:longitude>
      </ns2:situationRecord>
      <ns2:situationRecord xsi:type="ns2:ReroutingManagement" id="r3">
       <ns2:reroutingManagementType>followDiversionSigns</ns2:reroutingManagementType>
       <ns2:latitude>44.3</ns2:latitude><ns2:longitude>6.3</ns2:longitude>
      </ns2:situationRecord>
     </ns2:situation>
     <ns2:situation id="s2"><ns2:headerInformation><ns2:informationStatus>test</ns2:informationStatus></ns2:headerInformation>
      <ns2:situationRecord id="r4"><ns2:accidentType>accident</ns2:accidentType>
       <ns2:latitude>44.4</ns2:latitude><ns2:longitude>6.4</ns2:longitude></ns2:situationRecord>
     </ns2:situation>
    </ns2:payloadPublication></d2LogicalModel></soap:Body></soap:Envelope>
    """.utf8)

    let v3 = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <d2:payload xmlns:d2="http://levelC/schema/3/d2Payload" xmlns:sit="http://levelC/schema/3/situation"
     xmlns:com="http://levelC/schema/3/common" xmlns:loc="http://levelC/schema/3/locationReferencing">
     <sit:situation id="9"><sit:headerInformation><com:informationStatus>real</com:informationStatus></sit:headerInformation>
      <sit:situationRecord id="9_1">
       <sit:cause><sit:causeType>vehicleObstruction</sit:causeType><sit:vehicleObstructionType>vehicleOnFire</sit:vehicleObstructionType></sit:cause>
       <sit:abnormalTrafficType>slowTraffic</sit:abnormalTrafficType>
       <loc:roadName>A-7</loc:roadName>
       <loc:latitude>40.5</loc:latitude><loc:longitude>-3.5</loc:longitude>
      </sit:situationRecord>
     </sit:situation>
    </d2:payload>
    """.utf8)

    let now = ISO8601DateFormatter().date(from: "2026-09-28T00:00:00Z")!

    func testV2RealCurrentDangersOnly() {
        // r2 ended, r3 is not a danger (diversion message), s2 is a test situation.
        XCTAssertEqual(OfficialEvents.parse(v2, source: "fr", now: now), [
            TrafficIncident(id: "fr-r1", category: .accident, description: "Accident · N85", geometry: [GeoPoint(lat: 44.1, lon: 6.1)]),
        ])
    }

    func testV3MostDangerousKindWins() {
        XCTAssertEqual(OfficialEvents.parse(v3, source: "es", now: now), [
            TrafficIncident(id: "es-9_1", category: .vehicleOnFire, description: "Véhicule en feu · A-7",
                            geometry: [GeoPoint(lat: 40.5, lon: -3.5)]),
        ])
    }

    func testBoxAndCoverage() {
        let events = OfficialEvents.parse(v2, source: "fr", now: now) + OfficialEvents.parse(v3, source: "es", now: now)
        XCTAssertEqual(OfficialEvents.inBox(events, minLon: 6.0, minLat: 44.0, maxLon: 6.5, maxLat: 44.5).map(\.id), ["fr-r1"])
        XCTAssertEqual(OfficialEvents.inBox(events, minLon: 0, minLat: 0, maxLon: 1, maxLat: 1), [])
        // Riding around Gap: only the French feed is downloaded.
        let around = OfficialEvents.feeds.filter { $0.covers(minLon: 5.9, minLat: 44.4, maxLon: 6.2, maxLat: 44.7) }
        XCTAssertEqual(around.map(\.source), ["fr"])
        XCTAssertEqual(OfficialEvents.feeds.filter { $0.covers(minLon: 1.5, minLat: 42.3, maxLon: 1.9, maxLat: 42.6) }.map(\.source),
                       ["fr", "es"])                                                     // Pyrenees: both
    }

    func testUnreadableFeedGivesNothing() {
        XCTAssertEqual(OfficialEvents.parse(Data("<html>Service indisponible".utf8), source: "fr", now: now), [])
    }
}
