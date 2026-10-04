import Foundation

// MARK: - JSON I/O

public enum TripCodec {
    public static func decode(_ data: Data) throws -> Trip {
        let trip = try JSONDecoder().decode(Trip.self, from: data)
        guard trip.schemaVersion <= Trip.currentSchemaVersion else {
            throw TripCodecError.unsupportedSchemaVersion(trip.schemaVersion)
        }
        var sanitized = trip
        sanitized.schemaVersion = Trip.currentSchemaVersion   // v1…v8 → v9: only optional fields were added
        sanitized.pois = trip.pois.map { $0.sanitized() }
        return sanitized
    }

    public static func encode(_ trip: Trip) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]      // compact: half the size of an indented file
        return try encoder.encode(trip)
    }
}

public enum TripCodecError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}
