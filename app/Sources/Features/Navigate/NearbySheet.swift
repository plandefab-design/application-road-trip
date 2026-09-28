import SwiftUI
import TripCore

/// Round floating button over the riding map (recentre, search), glove-sized.
struct MapRoundButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 54, height: 54)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                .shadow(radius: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Top banner content during a detour: next turn, or direction and distance when offline.
struct DetourBanner: View {
    let name: String
    let update: DetourRoute.Guidance.Update?

    var body: some View {
        if let turn = update?.nextTurn {
            Image(systemName: NavigationView.symbol(for: turn.instruction.maneuver)).font(.system(size: 44, weight: .bold))
            VStack(alignment: .leading) {
                Text(Format.distance(turn.distance)).font(.title.bold())
                Text(turn.instruction.text).font(.title3).lineLimit(2).minimumScaleFactor(0.7)
                Text("Vers \(name)").font(.caption).foregroundStyle(.cyan)
            }
        } else {
            Image(systemName: update?.bearing == nil ? "mappin.and.ellipse" : "location.north.fill")
                .font(.system(size: 44, weight: .bold))
                .rotationEffect(.degrees(update?.bearing ?? 0))
            VStack(alignment: .leading) {
                Text(name).font(.title3.bold()).lineLimit(1)
                Text(update.map { Format.distance($0.remaining) } ?? "…").font(.title.bold())
                if update?.bearing != nil { Text("À vol d'oiseau (pas de réseau)").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

/// « Autour de moi » while riding: fuel, hotels, restaurants, cafés nearby; one tap = guided there.
/// Big targets (gloves), no text input.
struct NearbySheet: View {
    @Environment(\.dismiss) private var dismiss
    let location: LocationService
    let trip: Trip?
    let onPick: (DetourRoute) -> Void

    @State private var category: NearbySearch.Category = .fuel
    @State private var places: [NearbySearch.Place] = []
    @State private var online = true
    @State private var loading = false
    @State private var routing: String?
    @State private var here: GeoPoint?
    @State private var center = NearbySearch.Center.here
    @State private var typedCenters: [NearbySearch.Center] = []
    @State private var typing = false
    @State private var cityText = ""
    @State private var locating = false
    @State private var cityError: String?

    private var centers: [NearbySearch.Center] {
        [.here] + typedCenters + NearbySearch.tripCenters(trip).filter { c in !typedCenters.contains { $0.name == c.name } }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                centerBar
                HStack(spacing: 8) {
                    ForEach(NearbySearch.Category.allCases) { c in
                        Button { category = c } label: {
                            VStack(spacing: 4) {
                                Image(systemName: c.icon).font(.title2)
                                Text(c.label).font(.caption.bold())
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .foregroundStyle(category == c ? .white : .primary)
                            .background(category == c ? Color.orange : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)

                if !online {
                    Label("Pas de réseau : adresses connues du trip, direction à vol d'oiseau.", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal)
                }

                if loading {
                    Spacer(); ProgressView("Recherche…"); Spacer()
                } else if places.isEmpty {
                    Spacer()
                    ContentUnavailableView("Rien trouvé", systemImage: category.icon,
                                           description: Text(online ? "Aucun résultat dans 15 km." : "Pas de réseau et rien de ce type dans le trip."))
                    Spacer()
                } else {
                    List(places) { place in
                        Button { Task { await go(to: place) } } label: { row(place) }
                            .disabled(routing != nil)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(center.point == nil ? "Autour de moi" : "Autour de \(center.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fermer") { dismiss() } }
            .keyboardDoneButton()
            .overlay {
                if let routing {
                    ProgressView("Itinéraire vers \(routing)…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .task(id: "\(category.rawValue)|\(center.name)") { await load() }
        }
    }

    /// « Autour de » : my position, a place of the trip (one tap) or any town typed by the rider (when stopped).
    private var centerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(centers) { c in
                        Button { center = c; typing = false } label: {
                            Label(c.name, systemImage: c.point == nil ? "location.fill" : "mappin")
                                .font(.subheadline.bold()).lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .foregroundStyle(center == c ? .white : .primary)
                                .background(center == c ? Color.blue : Color.secondary.opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Button { typing.toggle() } label: {
                        Label("Autre ville…", systemImage: "magnifyingglass")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
            if typing {
                HStack {
                    TextField("Ville ou adresse (à l'arrêt)", text: $cityText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { Task { await locateCity() } }
                    Button(locating ? "…" : "Chercher") { Task { await locateCity() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(cityText.trimmingCharacters(in: .whitespaces).isEmpty || locating)
                }
                .padding(.horizontal)
                if let cityError { Text(cityError).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
            }
        }
    }

    private func locateCity() async {
        locating = true
        defer { locating = false }
        cityError = nil
        guard let found = await NearbySearch.locate(cityText) else {
            cityError = "Ville introuvable (ou pas de réseau)."
            return
        }
        typedCenters.removeAll { $0.name == found.name }
        typedCenters.insert(found, at: 0)
        center = found
        typing = false
        cityText = ""
    }

    private func row(_ place: NearbySearch.Place) -> some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon).foregroundStyle(.orange).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.headline).lineLimit(1)
                if let a = place.address { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(Format.distance(place.distance)).font(.subheadline.bold().monospacedDigit())
                if center.point != nil { Text("du centre").font(.caption2).foregroundStyle(.secondary) }
            }
            Image(systemName: "arrow.triangle.turn.up.right.circle.fill").font(.title2).foregroundStyle(.blue)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if here == nil { here = await location.currentPosition() }
        guard let around = center.point ?? here else { places = []; return }
        let result = await NearbySearch.search(category, around: around, trip: trip)
        places = result.places
        online = result.online
    }

    private func go(to place: NearbySearch.Place) async {
        guard let from = await location.currentPosition() ?? here else { return }
        routing = place.name
        let route = await NearbySearch.route(to: place, from: from)
        routing = nil
        onPick(route)
        dismiss()
    }
}
