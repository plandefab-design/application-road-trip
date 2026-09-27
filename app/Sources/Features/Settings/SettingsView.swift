import SwiftUI
import TripCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: TripStore
    @State private var addingBike = false
    @State private var health: String = "Non testé"
    @State private var token = ""
    @State private var tomtom = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Garage") {
                    ForEach(settings.garage) { bike in
                        VStack(alignment: .leading) {
                            Text(bike.model).font(.headline)
                            Text("Autonomie \(Int(bike.rangeKm)) km · marge \(Int(bike.reserveMarginPct)) % · utile \(Int(bike.usableRangeMeters / 1000)) km")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { settings.garage.remove(atOffsets: $0) }
                    Button("Ajouter une moto") { addingBike = true }
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
                    Toggle("Annonces radar", isOn: $settings.radarAnnouncements)
                    Toggle("Thème sombre forcé", isOn: $settings.forceDark)
                    SecureField("Clé TomTom (trafic)", text: $tomtom)
                        .onSubmit { settings.tomtomKey = tomtom }
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
            .sheet(isPresented: $addingBike) { AddBikeView { settings.garage.append($0) } }
            .onAppear {
                token = settings.companionToken
                tomtom = settings.tomtomKey
            }
            .onDisappear {
                settings.companionToken = token
                settings.tomtomKey = tomtom
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
            health = "Injoignable"
        }
    }
}

struct AddBikeView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (Bike) -> Void

    @State private var model = Catalog.bikeModels().first ?? ""
    @State private var custom = ""
    @State private var range = 200.0
    @State private var margin = 15.0

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
            .navigationTitle("Ajouter une moto")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") {
                        onAdd(Bike(model: model.isEmpty ? custom : model, rangeKm: range, reserveMarginPct: margin))
                        dismiss()
                    }
                    .disabled(model.isEmpty && custom.isEmpty)
                }
            }
        }
    }
}
