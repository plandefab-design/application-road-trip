import SwiftUI
import TripCore

/// Réglages: garage, safety, riding, connections and data.
/// Coloured icons, carbon background, the PC's address in its own screen: clear at a glance.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var rides: RideStore
    @EnvironmentObject private var sync: SyncService
    @ObservedObject private var alertPack = AlertPackStore.shared
    @AppStorage("mapDarkAtNight") private var mapDarkAtNight = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { GarageView(embedded: true) } label: {
                        row("Garage et entretien", icon: "wrench.and.screwdriver.fill", tint: Theme.info,
                            subtitle: "Ta moto, son autonomie, son carnet d'entretien", value: settings.primaryBike?.model)
                    }
                }

                Section {
                    HStack(spacing: 12) {
                        IconBadge(icon: "sos", tint: Theme.camera)
                        TextField("Nom du contact SOS", text: $settings.sosName)
                    }
                    HStack(spacing: 12) {
                        IconBadge(icon: "phone.fill", tint: Theme.camera)
                        TextField("Téléphone du contact SOS", text: $settings.sosPhone).keyboardType(.phonePad)
                    }
                } header: {
                    Text("Sécurité")
                } footer: {
                    Text("Bouton SOS sur l'accueil et en roulant : appui long = appel ; SMS avec ta position exacte ; « petit point » pour rassurer.")
                }

                Section {
                    Toggle(isOn: $settings.voiceEnabled) {
                        row("Directions vocales", icon: "arrow.triangle.turn.up.right.diamond.fill", tint: Theme.info,
                            subtitle: settings.voiceEnabled ? "Comme un GPS : virages, ronds-points, distances" : "Alertes uniquement par défaut")
                    }
                    row("Alertes vocales", icon: "exclamationmark.triangle.fill", tint: Theme.hazard,
                        subtitle: "Radars, dangers, accidents, bouchons : toujours actives", value: "Toujours")
                    Stepper(value: $settings.defaultKmPerDay, in: 100...500, step: 10) {
                        row("Km par jour (nouveau trip)", icon: "road.lanes", tint: Theme.accent, value: "\(Int(settings.defaultKmPerDay))")
                    }
                    Toggle(isOn: $mapDarkAtNight) {
                        row("Carte sombre la nuit", icon: "moon.fill", tint: .indigo, subtitle: "Moins de détails")
                    }
                    Toggle(isOn: $settings.lightTheme) {
                        row("Thème clair", icon: "sun.max.fill", tint: .yellow, subtitle: "L'app est sombre par défaut")
                    }
                } header: {
                    Text("Conduite")
                }
                .tint(Theme.accent)

                Section {
                    NavigationLink { CompanionSettingsView() } label: {
                        row("PC (création, radars, trafic)", icon: "desktopcomputer", tint: Theme.info,
                            value: settings.companionURL.isEmpty ? "À configurer" : "Configuré")
                    }
                    NavigationLink { TomTomKeyView() } label: {
                        row("Trafic TomTom", icon: "car.fill", tint: .teal,
                            value: settings.tomtomKey.isEmpty ? "Aucune clé" : "…\(settings.tomtomKey.suffix(4))")
                    }
                    Button {
                        Task { await sync.sync(store: store, rides: rides, settings: settings) }
                    } label: {
                        row(sync.running ? "Synchronisation…" : "Synchroniser avec le PC", icon: "arrow.triangle.2.circlepath",
                            tint: Theme.ok, subtitle: sync.status)
                    }
                    .disabled(sync.running)
                } header: {
                    Text("Connexions")
                }

                Section {
                    row("Radars · dangers hors ligne", icon: "camera.fill", tint: Theme.camera,
                        subtitle: alertPack.updatedAt.map { "Base du \($0.formatted(date: .abbreviated, time: .shortened)), mise à jour chaque jour" },
                        value: alertPack.version == nil ? "À télécharger" : "\(alertPack.cameraCount) · \(alertPack.hazardCount)")
                    row("Trips · sorties", icon: "map.fill", tint: Theme.accent, value: "\(store.trips.count) · \(rides.rides.count)")
                    row("Allure apprise (cols)", icon: "speedometer", tint: .purple,
                        value: String(format: "%.2f", settings.pace.coefficient(.curvy)))
                    if let expiry = SigningInfo.expirationDate {
                        row("Signature SideStore", icon: "signature", tint: expiry.timeIntervalSinceNow < 2 * 86_400 ? Theme.hazard : .gray,
                            subtitle: "Rafraîchis l'app avant cette date, et la veille d'un trip",
                            value: expiry.formatted(date: .abbreviated, time: .omitted))
                    }
                    row("Version", icon: "info.circle.fill", tint: .gray,
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                } header: {
                    Text("Données")
                }

                Section("À propos") {
                    Text("Cartes © OpenStreetMap contributors · OpenFreeMap · MapLibre. Météo : Open-Meteo (CC BY 4.0). Trafic : TomTom. Radars : Sécurité routière (Etalab), DGT España (CC BY), OpenStreetMap (ODbL), MapAtlas (CC BY 4.0, mapatlas.eu). Événements en direct : Bison Futé (Licence Ouverte), DGT (CC BY). Groupe : Supabase, voix LiveKit (Apache 2.0).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .motoList()
            .navigationTitle("Réglages")
            .keyboardDoneButton()
        }
    }

    // MARK: Rows

    private func row(_ title: String, icon: String, tint: Color, subtitle: String? = nil, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            IconBadge(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
        }
        .contentShape(Rectangle())
    }

}

/// The PC (companion) address and access token, with a connection test.
struct CompanionSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var token = ""
    @State private var health = "Non testé"
    @State private var testing = false

    var body: some View {
        List {
            Section {
                TextField("https://mon-pc.xxxx.ts.net", text: $settings.companionURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Jeton d'accès (coller)", text: $token)
            } header: {
                Text("Adresse Tailscale et jeton")
            } footer: {
                Text("Le PC crée les trips avec Claude, met à jour les radars et relaie les accidents et bouchons en direct (Bison Futé, DGT). En roulant, rien n'en dépend : sans lui, le guidage continue.")
            }
            Section {
                Button { Task { await test() } } label: {
                    Label(testing ? "Test en cours…" : "Tester la connexion", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(testing)
                LabeledContent("État", value: health)
            }
        }
        .motoList()
        .navigationTitle("PC")
        .keyboardDoneButton()
        .onAppear { token = settings.companionToken }
        .onDisappear { if token != settings.companionToken { settings.companionToken = token } }   // saved once
    }

    private func test() async {
        testing = true
        defer { testing = false }
        settings.companionToken = token
        guard let client = CompanionClient(urlString: settings.companionURL, token: token) else {
            health = "Adresse invalide"; return
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
                Section("Modèle") {
                    Picker("Modèle", selection: $model) {
                        ForEach(Catalog.bikeModels(), id: \.self) { Text($0).tag($0) }
                        Text("Autre…").tag("")
                    }
                    if model.isEmpty { TextField("Modèle", text: $custom) }
                }
                Section {
                    Picker("Type", selection: $category) {
                        ForEach(BikeCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text(categoryHint)
                }
                Section {
                    Stepper("Autonomie réelle : \(Int(range)) km", value: $range, in: 80...450, step: 5)
                    Stepper("Marge de sécurité : \(Int(margin)) %", value: $margin, in: 0...40, step: 5)
                } header: {
                    Text("Autonomie")
                } footer: {
                    Text("Saisis l'autonomie constatée sur ta moto (réserve comprise), pas la valeur constructeur. Les pleins sont placés avant \(Int(range * (1 - margin / 100))) km.")
                }
            }
            .motoList()
            .tint(Theme.accent)
            .navigationTitle(bike == nil ? "Ajouter une moto" : "Modifier la moto")
            .navigationBarTitleDisplayMode(.inline)
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
