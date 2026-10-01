import SwiftUI
import UIKit

/// TomTom key entry: plain field (no secure-field clearing), paste button, live test, explicit save.
struct TomTomKeyView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var key = ""
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("Colle ta clé API TomTom", text: $key, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
                Button {
                    key = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? key
                } label: { Label("Coller depuis le presse-papiers", systemImage: "doc.on.clipboard") }
                Button {
                    Task { await test() }
                } label: { Label(testing ? "Test en cours…" : "Tester la clé", systemImage: "checkmark.shield") }
                .disabled(key.isEmpty || testing)
                if let result { Text(result).font(.subheadline) }
            } footer: {
                Text("Gratuit : developer.tomtom.com › créer un compte › Dashboard › « My first API key » (copier). Sans clé, la navigation fonctionne normalement, sans les incidents en direct.")
            }
            Section {
                Button("Enregistrer") {
                    settings.tomtomKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = settings.tomtomKey.isEmpty ? "Clé supprimée." : "Clé enregistrée ✓"
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines) == settings.tomtomKey)
                if !settings.tomtomKey.isEmpty {
                    Button("Supprimer la clé", role: .destructive) {
                        settings.tomtomKey = ""
                        key = ""
                        result = "Clé supprimée."
                    }
                }
            }
        }
        .motoList()
        .navigationTitle("Trafic TomTom")
        .keyboardDoneButton()
        .onAppear { key = settings.tomtomKey }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let client = TomTomTrafficClient(key: key.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            // Small area around Aix-en-Provence: any valid key answers, with or without incidents.
            let incidents = try await client.incidents(minLon: 5.40, minLat: 43.50, maxLon: 5.50, maxLat: 43.56)
            result = "✓ Clé valide (\(incidents.count) incident(s) dans la zone test). Pense à Enregistrer."
        } catch {
            result = "✗ \(TomTomTrafficClient.describe(error))"
        }
    }
}
