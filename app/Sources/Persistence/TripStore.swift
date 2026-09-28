import Foundation
import TripCore

/// Local persistence: one JSON file per trip in Documents/trips (visible in the Files app).
@MainActor
final class TripStore: ObservableObject {
    @Published private(set) var trips: [Trip] = []
    @Published var lastError: String?

    private let folder: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("trips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        trips = files.filter { $0.pathExtension == "json" }
            .compactMap { try? TripCodec.decode(Data(contentsOf: $0)) }
            .sorted { $0.params.dateStart > $1.params.dateStart }
    }

    func save(_ trip: Trip) {
        do {
            let data = try TripCodec.encode(trip)
            try data.write(to: fileURL(trip.id), options: .atomic)
            if let i = trips.firstIndex(where: { $0.id == trip.id }) { trips[i] = trip } else { trips.insert(trip, at: 0) }
        } catch {
            lastError = "Enregistrement impossible : \(error.localizedDescription)"
        }
    }

    func delete(_ trip: Trip) {
        try? FileManager.default.removeItem(at: fileURL(trip.id))
        ChatHistory.delete(trip.id)
        trips.removeAll { $0.id == trip.id }
    }

    func fileURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    /// Imports a trip.json (from the Claude project / companion) or a GPX (one day per track).
    func importFile(at url: URL) {
        do {
            let data = try Self.readImported(url)
            switch url.pathExtension.lowercased() {
            case "json":
                save(try TripCodec.decode(data))
            case "gpx":
                save(try Self.trip(fromGPX: data, name: url.deletingPathExtension().lastPathComponent))
            default:
                lastError = "Format non pris en charge : .\(url.pathExtension)"
            }
        } catch {
            lastError = "Import impossible (\(url.lastPathComponent)) : \(Self.describe(error))"
        }
    }

    /// Reads a file picked in Files or received via "Ouvrir avec".
    /// Coordinated read: files stored in iCloud Drive or another provider are downloaded before reading.
    static func readImported(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// French message with the technical code, so an import failure can be diagnosed from a screenshot.
    static func describe(_ error: Error) -> String {
        switch error {
        case GPXError.empty:
            return "le GPX ne contient ni trace ni point."
        case GPXError.invalidCoordinate:
            return "le GPX contient une coordonnée invalide."
        case TripCodecError.unsupportedSchemaVersion(let v):
            return "trip.json en version \(v), trop récente pour cette version de l'app."
        case let decoding as DecodingError:
            return "ce n'est pas un trip.json valide (\(decoding))."
        default:
            let ns = error as NSError
            var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                text += " ← [\(underlying.domain) \(underlying.code)]"
            }
            return text
        }
    }

    /// GPX → draft trip. Waypoints are imported as unverified POIs (no source).
    static func trip(fromGPX data: Data, name: String) throws -> Trip {
        let doc = try GPX.parse(data)
        let today = ISODate.format(Date())
        let days: [TripDay] = doc.tracks.enumerated().map { i, line in
            TripDay(index: i + 1,
                    distanceKm: (line.length / 1000).rounded(),
                    curvinessScore: Curvature.score(line).rounded(),
                    ascentM: line.ascent.rounded(),
                    track: line)
        }
        let pois: [POI] = doc.waypoints.map { w in
            POI(type: POIType(rawValue: w.type ?? "") ?? .viewpoint, name: w.name ?? "Point", point: w.point)
        }
        let start = doc.tracks.first?.points.first
        let params = TripParams(start: Place(name: "Départ", point: start),
                                dateStart: today,
                                dateEnd: ISODate.format(Date().addingTimeInterval(Double(max(days.count - 1, 0)) * 86_400)))
        return Trip(name: name, status: .proposed, params: params, days: days, pois: pois)
    }
}
