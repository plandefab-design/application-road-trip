import SwiftUI
import TripCore

/// Guided form covering the 13 parameters of the project brief (SPEC §4.2 step 1).
/// Drop-downs and sliders only, except the trip name and free constraints.
struct CreateTripView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings

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
    @State private var style = 0.3
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
                    ForEach(settings.garage) { bike in
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

                Section("Rythme et budget") {
                    VStack(alignment: .leading) {
                        Text("Km/jour max : \(Int(maxKmPerDay))")
                        Slider(value: $maxKmPerDay, in: 100...500, step: 10)
                    }
                    VStack(alignment: .leading) {
                        Text("Style : \(style < 0.34 ? "conduite pure" : style < 0.67 ? "équilibré" : "contemplatif")")
                        Slider(value: $style, in: 0...1)
                    }
                    Stepper("Budget : \(Int(budget)) €/jour", value: $budget, in: 50...600, step: 10)
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

                Section {
                    Button("Vérifier la cohérence") { questions = ConsistencyChecker.check(params, cols: Catalog.cols()) }
                    Button("Continuer avec Claude") { startPlanning() }
                        .disabled(name.isEmpty || startName.isEmpty)
                        .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Nouveau trip")
            .navigationDestination(item: $draft) { trip in
                PlannerChatView(trip: trip)
            }
            .onAppear { maxKmPerDay = settings.defaultKmPerDay }
        }
    }

    private var dayCount: Int {
        max(1, (Calendar.current.dateComponents([.day], from: dateStart, to: dateEnd).day ?? 0) + 1)
    }

    private var params: TripParams {
        TripParams(start: Place(name: startName),
                   end: loop ? nil : Place(name: endName),
                   dateStart: ISODate.format(dateStart), dateEnd: ISODate.format(dateEnd),
                   zone: Array(zones).sorted(),
                   bikes: settings.garage.filter { bikeIds.contains($0.id) },
                   riders: riders, luggage: luggage, maxKmPerDay: maxKmPerDay, style: style,
                   budgetPerDayEur: budget, constraints: constraints, roads: roads)
    }

    private func startPlanning() {
        questions = ConsistencyChecker.check(params, cols: Catalog.cols())
        let trip = Trip(name: name, status: .draft, params: params)
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
