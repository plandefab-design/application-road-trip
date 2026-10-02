import SwiftUI
import TripCore

/// Changes a trip's route on the map: a touch on the map adds a passage (placed in route order), passages can be
/// removed or reordered, then « Recalculer le tracé » has the PC route the day through them (GPX updated).
/// Opened from the trip and from the chat with Claude.
struct RouteEditorView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// Called with the saved trip (the chat keeps working on it).
    let onSaved: (Trip) -> Void

    @State private var draft: Trip
    /// Last saved version: what « Fermer » goes back to.
    @State private var base: Trip
    @State private var dayIndex: Int
    @State private var naming = 0
    @State private var computing = false
    @State private var progress: String?
    @State private var result: String?
    @State private var failed = false
    @State private var confirmClose = false

    static let placeholder = "Point sur la carte"

    init(trip: Trip, day: Int? = nil, onSaved: @escaping (Trip) -> Void = { _ in }) {
        self.onSaved = onSaved
        _draft = State(initialValue: trip)
        _base = State(initialValue: trip)
        _dayIndex = State(initialValue: day.flatMap { d in trip.days.contains { $0.index == d } ? d : nil } ?? trip.days.first?.index ?? 1)
    }

    private var position: Int? { draft.days.firstIndex { $0.index == dayIndex } }
    private var changed: Bool { draft.days.map(\.highlights) != base.days.map(\.highlights) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    TripMapView(content: mapContent, onTap: { add(at: $0) })
                        .id(dayIndex)                    // a new day: the map fits that day again
                    Label(naming > 0 ? "Nom du lieu…" : "Touche la carte pour ajouter un passage", systemImage: "hand.tap.fill")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glass(radius: 18)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
                .frame(height: 330)

                if draft.days.count > 1 { dayChips }
                passages
            }
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationTitle("Modifier le tracé")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { if changed { confirmClose = true } else { dismiss() } }
                        .disabled(computing)
                }
            }
            .confirmationDialog("Passages modifiés, tracé pas encore recalculé", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Enregistrer sans recalculer") {
                    store.save(draft)
                    onSaved(draft)
                    dismiss()
                }
                Button("Abandonner les modifications", role: .destructive) { dismiss() }
                Button("Continuer à modifier", role: .cancel) {}
            }
        }
    }

    // MARK: Map

    private var mapContent: MapContent {
        var c = MapContent.from(trip: draft, highlightDay: dayIndex)
        c.keepCamera = true
        return c
    }

    private func add(at point: GeoPoint) {
        guard let i = position, !computing else { return }
        RouteEdit.addPassage(Self.placeholder, at: point, to: &draft.days[i])
        result = nil
        naming += 1
        Task {
            let name = await Messaging.placeName(point)
            naming -= 1
            // Found again by its position: the rider may have moved it in the meantime.
            for d in draft.days.indices {
                if let h = draft.days[d].highlights.firstIndex(where: { $0.point == point && $0.name == Self.placeholder }) {
                    draft.days[d].highlights[h].name = name.flatMap { $0.isEmpty ? nil : $0 }
                        ?? String(format: "Point %.4f, %.4f", point.lat, point.lon)
                }
            }
        }
    }

    // MARK: Days and passages

    private var dayChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.days) { day in
                    let on = day.index == dayIndex
                    Button { dayIndex = day.index } label: {
                        Text("Jour \(day.index)").font(.subheadline.bold())
                            .padding(.horizontal, 14).frame(minHeight: 38)
                            .foregroundStyle(on ? .white : .primary)
                            .background(on ? AnyShapeStyle(Theme.rideGradient) : AnyShapeStyle(Theme.faint), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var passages: some View {
        List {
            if let i = position {
                let day = draft.days[i]
                Section {
                    if day.highlights.isEmpty {
                        Text("Aucun passage : touche la carte là où tu veux passer.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .listRowBackground(Theme.row)
                    }
                    ForEach(Array(day.highlights.enumerated()), id: \.offset) { n, h in
                        HStack(spacing: 12) {
                            Image(systemName: "\(n + 1).circle.fill").font(.title3).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.name).font(.body.weight(.semibold)).lineLimit(1)
                                if h.point == nil {
                                    Text("Position retrouvée par le PC").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(minHeight: 40)
                        .listRowBackground(Theme.row)
                    }
                    .onDelete { draft.days[i].highlights.remove(atOffsets: $0); result = nil }
                    .onMove { draft.days[i].highlights.move(fromOffsets: $0, toOffset: $1); result = nil }
                } header: {
                    Text("Passages du jour \(day.index)")
                } footer: {
                    Text(footer(day))
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
    }

    private func footer(_ day: TripDay) -> String {
        let original = base.days.first { $0.index == day.index }
        let importedTrack = original.map { $0.highlights.isEmpty && $0.track != nil } ?? false
        return (importedTrack ? "Le tracé importé (GPX) sera remplacé par une route calculée passant par ces points. " : "")
            + "Le départ et l'arrivée de l'étape ne changent pas. Glisse ≡ pour changer l'ordre."
    }

    // MARK: Recompute

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if computing {
                ProgressView(progress ?? "Calcul de la route…").font(.caption)
            } else if let result {
                Text(result).font(.caption).foregroundStyle(failed ? .orange : Theme.ok).lineLimit(3)
            }
            Button {
                if changed { Task { await recompute() } } else { dismiss() }
            } label: {
                Label(changed ? "Recalculer le tracé" : "Terminer",
                      systemImage: changed ? "point.topleft.down.to.point.bottomright.curvepath" : "checkmark")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Theme.rideGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(computing || naming > 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func recompute() async {
        computing = true
        defer { computing = false; progress = nil }
        store.save(draft)                     // the passages are kept even if the PC does not answer
        onSaved(draft)
        let outcome = await TripRouting.finalize(draft, settings: settings) { progress = $0 }
        failed = !outcome.ok
        if let routed = outcome.trip {
            store.save(routed)
            onSaved(routed)
            draft = routed
            base = routed
            let km = routed.days.first { $0.index == dayIndex }?.distanceKm.map { " · jour \(dayIndex) : \(Int($0.rounded())) km" } ?? ""
            result = "Tracé recalculé ✓\(km)"
                + outcome.message.components(separatedBy: "\n\n").filter { $0.hasPrefix("⛽") }.prefix(1).map { "\n\($0)" }.joined()
        } else {
            result = outcome.message          // passages saved; « Recalculer » stays available to try again
        }
    }
}
