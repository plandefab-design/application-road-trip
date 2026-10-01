import SwiftUI
import TripCore

/// New road trip, step by step (SPEC §4.2 step 1: successive questions, no free-text block):
/// where (start, drop-off point or loop, mandatory stops: real addresses or map points), when, bike, style,
/// last details, then a summary and « Continuer avec Claude ». With `editing`, the same steps edit a trip's
/// parameters (days, places, checklist are kept).
struct CreateTripView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var editing: Trip? = nil
    @State private var loaded = false
    @State private var step = 0
    @State private var status: TripStatus = .draft

    @State private var name = ""
    @State private var start: Place?
    @State private var end: Place?
    @State private var loop = false
    @State private var stops: [Place] = []
    @State private var keptZones: [String] = []
    @State private var dateStart = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var dateEnd = Calendar.current.date(byAdding: .day, value: 32, to: Date()) ?? Date()
    @State private var bikeIds: Set<String> = []
    @State private var riders: Riders = .solo
    @State private var luggage = false
    @State private var maxKmPerDay = 300.0
    @State private var tripStyle: TripStyle = .kiff
    @State private var level: RiderLevel = .confirme
    @State private var budget = 150.0
    @State private var constraints = ""
    @State private var roads = RoadPreferences()

    @State private var picking: Target?
    @State private var questions: [ConsistencyQuestion] = []
    @State private var draft: Trip?

    enum Target: String, Identifiable {
        case start, end, stop
        var id: String { rawValue }
        var title: String {
            switch self {
            case .start: "Départ"
            case .end: "Point de chute"
            case .stop: "Passage obligatoire"
            }
        }
    }

    private static let steps: [(title: String, subtitle: String, icon: String)] = [
        ("Où tu vas ?", "Départ, point de chute et passages obligés : de vraies adresses ou des points sur la carte.", "map.fill"),
        ("Quand ?", "Les dates et ce que tu veux rouler par jour.", "calendar"),
        ("Ta moto", "Avec qui et sur quoi : l'autonomie place les pleins.", "gauge.with.dots.needle.67percent"),
        ("Ton style", "Ce que tu veux ressentir, et ton niveau.", "flame.fill"),
        ("Derniers détails", "Budget et ce que Claude doit savoir.", "slider.horizontal.3"),
        ("C'est parti ?", "Vérifie, puis Claude prépare le road trip.", "checkmark.seal.fill"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Self.steps[step].title).font(.system(size: 32, weight: .black, design: .rounded))
                            Text(Self.steps[step].subtitle).font(.subheadline).foregroundStyle(Theme.muted)
                        }
                        .padding(.top, 8)
                        switch step {
                        case 0: whereStep
                        case 1: whenStep
                        case 2: bikeStep
                        case 3: styleStep
                        case 4: detailsStep
                        default: summaryStep
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                bottomBar
            }
            .foregroundStyle(.white)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(editing == nil ? "Nouveau trip" : "Modifier le trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.carbon, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                if editing != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Enregistrer") { store.save(updatedTrip); dismiss() }.disabled(start == nil)
                    }
                }
            }
            .sheet(item: $picking) { target in
                PlacePickerView(title: target.title) { place in
                    switch target {
                    case .start: start = place
                    case .end: end = place; loop = false
                    case .stop: stops.append(place)
                    }
                }
            }
            .navigationDestination(item: $draft) { PlannerChatView(trip: $0) }
            .onAppear(perform: loadOnce)
        }
    }

    // MARK: Progress and navigation

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Self.steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? AnyShapeStyle(Theme.rideGradient) : AnyShapeStyle(Color.white.opacity(0.15)))
                    .frame(height: 5)
                    .onTapGesture { if editing != nil || i < step { step = i } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.2), value: step)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if step > 0 {
                Button { withAnimation { step -= 1 } } label: {
                    Label("Retour", systemImage: "chevron.left").font(.headline).frame(minWidth: 96, minHeight: 54)
                        .glass(radius: 18)
                }
                .buttonStyle(.plain)
            }
            if step < Self.steps.count - 1 {
                Button {
                    withAnimation { step += 1 }
                    if step == Self.steps.count - 1 { questions = ConsistencyChecker.check(params, cols: Catalog.cols()) }
                } label: {
                    Label("Suivant", systemImage: "chevron.right").labelStyle(TrailingIcon())
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.rideGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .opacity(canContinue ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!canContinue)
            } else {
                Button { startPlanning() } label: {
                    Label("Continuer avec Claude", systemImage: "sparkles")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.rideGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(start == nil)
            }
        }
        .padding(16)
        .background(Theme.carbon.opacity(0.95).ignoresSafeArea(edges: .bottom))
    }

    private var canContinue: Bool {
        switch step {
        case 0: start != nil && (loop || end != nil || !stops.isEmpty)
        default: true
        }
    }

    // MARK: Step 1 — where

    private var whereStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Nom du trip", text: $name, prompt: suggestedName ?? "Ex. Les cols du Sud")
            placeCard("Départ", place: start, icon: "flag.fill", tint: Theme.ok) { picking = .start }
            HStack(spacing: 10) {
                choice("Point de chute", icon: "flag.checkered", selected: !loop) { loop = false }
                choice("Boucle", icon: "arrow.triangle.2.circlepath", selected: loop) { loop = true; end = nil }
            }
            if !loop {
                placeCard("Point de chute", place: end, icon: "flag.checkered", tint: Theme.accent) { picking = .end }
            }
            sectionTitle("Passages obligatoires")
            ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                HStack(spacing: 12) {
                    IconBadge(icon: "mappin.and.ellipse", tint: Theme.info)
                    Text(stop.name).font(.body.weight(.semibold)).lineLimit(2)
                    Spacer()
                    Button { stops.remove(at: i) } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Theme.muted)
                    }
                    .accessibilityLabel("Retirer \(stop.name)")
                }
                .padding(12)
                .glass(radius: 16)
            }
            Button { picking = .stop } label: {
                Label("Ajouter un passage (col, ville, adresse…)", systemImage: "plus.circle.fill")
                    .font(.subheadline.bold()).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .glass(radius: 16)
            }
            .buttonStyle(.plain)
            if !previewMarkers.isEmpty {
                TripMapView(content: MapContent(markers: previewMarkers))
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
    }

    private var previewMarkers: [MapContent.Marker] {
        var out: [MapContent.Marker] = []
        if let p = start?.point { out.append(.init(id: "start", point: p, title: "🏍 \(start!.name)", subtitle: "Départ")) }
        for (i, s) in stops.enumerated() {
            if let p = s.point { out.append(.init(id: "stop-\(i)", point: p, title: "📍 \(s.name)", subtitle: "Passage")) }
        }
        if !loop, let p = end?.point { out.append(.init(id: "end", point: p, title: "🏁 \(end!.name)", subtitle: "Point de chute")) }
        return out
    }

    private var suggestedName: String? {
        guard let a = start?.name.components(separatedBy: " (").first else { return nil }
        if let b = (loop ? nil : end?.name)?.components(separatedBy: " (").first { return "\(a) → \(b)" }
        if let s = stops.first?.name.components(separatedBy: " (").first { return "Boucle \(a) · \(s)" }
        return nil
    }

    // MARK: Step 2 — when

    private var whenStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                DatePicker("Départ", selection: $dateStart,
                           in: (editing == nil ? Calendar.current.startOfDay(for: Date()) : .distantPast)...,
                           displayedComponents: .date)
                    .padding(.vertical, 8)
                Divider().overlay(Color.white.opacity(0.1))
                DatePicker("Retour", selection: $dateEnd, in: dateStart..., displayedComponents: .date)
                    .padding(.vertical, 8)
            }
            .padding(.horizontal, 14)
            .glass(radius: 18)
            .onChange(of: dateStart) { _, d in if dateEnd < d { dateEnd = d } }
            bigValue("\(dayCount)", unit: dayCount > 1 ? "jours" : "jour", caption: "de road trip")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Km par jour, au maximum").font(.subheadline.bold())
                    Spacer()
                    Text("\(Int(maxKmPerDay)) km").font(.title3.bold().monospacedDigit()).foregroundStyle(Theme.accent)
                }
                Slider(value: $maxKmPerDay, in: 100...500, step: 10).tint(Theme.accent)
                Text(maxKmPerDay <= 200 ? "Tranquille : du temps pour les pauses et les visites."
                     : maxKmPerDay <= 350 ? "Belle journée de moto." : "Grosse journée : réservé aux habitués.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(14)
            .glass(radius: 18)
        }
    }

    // MARK: Step 3 — bike and riders

    private var bikeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if availableBikes.isEmpty {
                Text("Ajoute ta moto dans Réglages › Garage : son autonomie réelle sert à placer les pleins.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                    .padding(14).glass(radius: 16)
            }
            ForEach(availableBikes) { bike in
                let on = bikeIds.contains(bike.id)
                Button {
                    if on { bikeIds.remove(bike.id) } else { bikeIds.insert(bike.id) }
                } label: {
                    HStack(spacing: 12) {
                        MotoGlyphView(size: 18).frame(width: 44, height: 44)
                            .background(on ? AnyShapeStyle(Theme.rideGradient) : AnyShapeStyle(Color.white.opacity(0.1)),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bike.model).font(.headline)
                            Text("\(bike.category?.label ?? "Type à renseigner") · \(Int(bike.rangeKm)) km d'autonomie")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title2)
                            .foregroundStyle(on ? Theme.accent : Theme.muted)
                    }
                    .padding(12)
                    .glass(radius: 18)
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(on ? Theme.accent : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
            sectionTitle("Pilotes")
            HStack(spacing: 10) {
                choice("Solo", icon: "person.fill", selected: riders == .solo) { riders = .solo }
                choice("Duo", icon: "person.2.fill", selected: riders == .duo) { riders = .duo }
            }
            Toggle(isOn: $luggage) {
                Label("Bagagerie (sacoches, top-case)", systemImage: "bag.fill")
            }
            .tint(Theme.accent)
            .padding(14)
            .glass(radius: 18)
        }
    }

    // MARK: Step 4 — style

    private var styleStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(TripStyle.allCases, id: \.self) { s in
                    Button { tripStyle = s } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: icon(s)).font(.title2)
                            Text(s.label).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                            Text(hint(s)).font(.caption2).foregroundStyle(Theme.muted).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .padding(12)
                        .glass(radius: 18, tint: tripStyle == s ? Theme.accent.opacity(0.55) : nil)
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(tripStyle == s ? Theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            sectionTitle("Ton niveau")
            HStack(spacing: 8) {
                ForEach(RiderLevel.allCases, id: \.self) { l in
                    Button { level = l } label: {
                        Text(l.label).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .glass(radius: 14, tint: level == l ? Theme.accent.opacity(0.7) : nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            sectionTitle("Routes")
            VStack(spacing: 0) {
                Toggle("Sans autoroute", isOn: $roads.avoidMotorway).padding(.vertical, 6)
                Divider().overlay(Color.white.opacity(0.1))
                Toggle("Sans voie rapide ni nationale rectiligne", isOn: $roads.avoidTrunk).padding(.vertical, 6)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .glass(radius: 18)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Virages").font(.subheadline.bold())
                    Spacer()
                    Text(["Peu", "Quelques-uns", "Pas mal", "Beaucoup", "Que ça"][roads.curvinessLevel - 1])
                        .font(.subheadline.bold()).foregroundStyle(Theme.accent)
                }
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { n in
                        Button { roads.curvinessLevel = n } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(n <= roads.curvinessLevel ? AnyShapeStyle(Theme.rideGradient) : AnyShapeStyle(Color.white.opacity(0.15)))
                                .frame(height: 12 + CGFloat(n) * 6)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottom)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Sinuosité \(n) sur 5")
                    }
                }
            }
            .padding(14)
            .glass(radius: 18)
        }
    }

    private func icon(_ s: TripStyle) -> String {
        switch s {
        case .kiff: "flame.fill"
        case .balade: "sun.max.fill"
        case .rapide: "bolt.fill"
        case .tourisme: "camera.fill"
        }
    }

    private func hint(_ s: TripStyle) -> String {
        switch s {
        case .kiff: "Virages, cols, enchaînements : le pilotage avant tout."
        case .balade: "Rythme tranquille, paysages, pauses."
        case .rapide: "Relier vite et bien, peu de détours."
        case .tourisme: "Villages, sites, bonnes tables."
        }
    }

    // MARK: Step 5 — details

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                stepButton("minus") { budget = max(50, budget - 10) }
                bigValue("\(Int(budget)) €", unit: "", caption: "par jour (repas, nuit, essence)")
                stepButton("plus") { budget = min(600, budget + 10) }
            }
            .frame(maxWidth: .infinity)
            sectionTitle("À dire à Claude")
            TextField("Ex. éviter tel col, finir tôt le dimanche, resto avec terrasse…", text: $constraints, axis: .vertical)
                .lineLimit(3...6)
                .padding(14)
                .glass(radius: 18)
        }
    }

    // MARK: Step 6 — summary

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(name.isEmpty ? (suggestedName ?? "Nouveau trip") : name).font(.title2.bold())
                summaryLine("flag.fill", start?.name ?? "—")
                ForEach(stops.indices, id: \.self) { summaryLine("mappin.and.ellipse", stops[$0].name) }
                summaryLine(loop ? "arrow.triangle.2.circlepath" : "flag.checkered", loop ? "Boucle, retour au départ" : (end?.name ?? "—"))
                summaryLine("calendar", "\(dayCount) jour\(dayCount > 1 ? "s" : "") · \(Int(maxKmPerDay)) km/jour max")
                summaryLine("gauge.with.dots.needle.67percent",
                            availableBikes.filter { bikeIds.contains($0.id) }.map(\.model).joined(separator: ", ").nonEmpty ?? "Moto à choisir")
                summaryLine(icon(tripStyle), "\(tripStyle.label) · \(level.label) · \(riders == .duo ? "duo" : "solo")")
                summaryLine("eurosign.circle", "\(Int(budget)) € par jour")
            }
            .padding(16)
            .glass(radius: 22)
            if !questions.isEmpty {
                sectionTitle("À clarifier")
                ForEach(questions, id: \.code) { q in
                    Label(q.message, systemImage: "questionmark.circle.fill")
                        .font(.subheadline).foregroundStyle(Theme.hazard)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glass(radius: 16)
                }
            }
            if editing != nil {
                Picker("Statut", selection: $status) {
                    ForEach(TripStatus.allCases, id: \.self) { Text(StatusBadge.label(for: $0)).tag($0) }
                }
                .pickerStyle(.menu)
                .padding(10)
                .glass(radius: 16)
            }
        }
    }

    private func summaryLine(_ icon: String, _ text: String) -> some View {
        Label { Text(text).font(.subheadline) } icon: { Image(systemName: icon).foregroundStyle(Theme.accent) }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.heavy)).foregroundStyle(Theme.muted).padding(.top, 6)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(Theme.muted)
            TextField(prompt, text: text).font(.title3.weight(.semibold))
        }
        .padding(14)
        .glass(radius: 18)
    }

    private func placeCard(_ title: String, place: Place?, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconBadge(icon: icon, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.bold()).foregroundStyle(Theme.muted)
                    Text(place?.name ?? "Choisir une adresse ou un point").font(.headline)
                        .foregroundStyle(place == nil ? Theme.accent : .white).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
            }
            .padding(14)
            .glass(radius: 18)
        }
        .buttonStyle(.plain)
    }

    private func choice(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.bold())
                .frame(maxWidth: .infinity, minHeight: 50)
                .glass(radius: 16, tint: selected ? Theme.accent.opacity(0.7) : nil)
        }
        .buttonStyle(.plain)
    }

    private func bigValue(_ value: String, unit: String, caption: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 44, weight: .black, design: .rounded)).foregroundStyle(Theme.accent)
                if !unit.isEmpty { Text(unit).font(.title3.bold()) }
            }
            Text(caption).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2.bold()).frame(width: 56, height: 56).glass(radius: 28)
        }
        .buttonStyle(.plain)
    }

    // MARK: Data

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
            if let bike = settings.primaryBike { bikeIds = [bike.id] }
            return
        }
        let p = trip.params
        name = trip.name
        status = trip.status
        start = p.start
        end = p.end
        loop = p.end == nil
        stops = p.mandatoryStops.map(\.place)
        keptZones = p.zone
        if let d = ISODate.parse(p.dateStart) { dateStart = d }
        if let d = ISODate.parse(p.dateEnd) { dateEnd = max(d, dateStart) }
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
        let title = name.isEmpty ? (suggestedName ?? "Nouveau trip") : name
        guard var trip = editing else { return Trip(name: title, status: .draft, params: params) }
        var p = params
        p.maxFuelIntervalKm = trip.params.maxFuelIntervalKm
        // A stop kept from before keeps its time, if it had one.
        p.mandatoryStops = stops.map { s in MandatoryStop(place: s, at: trip.params.mandatoryStops.first { $0.place.name == s.name }?.at) }
        trip.name = title
        trip.status = status
        trip.params = p
        return trip
    }

    private var dayCount: Int {
        max(1, (Calendar.current.dateComponents([.day], from: dateStart, to: dateEnd).day ?? 0) + 1)
    }

    private var params: TripParams {
        TripParams(start: start ?? Place(name: ""),
                   end: loop ? nil : end,
                   dateStart: ISODate.format(dateStart), dateEnd: ISODate.format(dateEnd),
                   zone: keptZones,
                   bikes: availableBikes.filter { bikeIds.contains($0.id) },
                   riders: riders, luggage: luggage, maxKmPerDay: maxKmPerDay, style: tripStyle.styleValue,
                   budgetPerDayEur: budget, mandatoryStops: stops.map { MandatoryStop(place: $0) },
                   constraints: constraints, roads: roads,
                   tripStyle: tripStyle, level: level)
    }

    private func startPlanning() {
        questions = ConsistencyChecker.check(params, cols: Catalog.cols())
        let trip = updatedTrip
        store.save(trip)
        draft = trip
    }
}

/// « Suivant › »: the icon after the title.
private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
