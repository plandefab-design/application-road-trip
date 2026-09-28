import Foundation
import MapKit
import TripCore

/// Address suggestions while typing, like a classic GPS (Apple's completer, biased around the rider).
/// Needs the network; without it the list simply stays empty and favourites / recents remain usable.
@MainActor
final class AddressCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let subtitle: String
        fileprivate let completion: MKLocalSearchCompletion

        static func == (a: Suggestion, b: Suggestion) -> Bool { a.id == b.id }
    }

    @Published private(set) var suggestions: [Suggestion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// New text typed; `near` biases the suggestions (≈ 100 km around the rider).
    func update(_ text: String, near: GeoPoint?) {
        if let near {
            completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: near.lat, longitude: near.lon),
                                                  latitudinalMeters: 200_000, longitudinalMeters: 200_000)
        }
        let q = text.trimmingCharacters(in: .whitespaces)
        if q.count < 2 { suggestions = []; completer.cancel(); return }
        completer.queryFragment = q
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items = completer.results.prefix(8).map { ($0.title, $0.subtitle, $0) }
        Task { @MainActor in
            self.suggestions = items.map { Suggestion(title: $0.0, subtitle: $0.1, completion: $0.2) }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }

    /// Coordinates of a picked suggestion (5 s).
    func resolve(_ s: Suggestion) async -> FavoritePlaces.Place? {
        let completion = s.completion
        let task = Task { () -> FavoritePlaces.Place? in
            let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
            guard let item = response?.mapItems.first else { return nil }
            let c = item.placemark.coordinate
            return FavoritePlaces.Place(name: s.title, subtitle: s.subtitle.isEmpty ? nil : s.subtitle,
                                        point: GeoPoint(lat: c.latitude, lon: c.longitude))
        }
        let timeout = Task { try? await Task.sleep(for: .seconds(5)); task.cancel() }
        let result = await task.value
        timeout.cancel()
        return result
    }
}
