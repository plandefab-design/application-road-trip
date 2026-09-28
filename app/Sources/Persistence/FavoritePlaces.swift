import Foundation
import TripCore

/// Favourite and recent destinations (« Aller à une adresse »), kept on the iPhone (UserDefaults).
@MainActor
final class FavoritePlaces: ObservableObject {
    static let shared = FavoritePlaces()

    struct Place: Codable, Identifiable, Equatable, Hashable {
        var id: String { "\(name)|\(Int(lat * 1e5))|\(Int(lon * 1e5))" }
        let name: String
        let subtitle: String?
        let lat: Double
        let lon: Double
        var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }

        init(name: String, subtitle: String?, point: GeoPoint) {
            self.name = name
            self.subtitle = subtitle
            self.lat = point.lat
            self.lon = point.lon
        }
    }

    @Published private(set) var favorites: [Place] = []
    @Published private(set) var recents: [Place] = []
    private let defaults = UserDefaults.standard
    static let maxRecents = 8

    init() {
        favorites = load("favoritePlaces")
        recents = load("recentPlaces")
    }

    private func load(_ key: String) -> [Place] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Place].self, from: data)) ?? []
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(favorites) { defaults.set(d, forKey: "favoritePlaces") }
        if let d = try? JSONEncoder().encode(recents) { defaults.set(d, forKey: "recentPlaces") }
    }

    func isFavorite(_ p: Place) -> Bool { favorites.contains { $0.id == p.id } }

    func toggleFavorite(_ p: Place) {
        if isFavorite(p) { favorites.removeAll { $0.id == p.id } } else { favorites.insert(p, at: 0) }
        persist()
    }

    func removeFavorite(_ p: Place) {
        favorites.removeAll { $0.id == p.id }
        persist()
    }

    /// Latest destination first, no duplicates, at most 8.
    func addRecent(_ p: Place) {
        recents.removeAll { $0.id == p.id }
        recents.insert(p, at: 0)
        recents = Array(recents.prefix(Self.maxRecents))
        persist()
    }
}
