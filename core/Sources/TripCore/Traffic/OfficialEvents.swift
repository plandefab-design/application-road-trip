import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Live road events from the official open feeds (DATEX II), read by the iPhone itself, no PC:
/// - France, national road network: Bison Futé / DIR (Licence Ouverte);
/// - Spain: DGT incidents (CC BY).
/// Optional while riding like every live source: the app never waits for them.
public enum OfficialEvents {
    public struct Feed: Hashable, Sendable {
        public let source: String
        public let url: URL
        /// The area it covers (minLon, minLat, maxLon, maxLat): not downloaded for a ride elsewhere.
        public let area: (minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)

        public func covers(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) -> Bool {
            minLon <= area.maxLon && maxLon >= area.minLon && minLat <= area.maxLat && maxLat >= area.minLat
        }

        public static func == (a: Feed, b: Feed) -> Bool { a.source == b.source }
        public func hash(into h: inout Hasher) { h.combine(source) }
    }

    public static let feeds = [
        Feed(source: "fr", url: URL(string: "https://tipi.bison-fute.gouv.fr/bison-fute-ouvert/publicationsDIR/Evenementiel-DIR/grt/RRN/content.xml")!,
             area: (-5.5, 41.2, 10.0, 51.2)),
        Feed(source: "es", url: URL(string: "https://nap.dgt.es/datex2/v3/dgt/SituationPublication/datex2_v37.xml")!,
             area: (-18.5, 27.5, 4.6, 44.0)),
    ]

    /// DATEX II sub-type value → category. First match in this order wins: the most dangerous kind describes the event.
    static let categories: [(String, TrafficIncident.Category)] = [
        ("accident", .accident),
        ("vehicleOnFire", .vehicleOnFire), ("forestFire", .fire), ("fire", .fire),
        ("peopleOnRoadway", .pedestrians), ("animalsOnTheRoad", .animals), ("animalPresence", .animals),
        ("rockfalls", .rockfall), ("avalanches", .rockfall), ("landslips", .rockfall), ("mudslide", .rockfall),
        ("subsidence", .badSurface),
        ("objectOnTheRoad", .obstacle), ("shedLoad", .obstacle), ("obstructionOnTheRoad", .obstacle),
        ("spillageOnTheRoad", .obstacle),
        ("flooding", .flooding), ("snowOnTheRoad", .ice), ("iceOnRoad", .ice), ("blackIce", .ice), ("frost", .ice),
        ("fog", .fog), ("denseFog", .fog), ("strongWinds", .wind), ("roadSurfaceInPoorCondition", .badSurface),
        ("brokenDownVehicle", .brokenDownVehicle), ("vehicleStuck", .brokenDownVehicle), ("abandonedVehicle", .brokenDownVehicle),
        ("queuingTraffic", .jam), ("stationaryTraffic", .jam), ("slowTraffic", .jam), ("heavyTraffic", .jam),
        ("roadClosed", .roadClosed), ("carriagewayClosures", .roadClosed), ("closedPermanentlyForTheWinter", .roadClosed),
        ("laneClosures", .laneClosed), ("singleAlternateLineTraffic", .laneClosed), ("narrowLanes", .laneClosed),
        ("contraflow", .laneClosed), ("lanesDeviated", .laneClosed),
        ("roadworks", .roadWorks), ("maintenanceWork", .roadWorks), ("repairWork", .roadWorks), ("resurfacingWork", .roadWorks),
        ("constructionWork", .roadWorks), ("roadMarkingWork", .roadWorks), ("roadsideWork", .roadWorks), ("grassCuttingWork", .roadWorks),
    ]

    /// Current, real events of a DATEX II v2/v3 SituationPublication (tests, exercises and ended events skipped).
    /// Description: « Accident · N85 ».
    public static func parse(_ data: Data, source: String, now: Date = Date()) -> [TrafficIncident] {
        let reader = DatexReader(source: source, now: now)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        _ = parser.parse()
        return reader.events
    }

    /// The events located in a box.
    public static func inBox(_ events: [TrafficIncident], minLon: Double, minLat: Double, maxLon: Double, maxLat: Double)
        -> [TrafficIncident] {
        events.filter { e in
            guard let p = e.geometry.first else { return false }
            return p.lat >= minLat && p.lat <= maxLat && p.lon >= minLon && p.lon <= maxLon
        }
    }
}

/// Streaming DATEX II reader: one situation at a time, its records kept until its status is known.
private final class DatexReader: NSObject, XMLParserDelegate {
    struct Record {
        var id: String?
        var values: Set<String> = []
        var endTime: String?
        var lat: Double?, lon: Double?
        var road: String?
    }

    let source: String
    let now: Date
    private let road = try! NSRegularExpression(pattern: #"^(A|AP|AG|N|RN|D|RD|M|E|C|CV|GI|BI)-?\s?\d{1,4}[a-zA-Z]?$"#)
    private let plainTime = ISO8601DateFormatter()
    private let fractionalTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private(set) var events: [TrafficIncident] = []
    private var status: String?
    private var records: [Record] = []
    private var record: Record?
    private var text = ""
    private var counter = 0

    init(source: String, now: Date) {
        self.source = source
        self.now = now
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "situation":
            status = nil
            records = []
        case "situationRecord":
            record = Record(id: attributes["id"])
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        if name == "informationStatus", status == nil { status = value }
        if record != nil {
            switch name {
            case "situationRecord":
                records.append(record!)
                record = nil
                return
            case "overallEndTime": record!.endTime = value
            case "latitude": if record!.lat == nil { record!.lat = Double(value) }
            case "longitude": if record!.lon == nil { record!.lon = Double(value) }
            case "value", "roadNumber", "roadName":
                if record!.road == nil, isRoad(value) { record!.road = value }
            default: break
            }
            if name.hasSuffix("Type"), !value.isEmpty { record!.values.insert(value) }
        }
        if name == "situation" {
            if (status ?? "real") == "real" { records.forEach(add) }
            records = []
        }
    }

    private func add(_ r: Record) {
        counter += 1
        guard let category = OfficialEvents.categories.first(where: { r.values.contains($0.0) })?.1,
              !ended(r.endTime), let lat = r.lat, let lon = r.lon else { return }
        let label = category.label
        events.append(TrafficIncident(id: "\(source)-\(r.id ?? String(counter))", category: category,
                                      description: r.road.map { "\(label) · \($0)" } ?? label,
                                      geometry: [GeoPoint(lat: lat, lon: lon)]))
    }

    private func isRoad(_ text: String) -> Bool {
        road.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func ended(_ text: String?) -> Bool {
        guard let text, !text.isEmpty, let end = plainTime.date(from: text) ?? fractionalTime.date(from: text) else { return false }
        return end < now
    }
}
