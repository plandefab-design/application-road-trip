from datetime import datetime, timezone

from app.live_events import in_box, parse_datex

# Synthetic snippets in the shape of the two feeds (no real event).
V2 = b"""<?xml version="1.0" encoding="UTF-8"?>
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
</ns2:payloadPublication></d2LogicalModel></soap:Body></soap:Envelope>"""

V3 = b"""<?xml version="1.0" encoding="UTF-8"?>
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
</d2:payload>"""

NOW = datetime(2026, 9, 28, tzinfo=timezone.utc)


def test_v2_real_current_events_only():
    events = parse_datex(V2, "fr", NOW)
    # r2 ended, r3 is not a danger (diversion message), s2 is a test situation.
    assert events == [{"id": "fr-r1", "lat": 44.1, "lon": 6.1, "cat": 1, "label": "Accident", "road": "N85"}]


def test_v3_most_dangerous_kind_wins():
    events = parse_datex(V3, "es", NOW)
    assert [(e["id"], e["cat"], e["label"], e["road"]) for e in events] == [("es-9_1", 23, "Véhicule en feu", "A-7")]


def test_in_box_uses_the_tomtom_shape():
    events = parse_datex(V2, "fr", NOW) + parse_datex(V3, "es", NOW)
    box = in_box(6.0, 44.0, 6.5, 44.5, events)
    assert box == {"incidents": [{
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [6.1, 44.1]},
        "properties": {"id": "fr-r1", "iconCategory": 1, "events": [{"description": "Accident · N85"}]},
    }]}
    assert in_box(0, 0, 1, 1, events) == {"incidents": []}
