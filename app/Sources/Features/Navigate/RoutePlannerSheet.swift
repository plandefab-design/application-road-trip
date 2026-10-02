import SwiftUI
import TripCore

/// « Itinéraire » of the free ride, like Google Maps: stops in order (add, move, remove), a route type
/// (route sinueuse, sans autoroute, le plus rapide), a preview, then « C'est parti ». Meant for when stopped.
struct RoutePlannerSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var saved = FavoritePlaces.shared
    let location: LocationService
    let onStart: ([FavoritePlaces.Place], RideRouter.Result) -> Void

    struct Stop: Identifiable, Equatable {
        let id = UUID()
        let place: FavoritePlaces.Place
    }

    @State private var stops: [Stop]
    @State private var picking = false
    @State private var computing = false
    @State private var result: RideRouter.Result?
    @State private var error: String?

    /// The PC accepts 12 points: my position and 11 stops; 10 is plenty on a bike.
    static let maxStops = 10

    init(location: LocationService, stops: [FavoritePlaces.Place] = [],
         onStart: @escaping ([FavoritePlaces.Place], RideRouter.Result) -> Void) {
        self.location = location
        self.onStart = onStart
        _stops = State(initialValue: stops.prefix(Self.maxStops).map { Stop(place: $0) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    modePicker
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        .listRowBackground(Color.clear)
                } footer: {
                    Text(settings.rideMode.hint)
                }

                Section {
                    stopRow(icon: "location.fill", tint: Theme.info, title: "Ma position", subtitle: "Départ")
                    ForEach(Array(stops.enumerated()), id: \.element.id) { i, stop in
                        let last = i == stops.count - 1
                        stopRow(icon: last ? "flag.checkered" : "\(i + 1).circle.fill", tint: last ? Theme.accent : Theme.muted,
                                title: stop.place.name, subtitle: last ? "Arrivée" : stop.place.subtitle)
                    }
                    .onMove { stops.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { stops.remove(atOffsets: $0) }
                    if stops.count < Self.maxStops {
                        Button { picking = true } label: {
                            Label(stops.isEmpty ? "Choisir la destination" : "Ajouter une étape", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .frame(minHeight: 44)
                        }
                        .tint(Theme.accent)
                        .listRowBackground(Theme.row)
                    }
                } header: {
                    Text("Étapes")
                } footer: {
                    Text(stops.count > 1 ? "Glisse ≡ pour changer l'ordre. La dernière étape est l'arrivée."
                                         : "Ajoute d'autres étapes pour passer par où tu veux.")
                }

                if stops.isEmpty, !saved.favorites.isEmpty {
                    Section("Favoris") {
                        ForEach(saved.favorites.prefix(6)) { p in
                            Button { stops.append(Stop(place: p)) } label: {
                                Label(p.name, systemImage: "star.fill").lineLimit(1)
                            }
                            .listRowBackground(Theme.row)
                        }
                    }
                }

                if let result { preview(result) }
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(.orange).listRowBackground(Color.clear)
                }
            }
            .environment(\.editMode, .constant(.active))
            .motoList()
            .navigationTitle("Itinéraire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { mainButton }
            .onChange(of: stops) { _, _ in result = nil; error = nil }
            .onChange(of: settings.rideMode) { _, _ in result = nil; error = nil }
            .sheet(isPresented: $picking) {
                PlacePickerView(title: stops.isEmpty ? "Destination" : "Ajouter une étape") { place in
                    guard let p = place.point else { return }
                    stops.append(Stop(place: FavoritePlaces.Place(name: place.name, subtitle: nil, point: p)))
                }
            }
        }
    }

    // MARK: Route type

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(RideMode.allCases) { mode in
                let on = settings.rideMode == mode
                Button { settings.rideMode = mode } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.icon).font(.title2.bold())
                        Text(mode.label).font(.caption.bold()).multilineTextAlignment(.center).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .foregroundStyle(on ? .white : .primary)
                    .background(on ? AnyShapeStyle(Theme.rideGradient) : AnyShapeStyle(Theme.faint),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func stopRow(icon: String, tint: Color, title: String, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3.bold()).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .frame(minHeight: 44)
        .listRowBackground(Theme.row)
    }

    // MARK: Preview and start

    @ViewBuilder private func preview(_ r: RideRouter.Result) -> some View {
        Section("Aperçu") {
            TripMapView(content: MapContent(lines: [.init(id: "plan", points: r.route.track.points, highlighted: true)],
                                            markers: markers(r.route)))
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .listRowInsets(EdgeInsets())
            VStack(alignment: .leading, spacing: 4) {
                Text(summary(r)).font(.title3.bold().monospacedDigit())
                Text(r.note ?? settings.rideMode.label).font(.subheadline)
                    .foregroundStyle(r.note == nil ? Theme.muted : .orange)
            }
            .listRowBackground(Theme.row)
        }
    }

    private func markers(_ route: DetourRoute) -> [MapContent.Marker] {
        var out = route.stops.compactMap { s in
            route.track.point(at: s.along).map { MapContent.Marker(id: "stop-\(s.along)", point: $0, title: "📍 \(s.name)", subtitle: nil) }
        }
        out.append(.init(id: "end", point: route.destination, title: "🏁 \(route.name)", subtitle: nil))
        return out
    }

    private func summary(_ r: RideRouter.Result) -> String {
        let km = "\(Int((r.route.track.length / 1000).rounded())) km"
        guard r.route.isRoad else { return "\(km) à vol d'oiseau" }
        return r.minutes.map { "\(km) · \(Format.duration(minutes: $0))" } ?? km
    }

    private var mainButton: some View {
        Button {
            if let result { start(result) } else { Task { await compute() } }
        } label: {
            HStack(spacing: 10) {
                if computing { ProgressView().tint(.white) }
                Label(result == nil ? (computing ? "Calcul…" : "Calculer l'itinéraire") : "C'est parti",
                      systemImage: result == nil ? "point.topleft.down.to.point.bottomright.curvepath" : "location.north.line.fill")
            }
            .font(.title3.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Theme.rideGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(stops.isEmpty || computing)
        .opacity(stops.isEmpty ? 0.5 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func compute() async {
        error = nil
        guard let here = await location.currentPosition() else {
            error = "Position GPS indisponible."
            return
        }
        computing = true
        result = await RideRouter.route(from: here, through: stops.map(\.place), mode: settings.rideMode, settings: settings)
        computing = false
    }

    private func start(_ r: RideRouter.Result) {
        for s in stops { saved.addRecent(s.place) }
        onStart(stops.map(\.place), r)
        dismiss()
    }
}
