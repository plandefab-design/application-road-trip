import Foundation

public struct GPXWaypoint: Equatable, Sendable {
    public var point: GeoPoint
    public var name: String?
    public var type: String?
    public init(point: GeoPoint, name: String? = nil, type: String? = nil) {
        self.point = point
        self.name = name
        self.type = type
    }
}

public struct GPXDocument: Equatable, Sendable {
    /// One polyline per <trk> (all <trkseg> concatenated) and per <rte>.
    public var tracks: [Polyline]
    public var trackNames: [String?]
    public var waypoints: [GPXWaypoint]
    public init(tracks: [Polyline] = [], trackNames: [String?] = [], waypoints: [GPXWaypoint] = []) {
        self.tracks = tracks
        self.trackNames = trackNames
        self.waypoints = waypoints
    }
}

public enum GPXError: Error, Equatable {
    case empty
    case invalidCoordinate
}

/// Dependency-free GPX 1.1 reader/writer (no XMLParser → identical behaviour on iOS, Linux, Windows).
public enum GPX {

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> GPXDocument {
        guard let text = String(data: data, encoding: .utf8) else { throw GPXError.empty }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> GPXDocument {
        var doc = GPXDocument()
        var current: [GeoPoint] = []
        var currentName: String?
        var inTrackOrRoute = false
        var pendingPoint: GeoPoint?
        var pendingKind: String?     // "trkpt" | "rtept" | "wpt"
        var pendingName: String?
        var pendingType: String?
        var captureTag: String?      // "ele" | "name" | "type"
        var captured = ""

        func flushPoint() {
            guard let p = pendingPoint, let kind = pendingKind else { return }
            if kind == "wpt" {
                doc.waypoints.append(GPXWaypoint(point: p, name: pendingName, type: pendingType))
            } else {
                current.append(p)
            }
            pendingPoint = nil
            pendingKind = nil
        }

        var scanner = TagScanner(text)
        while let token = scanner.next() {
            switch token {
            case .text(let t):
                if captureTag != nil { captured += t }
            case .open(let name, let attrs, let selfClosing):
                switch name {
                case "trk", "rte":
                    inTrackOrRoute = true
                    current = []
                    currentName = nil
                case "trkpt", "rtept", "wpt":
                    guard let lat = attrs["lat"].flatMap({ Double($0) }), let lon = attrs["lon"].flatMap({ Double($0) }) else {
                        throw GPXError.invalidCoordinate
                    }
                    let p = GeoPoint(lat: lat, lon: lon)
                    guard p.isValid else { throw GPXError.invalidCoordinate }
                    pendingPoint = p
                    pendingKind = name
                    pendingName = nil
                    pendingType = nil
                    if selfClosing { flushPoint() }
                case "ele", "name", "type":
                    if !selfClosing { captureTag = name; captured = "" }
                default:
                    break
                }
            case .close(let name):
                switch name {
                case "ele", "name", "type":
                    let value = decodeEntities(captured.trimmingCharacters(in: .whitespacesAndNewlines))
                    if name == "ele", pendingPoint != nil { pendingPoint?.ele = Double(value) }
                    if name == "name" {
                        if pendingPoint != nil { pendingName = value } else if inTrackOrRoute { currentName = value }
                    }
                    if name == "type", pendingPoint != nil { pendingType = value }
                    captureTag = nil
                    captured = ""
                case "trkpt", "rtept", "wpt":
                    flushPoint()
                case "trk", "rte":
                    if current.count > 1 {
                        doc.tracks.append(Polyline(current))
                        doc.trackNames.append(currentName)
                    }
                    inTrackOrRoute = false
                    current = []
                default:
                    break
                }
            }
        }

        if doc.tracks.isEmpty && doc.waypoints.isEmpty { throw GPXError.empty }
        return doc
    }

    // MARK: Writing

    public static func write(name: String, tracks: [(name: String, line: Polyline)], waypoints: [GPXWaypoint]) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="MotoTrip" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(escape(name))</name></metadata>

        """
        for w in waypoints {
            s += "  <wpt lat=\"\(fmt(w.point.lat))\" lon=\"\(fmt(w.point.lon))\">"
            if let e = w.point.ele { s += "<ele>\(fmtEle(e))</ele>" }
            if let n = w.name { s += "<name>\(escape(n))</name>" }
            if let t = w.type { s += "<type>\(escape(t))</type>" }
            s += "</wpt>\n"
        }
        for t in tracks {
            s += "  <trk><name>\(escape(t.name))</name><trkseg>\n"
            for p in t.line.points {
                s += "    <trkpt lat=\"\(fmt(p.lat))\" lon=\"\(fmt(p.lon))\">"
                if let e = p.ele { s += "<ele>\(fmtEle(e))</ele>" }
                s += "</trkpt>\n"
            }
            s += "  </trkseg></trk>\n"
        }
        s += "</gpx>\n"
        return s
    }

    /// Trip → GPX: one track per day + waypoints for selected stops, fuel stops and highlights.
    public static func write(trip: Trip) -> String {
        var tracks: [(String, Polyline)] = []
        var wpts: [GPXWaypoint] = []
        for day in trip.days {
            if let t = day.track, !t.isEmpty { tracks.append(("Jour \(day.index)", t)) }
            for f in day.fuelStops { wpts.append(GPXWaypoint(point: f.point, name: "⛽ \(f.name)", type: "fuel")) }
            for h in day.highlights { if let p = h.point { wpts.append(GPXWaypoint(point: p, name: h.name, type: h.type.rawValue)) } }
            for poi in trip.selectedStops(for: day) {
                if let p = poi.point { wpts.append(GPXWaypoint(point: p, name: poi.name, type: poi.type.rawValue)) }
            }
        }
        return write(name: trip.name, tracks: tracks.map { (name: $0.0, line: $0.1) }, waypoints: wpts)
    }

    static func fmt(_ v: Double) -> String { String(format: "%.6f", v) }
    static func fmtEle(_ v: Double) -> String { String(format: "%.1f", v) }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Minimal XML tokenizer (enough for GPX)

struct TagScanner {
    enum Token {
        case open(name: String, attrs: [String: String], selfClosing: Bool)
        case close(name: String)
        case text(String)
    }

    private let chars: [Character]
    private var i = 0

    init(_ text: String) { chars = Array(text) }

    mutating func next() -> Token? {
        guard i < chars.count else { return nil }
        if chars[i] != "<" {
            let start = i
            while i < chars.count && chars[i] != "<" { i += 1 }
            return .text(String(chars[start..<i]))
        }
        // Comments, CDATA, processing instructions, doctype
        if match("<!--") { skip(until: "-->"); return next() }
        if match("<![CDATA[") {
            i += 9
            let start = i
            skip(until: "]]>")
            let end = max(start, i - 3)
            return .text(String(chars[start..<end]))
        }
        if match("<?") || match("<!") { skip(until: ">"); return next() }

        i += 1 // '<'
        if i < chars.count && chars[i] == "/" {
            i += 1
            let name = readName()
            skip(until: ">")
            return .close(name: name)
        }
        let name = readName()
        var attrs: [String: String] = [:]
        var selfClosing = false
        while i < chars.count {
            skipSpaces()
            guard i < chars.count else { break }
            if chars[i] == "/" { selfClosing = true; i += 1; continue }
            if chars[i] == ">" { i += 1; break }
            let key = readName()
            skipSpaces()
            if i < chars.count && chars[i] == "=" {
                i += 1
                skipSpaces()
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    let start = i
                    while i < chars.count && chars[i] != quote { i += 1 }
                    attrs[key] = String(chars[start..<min(i, chars.count)])
                    i += 1
                }
            } else if key.isEmpty {
                i += 1 // unexpected char, avoid infinite loop
            }
        }
        return .open(name: name, attrs: attrs, selfClosing: selfClosing)
    }

    /// Local name without namespace prefix (gpx:trkpt → trkpt).
    private mutating func readName() -> String {
        let start = i
        while i < chars.count, !chars[i].isWhitespace, chars[i] != ">", chars[i] != "/", chars[i] != "=" { i += 1 }
        let raw = String(chars[start..<i])
        if let colon = raw.lastIndex(of: ":") { return String(raw[raw.index(after: colon)...]) }
        return raw
    }

    private mutating func skipSpaces() {
        while i < chars.count && chars[i].isWhitespace { i += 1 }
    }

    private func match(_ s: String) -> Bool {
        let a = Array(s)
        guard i + a.count <= chars.count else { return false }
        return Array(chars[i..<(i + a.count)]) == a
    }

    private mutating func skip(until s: String) {
        let a = Array(s)
        while i < chars.count {
            if i + a.count <= chars.count && Array(chars[i..<(i + a.count)]) == a { i += a.count; return }
            i += 1
        }
    }
}
