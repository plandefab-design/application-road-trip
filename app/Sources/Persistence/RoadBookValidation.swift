import Foundation
import TripCore

/// Which content of each trip the rider validated (fingerprint + date), kept on the iPhone. A trip changed after
/// its validation (chat, recomputed route, parameters) is no longer validated: the PDF waits for a new validation.
@MainActor
final class RoadBookValidation: ObservableObject {
    static let shared = RoadBookValidation()

    struct Record: Codable, Equatable {
        let fingerprint: String
        let date: Date
    }

    @Published private(set) var records: [String: Record] = [:]
    private let key = "roadBookValidations"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved
        }
    }

    /// Validation date when the trip's current content is the validated one.
    func validatedAt(_ trip: Trip) -> Date? {
        guard let r = records[trip.id], r.fingerprint == RoadBook.fingerprint(trip) else { return nil }
        return r.date
    }

    /// Validated once, then changed.
    func isOutdated(_ trip: Trip) -> Bool {
        records[trip.id] != nil && validatedAt(trip) == nil
    }

    func validate(_ trip: Trip) {
        records[trip.id] = Record(fingerprint: RoadBook.fingerprint(trip), date: Date())
        save()
    }

    func revoke(_ tripId: String) {
        records[tripId] = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }
}
