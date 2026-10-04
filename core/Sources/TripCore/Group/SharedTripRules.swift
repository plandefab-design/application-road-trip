import Foundation

/// What changes in a trip when it travels from one rider to another.
public enum SharedTripRules {
    /// The server accepts files up to 20 MB (the bucket limit).
    public static let maxFileBytes = 20 * 1024 * 1024

    /// Days and kilometres shown on the share card.
    public static func summary(of trip: Trip) -> (days: Int, distanceKm: Double) {
        (trip.days.count, trip.days.reduce(0) { $0 + ($1.distanceKm ?? 0) })
    }

    /// The copy a friend adds to his own trips: a new identity (so it never overwrites or syncs onto anyone's trip),
    /// no claim about offline files he does not have, a status that asks him to check and download the maps, and
    /// an unticked checklist (the ticks were the sender's).
    public static func prepareForImport(_ trip: Trip) -> Trip {
        var copy = trip
        copy.id = UUID().uuidString
        copy.updatedAt = nil
        copy.offlinePack = OfflinePack()
        if copy.status == .ready || copy.status == .active || copy.status == .done { copy.status = .validated }
        copy.checklist = copy.checklist.map { item in
            var fresh = item
            fresh.done = false
            return fresh
        }
        return copy
    }
}
