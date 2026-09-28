import SwiftUI
import TripCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var rides: RideStore
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var maintenance: MaintenanceStore
    @ObservedObject private var alertPack = AlertPackStore.shared
    @AppStorage("mapDarkAtNight") private var mapDarkAtNight = false
    @State private var bikeSheet: BikeSheet?
    @State private var health: String = "Non testé"
    @State private var token = ""

    enum BikeSheet: Identifiable {
        case add
        case edit(Bike)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let bike): bike.id
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(settings.garage) { bike in
                        Button { bikeSheet = .edit(bike) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(bike.model).font(.headline).foregroundStyle(.primary)
                                    Text(bike.category?.label ?? "Type à renseigner").font(.caption.bold())
                                        .foregroundStyle(bike.category == nil ? .orange : .secondary)
                                    Text("Autonomie \(Int(bike.rangeKm)) km · marge \(Int(bike.reserveMarginPct)) % · utile \(Int(bike.usableRangeMeters / 1000)) km")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let km = maintenance.books[bike.id]?.odometerKm {
                                        Label("\(Int(km)) km au compteur" + (settings.primaryBike?.id == bike.id ? " · Ma moto (sorties comptées)" : ""),
                                              systemImage: "gauge.with.needle")
                                            .font(.caption.bold()).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Image(systemName: "pencil").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete {
                        settings.garage.remove(atOffsets: $0)
                        maintenance.removeBooks(notIn: Set(settings.garage.map(\.id)))
                    }
                    Button("Ajouter une moto") { bikeSheet = .add }
                } header: {
                    Text("Garage")
                } footer: {
                    Text("Touche une moto pour la modifier, glisse vers la gauche pour la supprimer.")
                }

                if !settings.garage.isEmpty {
                    Section {
                        Picker("Ma moto (compteur)", selection: Binding(get: { settings.primaryBike?.id ?? "" },
                                                                        set: { settings.primaryBikeId = $0 })) {
                            ForEach(settings.garage) { Text($0.model).tag($0.id) }
                        }
                        ForEach(settings.garage) { bike in
                            NavigationLink {
                                MaintenanceView(bike: bike)
                            } label: {
                                maintenanceRow(bike)
                            }
                        }
                    } header: {
                        Text("Entretien")
                    } footer: {
                        Text("Chaque sortie enregistrée ajoute ses kilomètres au compteur de « Ma moto » et te prévient des entretiens à faire.")
                    }
                }

                Section("Pilote") {
                    TextField("Contact SOS — nom", text: $settings.sosName)
                    TextField("Contact SOS — téléphone", text: $settings.sosPhone).keyboardType(.phonePad)
                    Stepper("Km/jour par défaut : \(Int(settings.defaultKmPerDay))", value: $settings.defaultKmPerDay, in: 100...500, step: 10)
                }

                Section {
                    TextField("https://mon-pc.xxxx.ts.net", text: $settings.companionURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Jeton d'accès (coller)", text: $token)
                        .onSubmit { settings.companionToken = token }
                    Button("Tester la connexion") { Task { await testCompanion() } }
                    LabeledContent("État", value: health)
                } header: {
                    Text("Companion (PC via Tailscale)")
                } footer: {
                    Text("Utilisé uniquement pour créer les trips. La navigation fonctionne sans le PC.")
                }

                Section("Navigation") {
                    Toggle("Guidage vocal", isOn: $settings.voiceEnabled)
                    Toggle("Annonces radar (à 500 m)", isOn: $settings.radarAnnouncements)
                    Toggle("Carte sombre la nuit (moins détaillée)", isOn: $mapDarkAtNight)
                    Toggle("Thème sombre forcé", isOn: $settings.forceDark)
                    NavigationLink {
                        TomTomKeyView()
                    } label: {
                        LabeledContent("Trafic TomTom", value: settings.tomtomKey.isEmpty ? "Aucune clé" : "Clé …\(settings.tomtomKey.suffix(4))")
                    }
                }

                Section("État du système") {
                    LabeledContent("Trips enregistrés", value: "\(store.trips.count)")
                    LabeledContent("Sorties enregistrées", value: "\(rides.rides.count)")
                    LabeledContent("Radars / dangers hors ligne",
                                   value: alertPack.version == nil ? "à synchroniser" : "\(alertPack.cameraCount) / \(alertPack.hazardCount)")
                    if let date = alertPack.updatedAt {
                        Text("Base du \(date.formatted(date: .abbreviated, time: .shortened)), utilisée en balade libre.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(sync.running ? "Synchronisation…" : "Synchroniser avec le PC maintenant") {
                        Task { await sync.sync(store: store, rides: rides, settings: settings) }
                    }
                    .disabled(sync.running)
                    if let s = sync.status { Text(s).font(.footnote).foregroundStyle(.secondary) }
                    LabeledContent("Coefficient d'allure (cols)", value: String(format: "%.2f", settings.pace.coefficient(.curvy)))
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                    if let expiry = SigningInfo.expirationDate {
                        LabeledContent("Signature (SideStore)", value: expiry.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(expiry.timeIntervalSinceNow < 2 * 86_400 ? .orange : .primary)
                    } else {
                        LabeledContent("Signature (SideStore)", value: "inconnue")
                    }
                    Text("Rafraîchis MotoTrip dans SideStore avant cette date (LocalDevVPN connecté, Tailscale coupé), et toujours la veille d'un trip.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("À propos") {
                    Text("Cartes © OpenStreetMap contributors · OpenFreeMap · MapLibre. Météo : Open-Meteo (CC BY 4.0). Trafic : TomTom. Radars : Sécurité routière (Etalab), DGT España (CC BY), OpenStreetMap (ODbL), MapAtlas (CC BY 4.0, mapatlas.eu). Événements en direct : Bison Futé (Licence Ouverte), DGT (CC BY).")
                        .font(.footnote)
                }
            }
            .navigationTitle("Réglages")
            .keyboardDoneButton()
            .sheet(item: $bikeSheet) { sheet in
                switch sheet {
                case .add:
                    BikeEditorView(bike: nil) { settings.garage.append($0) }
                case .edit(let bike):
                    BikeEditorView(bike: bike) { updated in
                        if let i = settings.garage.firstIndex(where: { $0.id == updated.id }) { settings.garage[i] = updated }
                    }
                }
            }
            .onAppear {
                token = settings.companionToken
            }
            .onDisappear {
                if token != settings.companionToken { settings.companionToken = token }   // saved once, not per keystroke
            }
        }
    }

    private func maintenanceRow(_ bike: Bike) -> some View {
        let book = maintenance.books[bike.id]
        let urgent = book?.attention().first
        return HStack(spacing: 10) {
            Circle().fill(urgent.map { MaintenanceView.color($0.status.level) } ?? .green).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(bike.model).font(.subheadline.bold())
                Text(book.map { "\(Int($0.odometerKm)) km" + (urgent.map { " · \($0.item.label) \($0.status.text)" } ?? " · à jour") }
                     ?? "Carnet à ouvrir une première fois")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func testCompanion() async {
        settings.companionToken = token
        guard let client = CompanionClient(urlString: settings.companionURL, token: token) else {
            health = "URL invalide"; return
        }
        do {
            let h = try await client.health()
            health = "OK · routage \(h.graphhopper ?? "?") · planner \(h.planner ?? "?")"
        } catch {
            health = "Injoignable : \(error.localizedDescription)"
        }
    }
}

/// Add a bike (bike == nil) or edit an existing one (keeps its id).
struct BikeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let bike: Bike?
    let onSave: (Bike) -> Void

    @State private var model: String
    @State private var custom: String
    @State private var range: Double
    @State private var margin: Double
    @State private var category: BikeCategory

    init(bike: Bike?, onSave: @escaping (Bike) -> Void) {
        self.bike = bike
        self.onSave = onSave
        let known = Catalog.bikeModels()
        if let bike {
            let inCatalog = known.contains(bike.model)
            _model = State(initialValue: inCatalog ? bike.model : "")
            _custom = State(initialValue: inCatalog ? "" : bike.model)
            _range = State(initialValue: bike.rangeKm)
            _margin = State(initialValue: bike.reserveMarginPct)
            _category = State(initialValue: bike.category ?? .roadster)
        } else {
            _category = State(initialValue: .roadster)
            _model = State(initialValue: known.first ?? "")
            _custom = State(initialValue: "")
            _range = State(initialValue: 200)
            _margin = State(initialValue: 15)
        }
    }

    private var categoryHint: String {
        switch category.offroadLevel {
        case 2: "Itinéraires : chemins et pistes ouverts aux motos, liaisons courtes sur route."
        case 1: "Itinéraires : routes sinueuses + pistes roulantes et routes gravillonnées."
        default: "Itinéraires : bitume uniquement, en bon état."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Modèle", selection: $model) {
                    ForEach(Catalog.bikeModels(), id: \.self) { Text($0).tag($0) }
                    Text("Autre…").tag("")
                }
                if model.isEmpty { TextField("Modèle", text: $custom) }
                Picker("Type", selection: $category) {
                    ForEach(BikeCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(categoryHint).font(.footnote).foregroundStyle(.secondary)
                Stepper("Autonomie réelle : \(Int(range)) km", value: $range, in: 80...450, step: 5)
                Stepper("Marge de sécurité : \(Int(margin)) %", value: $margin, in: 0...40, step: 5)
                Text("Saisis l'autonomie constatée sur ta moto (réserve comprise), pas la valeur constructeur.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle(bike == nil ? "Ajouter une moto" : "Modifier la moto")
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(bike == nil ? "Ajouter" : "Enregistrer") {
                        var saved = bike ?? Bike(model: "", rangeKm: range)
                        saved.model = model.isEmpty ? custom : model
                        saved.rangeKm = range
                        saved.reserveMarginPct = margin
                        saved.category = category
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(model.isEmpty && custom.isEmpty)
                }
            }
        }
    }
}
