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

    /// Book of a bike, created with starting items the first time.
    func book(for bike: Bike) -> MaintenanceBook {
        if let b = books[bike.id] { return b }
        let b = MaintenanceBook.starter(bikeId: bike.id, category: bike.category, today: ISODate.format(Date()))
        books[bike.id] = b
        persist()
        return b
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

    /// Most urgent item of the whole garage, for the home screen.
    func mostUrgent(garage: [Bike]) -> (bike: Bike, item: MaintenanceItem, status: MaintenanceBook.Status)? {
        garage.compactMap { bike -> (Bike, MaintenanceItem, MaintenanceBook.Status)? in
            guard let first = books[bike.id]?.attention().first else { return nil }
            return (bike, first.item, first.status)
        }
        .max { $0.2.level < $1.2.level }
        .map { (bike: $0.0, item: $0.1, status: $0.2) }
    }
}
