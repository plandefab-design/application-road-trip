import Foundation
import TripCore

/// Maintenance books of the garage bikes (Documents/maintenance.json), separate from trips.
@MainActor
final class MaintenanceStore: ObservableObject {
    @Published private(set) var books: [String: MaintenanceBook] = [:]
    private let file: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = docs.appendingPathComponent("maintenance.json")
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: MaintenanceBook].self, from: data) {
            books = decoded
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Book of a bike, created with the standard items the first time, and completed with the standard items added
    /// since (the rider's intervals, history and own items are kept).
    func book(for bike: Bike) -> MaintenanceBook {
        let today = ISODate.format(Date())
        let current = books[bike.id] ?? MaintenanceBook.starter(bikeId: bike.id, category: bike.category, today: today)
        let completed = current.completed(category: bike.category, today: today)
        if books[bike.id] != completed {
            books[bike.id] = completed
            persist()
        }
        return completed
    }

    func update(_ book: MaintenanceBook) {
        books[book.bikeId] = book
        persist()
    }

    /// Adds a ride to a bike's odometer. Returns the items that just became « soon » or worse (to notify).
    @discardableResult
    func addRide(bikeId: String, km: Double) -> [(item: MaintenanceItem, status: MaintenanceBook.Status)] {
        guard var b = books[bikeId] else { return [] }
        let before = Dictionary(uniqueKeysWithValues: b.items.map { ($0.id, b.status(of: $0).level) })
        b.addRide(km: km)
        update(b)
        return b.attention().filter { (before[$0.item.id] ?? .ok) < $0.status.level }
    }

    func removeBooks(notIn bikeIds: Set<String>) {
        let stale = books.keys.filter { !bikeIds.contains($0) }
        guard !stale.isEmpty else { return }
        stale.forEach { books[$0] = nil }
        persist()
    }
}
