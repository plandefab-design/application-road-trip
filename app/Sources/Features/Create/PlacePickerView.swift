import SwiftUI
import TripCore

/// Picks a real place for a trip (start, drop-off point, mandatory stop): an address with live suggestions,
/// my position, a favourite or recent place, or a point chosen on the map under a centre pin.
struct PlacePickerView: View {
    let title: String
    let onPick: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = AddressCompleter()
    @StateObject private var location = LocationService()
    @ObservedObject private var saved = FavoritePlaces.shared
    @State private var text = ""
    @State private var here: GeoPoint?
    @State private var onMap = false
    @State private var mapCenter: GeoPoint?
    /// Where the map opens (set once: the map must stay free to move under the pin).
    @State private var mapStart: GeoPoint?
    @State private var mapName: String?
    @State private var naming: Task<Void, Never>?
    @State private var busy = false
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Group {
                if onMap { mapPicker } else { searchList }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                if onMap {
                    ToolbarItem(placement: .primaryAction) { Button("Liste") { onMap = false } }
                }
            }
            .task {
                location.requestPermissions()
                location.warmUp()
                here = await location.currentPosition(maxAge: 600)
            }
        }
    }

    // MARK: Search

    private var searchList: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.accent)
                TextField("Ville, adresse, col, lieu…", text: $text)
                    .focused($typing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !text.isEmpty {
                    Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .glass(radius: 27)
            .padding(.horizontal, 16)
            .onChange(of: text) { _, t in completer.update(t, near: here) }

            List {
                if text.isEmpty {
                    Section {
                        row("Ma position", subtitle: here == nil ? "Recherche du GPS…" : "Là où tu es", icon: "location.fill", tint: Theme.info) {
                            Task { await pickHere() }
                        }
                        .disabled(here == nil)
                        row("Choisir sur la carte", subtitle: "Place le repère sur le point voulu", icon: "map.fill", tint: Theme.accent) {
                            typing = false
                            mapStart = here ?? GeoPoint(lat: 43.64, lon: 5.10)
                            mapCenter = mapStart
                            onMap = true
                        }
                    }
                }
                if !completer.suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(completer.suggestions) { s in
                            row(s.title, subtitle: s.subtitle.isEmpty ? nil : s.subtitle, icon: "mappin.circle.fill", tint: Theme.accent) {
                                Task {
                                    busy = true
                                    if let p = await completer.resolve(s) { pick(p.name, p.point) }
                                    busy = false
                                }
                            }
                        }
                    }
                }
                if text.isEmpty && !saved.favorites.isEmpty {
                    Section("Favoris") {
                        ForEach(saved.favorites) { p in
                            row(p.name, subtitle: p.subtitle, icon: "star.fill", tint: .yellow) { pick(p.name, p.point) }
                        }
                    }
                }
                if text.isEmpty && !saved.recents.isEmpty {
                    Section("Récents") {
                        ForEach(saved.recents) { p in
                            row(p.name, subtitle: p.subtitle, icon: "clock.arrow.circlepath", tint: Theme.muted) { pick(p.name, p.point) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay { if busy { ProgressView().controlSize(.large) } }
        }
        .padding(.top, 8)
    }

    private func row(_ title: String, subtitle: String?, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconBadge(icon: icon, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .frame(minHeight: 44)
        }
        .listRowBackground(Theme.row)
    }

    // MARK: Map with a centre pin

    private var mapPicker: some View {
        ZStack {
            TripMapView(content: MapContent(focus: mapStart)) { center in
                mapCenter = center
                naming?.cancel()
                naming = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    mapName = await Messaging.placeName(center)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            Image(systemName: "mappin")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.accent)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .offset(y: -20)
                .allowsHitTesting(false)
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text(mapName ?? "Déplace la carte sous le repère").font(.headline).lineLimit(2)
                    Button {
                        if let c = mapCenter { pick(mapName ?? String(format: "Point %.4f, %.4f", c.lat, c.lon), c) }
                    } label: {
                        Label("Choisir ce point", systemImage: "checkmark.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .disabled(mapCenter == nil)
                }
                .padding(16)
                .glass(radius: 24)
                .padding(16)
            }
        }
    }

    // MARK: Pick

    private func pickHere() async {
        guard let p = here else { return }
        busy = true
        let name = await Messaging.placeName(p) ?? "Ma position"
        busy = false
        pick(name, p)
    }

    private func pick(_ name: String, _ point: GeoPoint) {
        FavoritePlaces.shared.addRecent(FavoritePlaces.Place(name: name, subtitle: nil, point: point))
        onPick(Place(name: name, point: point))
        dismiss()
    }
}

/// Rounded-square coloured icon used in menus and lists (Réglages, création de trip).
struct IconBadge: View {
    let icon: String
    var tint: Color = Theme.accent

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
