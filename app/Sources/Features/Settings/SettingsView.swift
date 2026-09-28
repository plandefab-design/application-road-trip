import SwiftUI
import TripCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: TripStore
    @State private var bikeSheet: BikeSheet?
    @State private var health: String = "Non testé"
    @State private var token = ""
    @State private var tomtom = ""

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
                                    Text("Autonomie \(Int(bike.rangeKm)) km · marge \(Int(bike.reserveMarginPct)) % · utile \(Int(bike.usableRangeMeters / 1000)) km")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "pencil").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { settings.garage.remove(atOffsets: $0) }
                    Button("Ajouter une moto") { bikeSheet = .add }
                } header: {
                    Text("Garage")
                } footer: {
                    Text("Touche une moto pour la modifier, glisse vers la gauche pour la supprimer.")
                }

                Section("Pilote") {
                    TextField("Contact SOS — nom", text: $settings.sosName)
                    TextField("Contact SOS — téléphone", text: $settings.sosPhone).keyboardType(.phonePad)
                    Stepper("Km/jour par défaut : \(Int(settings.defaultKmPerDay))", value: $settings.defaultKmPerDay, in: 100...500, step: 10)
                }

                Section {
                    TextField("https://mon-pc.xxxx.ts.net", text: $settings.companionURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Jeton d'accès", text: $token)
                        .onChange(of: token) { _, value in settings.companionToken = value }
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
                    Toggle("Thème sombre forcé", isOn: $settings.forceDark)
                    SecureField("Clé TomTom (trafic)", text: $tomtom)
                        .onChange(of: tomtom) { _, value in settings.tomtomKey = value }
                    Link("Clé gratuite : developer.tomtom.com › compte › API Key", destination: URL(string: "https://developer.tomtom.com")!)
                        .font(.footnote)
                }

                Section("État du système") {
                    LabeledContent("Trips enregistrés", value: "\(store.trips.count)")
                    LabeledContent("Coefficient d'allure (cols)", value: String(format: "%.2f", settings.pace.coefficient(.curvy)))
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                    Text("Signature SideStore : vérifie la date d'expiration dans SideStore avant chaque trip.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("À propos") {
                    Text("Cartes © OpenStreetMap contributors · OpenFreeMap · MapLibre. Météo : Open-Meteo (CC BY 4.0). Trafic : TomTom.")
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
                tomtom = settings.tomtomKey
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
        } else {
            _model = State(initialValue: known.first ?? "")
            _custom = State(initialValue: "")
            _range = State(initialValue: 200)
            _margin = State(initialValue: 15)
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
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(model.isEmpty && custom.isEmpty)
                }
            }
        }
    }
}
