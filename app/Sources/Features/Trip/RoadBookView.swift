import SwiftUI
import TripCore

/// Cahier des charges: the rider reads the brief and every stage, validates route, stages and places, then
/// exports the PDF. A trip changed after its validation must be validated again.
struct RoadBookView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var validation = RoadBookValidation.shared
    let tripId: String

    @State private var routeOK = false
    @State private var stagesOK = false
    @State private var placesOK = false
    @State private var pdf: URL?
    @State private var rendering = false

    private var trip: Trip? { store.trips.first { $0.id == tripId } }

    var body: some View {
        if let trip {
            let validatedAt = validation.validatedAt(trip)
            let book = RoadBook.build(trip, pace: settings.pace, validatedAt: validatedAt)
            List {
                statusSection(trip, validatedAt: validatedAt)
                content(book, trip: trip)
                if validatedAt == nil { checksSection(trip) }
            }
            .navigationTitle("Cahier des charges")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { actionBar(trip, book: book, validatedAt: validatedAt) }
            .onChange(of: RoadBook.fingerprint(trip)) { _, _ in pdf = nil }
        } else {
            ContentUnavailableView("Trip introuvable", systemImage: "questionmark.folder")
        }
    }

    // MARK: Sections

    @ViewBuilder private func statusSection(_ trip: Trip, validatedAt: Date?) -> some View {
        Section {
            if let date = validatedAt {
                Label("Validé le \(date.formatted(date: .long, time: .omitted))", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
            } else if validation.isOutdated(trip) {
                Label("Le trip a changé depuis ta validation : relis et revalide.", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
            } else {
                Label("Relis tout, coche les 3 cases en bas, valide : le PDF sera prêt.", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder private func content(_ book: RoadBook, trip: Trip) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.title2.bold())
                Text(book.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        ForEach(Array(sections(book).enumerated()), id: \.offset) { _, section in
            Section(section.title) {
                ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block, trip: trip)
                }
            }
        }
    }

    @ViewBuilder private func blockView(_ block: RoadBook.Block, trip: Trip) -> some View {
        switch block {
        case .facts(let facts):
            ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                LabeledContent(f.label) { Text(f.value).multilineTextAlignment(.trailing) }
            }
        case .bullets(let items):
            ForEach(items, id: \.self) { Text($0) }
        case .paragraph(let text):
            Text(text).font(.footnote).foregroundStyle(.secondary)
        case .map(let day):
            TripMapView(content: MapContent.from(trip: trip, highlightDay: day))
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
                .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        case .heading(let text):
            Text(text).font(.subheadline.bold()).foregroundStyle(.orange)
        case .pageBreak:
            EmptyView()
        }
    }

    @ViewBuilder private func checksSection(_ trip: Trip) -> some View {
        let blockers = RoadBook.blockers(trip)
        Section {
            if blockers.isEmpty {
                Toggle("Le trajet me va (départ, arrivée, zone, routes)", isOn: $routeOK)
                Toggle("Les étapes me vont (distances, temps, cols)", isOn: $stagesOK)
                Toggle("Les lieux me vont (pleins, repas, hébergements)", isOn: $placesOK)
            } else {
                ForEach(blockers, id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) }
            }
        } header: {
            Text("Validation")
        } footer: {
            Text(blockers.isEmpty ? "Un changement demandé à Claude ? Fais-le avant de valider : toute modification annule la validation."
                 : "À régler avant de pouvoir valider.")
        }
    }

    // MARK: Bottom action

    @ViewBuilder private func actionBar(_ trip: Trip, book: RoadBook, validatedAt: Date?) -> some View {
        VStack(spacing: 8) {
            if validatedAt != nil {
                if let pdf {
                    ShareLink(item: pdf, preview: SharePreview("\(trip.name) — cahier des charges.pdf")) {
                        bigLabel("Envoyer / enregistrer le PDF", icon: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                } else {
                    Button {
                        Task {
                            rendering = true
                            pdf = await RoadBookPDF.render(book, trip: trip)
                            rendering = false
                        }
                    } label: {
                        bigLabel(rendering ? "Préparation du PDF…" : "Créer le PDF", icon: "doc.richtext.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.orange).disabled(rendering)
                }
                Button("Annuler la validation", role: .destructive) {
                    validation.revoke(trip.id)
                    pdf = nil
                    routeOK = false; stagesOK = false; placesOK = false
                }
                .font(.footnote)
            } else {
                Button { validate(trip) } label: { bigLabel("Valider le cahier des charges", icon: "checkmark.seal.fill") }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(!(routeOK && stagesOK && placesOK) || !RoadBook.blockers(trip).isEmpty)
            }
        }
        .padding()
        .background(.bar)
    }

    private func bigLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
    }

    private func validate(_ trip: Trip) {
        var t = trip
        if t.status == .draft || t.status == .proposed { t.status = .validated }
        store.save(t)
        // Fingerprint of the saved content (saving does not change what is validated).
        validation.validate(t)
    }

    // MARK: Grouping (headings split the list into sections)

    private struct BookSection {
        var title: String
        var blocks: [RoadBook.Block]
    }

    private func sections(_ book: RoadBook) -> [BookSection] {
        var out: [BookSection] = [BookSection(title: "Carte", blocks: [])]
        for block in book.blocks {
            switch block {
            case .heading(let text) where text.hasPrefix("Étape") || ["Cahier des charges", "Résumé", "Avant de partir"].contains(text):
                out.append(BookSection(title: text, blocks: []))
            case .pageBreak:
                continue
            default:
                out[out.count - 1].blocks.append(block)
            }
        }
        return out.filter { !$0.blocks.isEmpty }
    }
}
