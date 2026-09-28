import SwiftUI
import TripCore

/// Guided form covering the 13 parameters of the project brief (SPEC §4.2 step 1).
/// Drop-downs and sliders only, except the trip name and free constraints.
/// With `editing`, the same form edits an existing trip's parameters (days, POIs and checklist are kept).
struct CreateTripView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var editing: Trip? = nil
    @State private var loaded = false
    @State private var status: TripStatus = .draft

    @State private var name = ""
    @State private var startName = ""
    @State private var endName = ""
    @State private var loop = true
    @State private var dateStart = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var dateEnd = Calendar.current.date(byAdding: .day, value: 33, to: Date()) ?? Date()
    @State private var zones: Set<String> = []
    @State private var bikeIds: Set<String> = []
    @State private var riders: Riders = .solo
    @State private var luggage = false
    @State private var maxKmPerDay = 300.0
    @State private var tripStyle: TripStyle = .kiff
    @State private var level: RiderLevel = .confirme
    @State private var budget = 150.0
    @State private var constraints = ""
    @State private var roads = RoadPreferences()

    @State private var questions: [ConsistencyQuestion] = []
    @State private var draft: Trip?

    private let regions = Catalog.regions()

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Nom court (ex. Aix-Stelvio)", text: $name)
                    TextField("Départ (ville)", text: $startName)
                    Toggle("Boucle (retour au départ)", isOn: $loop)
                    if !loop { TextField("Arrivée (ville)", text: $endName) }
                }

                Section("Période") {
                    DatePicker("Départ", selection: $dateStart, displayedComponents: .date)
                    DatePicker("Retour", selection: $dateEnd, in: dateStart..., displayedComponents: .date)
                    Text("Durée : \(dayCount) jour(s)").foregroundStyle(.secondary)
                }

                Section("Zone") {
                    NavigationLink {
                        MultiPicker(title: "Zones", items: regions.map { (id: $0.id, label: "\($0.name) (\($0.country))") }, selection: $zones)
                    } label: {
                        LabeledContent("Zones", value: zones.isEmpty ? "Choisir" : "\(zones.count) sélectionnée(s)")
                    }
                }

                Section("Moto(s) et pilote(s)") {
                    if settings.garage.isEmpty {
                        Text("Ajoute tes motos dans Réglages › Garage (l'autonomie réelle est nécessaire pour placer les pleins).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(availableBikes) { bike in
                        Toggle(isOn: Binding(get: { bikeIds.contains(bike.id) },
                                             set: { on in if on { bikeIds.insert(bike.id) } else { bikeIds.remove(bike.id) } })) {
                            Text("\(bike.model) — \(Int(bike.rangeKm)) km")
                        }
                    }
                    Picker("Pilotes", selection: $riders) {
                        Text("Solo").tag(Riders.solo)
                        Text("Duo").tag(Riders.duo)
                    }
                    Toggle("Bagagerie (sacoches)", isOn: $luggage)
                }

                Section {
                    Picker("Envie", selection: $tripStyle) {
                        ForEach(TripStyle.allCases, id: \.self) { Text($0.label.components(separatedBy: " ").first ?? $0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(tripStyleHint).font(.footnote).foregroundStyle(.secondary)
                    Picker("Niveau", selection: $level) {
                        ForEach(RiderLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Km/jour max : \(Int(maxKmPerDay))")
                        Slider(value: $maxKmPerDay, in: 100...500, step: 10)
                    }
                    Stepper("Budget : \(Int(budget)) €/jour", value: $budget, in: 50...600, step: 10)
                } header: {
                    Text("Envie, niveau et budget")
                }

                Section("Routes") {
                    Toggle("Exclure autoroutes", isOn: $roads.avoidMotorway)
                    Toggle("Exclure voies rapides / nationales rectilignes", isOn: $roads.avoidTrunk)
                    Stepper("Sinuosité : \(roads.curvinessLevel)/5", value: $roads.curvinessLevel, in: 1...5)
                }

                Section("Contraintes particulières") {
                    TextField("Ex. éviter tel col, passage obligé…", text: $constraints, axis: .vertical)
                        .lineLimit(2...5)
                }

                if !questions.isEmpty {
                    Section("À clarifier avant de continuer") {
                        ForEach(questions, id: \.code) { q in
                            Label(q.message, systemImage: "questionmark.circle").foregroundStyle(.orange)
                        }
                    }
                }

                if editing != nil {
                    Section("Statut") {
                        Picker("Statut", selection: $status) {
                            ForEach(TripStatus.allCases, id: \.self) { Text(StatusBadge.label(for: $0)).tag($0) }
                        }
                    }
                }

                Section {
                    Button("Vérifier la cohérence") { questions = ConsistencyChecker.check(params, cols: Catalog.cols()) }
                    if editing != nil {
                        Button("Enregistrer les modifications") {
                            store.save(updatedTrip)
                            dismiss()
                        }
                        .disabled(name.isEmpty || startName.isEmpty)
                    }
                    Button("Continuer avec Claude") { startPlanning() }
                        .disabled(name.isEmpty || startName.isEmpty)
                        .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle(editing == nil ? "Nouveau trip" : "Modifier le trip")
            .keyboardDoneButton()
            .toolbar {
                if editing != nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                }
            }
            .navigationDestination(item: $draft) { trip in
                PlannerChatView(trip: trip)
            }
            .onAppear(perform: loadOnce)
        }
    }

    /// Garage bikes, plus bikes stored in the edited trip that are no longer in the garage.
    private var availableBikes: [Bike] {
        let extra = (editing?.params.bikes ?? []).filter { b in !settings.garage.contains { $0.id == b.id } }
        return settings.garage + extra
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        guard let trip = editing else {
            maxKmPerDay = settings.defaultKmPerDay
            return
        }
        let p = trip.params
        name = trip.name
        status = trip.status
        startName = p.start.name
        loop = p.end == nil
        endName = p.end?.name ?? ""
        if let d = ISODate.parse(p.dateStart) { dateStart = d }
        if let d = ISODate.parse(p.dateEnd) { dateEnd = max(d, dateStart) }
        zones = Set(p.zone)
        bikeIds = Set(p.bikes.map(\.id))
        riders = p.riders
        luggage = p.luggage
        maxKmPerDay = p.maxKmPerDay
        tripStyle = p.tripStyle ?? (p.style >= 0.8 ? .tourisme : p.style >= 0.5 ? .balade : .kiff)
        level = p.level ?? .confirme
        budget = p.budgetPerDayEur ?? budget
        constraints = p.constraints
        roads = p.roads
    }

    /// Edited trip: new parameters, everything else (days, POIs, checklist, pack) unchanged.
    private var updatedTrip: Trip {
        guard var trip = editing else { return Trip(name: name, status: .draft, params: params) }
        let old = trip.params
        var p = params
        // Keep the fields the form does not show, and known start/end coordinates when the town is unchanged.
        p.mandatoryStops = old.mandatoryStops
        p.maxFuelIntervalKm = old.maxFuelIntervalKm
        if p.start.name == old.start.name { p.start = old.start }
        if let end = p.end, end.name == old.end?.name { p.end = old.end }
        trip.name = name
        trip.status = status
        trip.params = p
        return trip
    }

    private var dayCount: Int {
        max(1, (Calendar.current.dateComponents([.day], from: dateStart, to: dateEnd).day ?? 0) + 1)
    }

    private var params: TripParams {
        TripParams(start: Place(name: startName),
                   end: loop ? nil : Place(name: endName),
                   dateStart: ISODate.format(dateStart), dateEnd: ISODate.format(dateEnd),
                   zone: Array(zones).sorted(),
                   bikes: availableBikes.filter { bikeIds.contains($0.id) },
                   riders: riders, luggage: luggage, maxKmPerDay: maxKmPerDay, style: tripStyle.styleValue,
                   budgetPerDayEur: budget, constraints: constraints, roads: roads,
                   tripStyle: tripStyle, level: level)
    }

    private var tripStyleHint: String {
        switch tripStyle {
        case .kiff: "Virages, cols, enchaînements : le plaisir de pilotage avant tout."
        case .balade: "Rythme tranquille, beaux paysages, étapes courtes et pauses."
        case .rapide: "Relier vite et bien, peu de détours (voies rapides acceptées sauf exclusion)."
        case .tourisme: "Villages, sites, gastronomie : les visites comptent autant que la route."
        }
    }

    private func startPlanning() {
        questions = ConsistencyChecker.check(params, cols: Catalog.cols())
        let trip = updatedTrip
        store.save(trip)
        draft = trip
    }
}

/// Simple multi-selection list (zones).
struct MultiPicker: View {
    let title: String
    let items: [(id: String, label: String)]
    @Binding var selection: Set<String>

    var body: some View {
        List(items, id: \.id) { item in
            Button {
                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            } label: {
                HStack {
                    Text(item.label).foregroundStyle(.primary)
                    Spacer()
                    if selection.contains(item.id) { Image(systemName: "checkmark").foregroundStyle(.orange) }
                }
            }
        }
        .navigationTitle(title)
    }
}
