import SwiftUI
import TripCore

/// Garage: your bikes with their odometer and maintenance at a glance, the next jobs across the garage, and each
/// bike's maintenance book (tyres, chain, brakes, oil, fluids, yearly service…). Every ride adds its km to « Ma moto ».
struct GarageView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var maintenance: MaintenanceStore
    @State private var bikeSheet: BikeSheet?
    @State private var deleting: Bike?

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

    /// true = shown inside another navigation (Réglages, the home bike card): no stack of its own.
    private let embedded: Bool

    init(embedded: Bool = false) { self.embedded = embedded }

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    private var content: some View {
        List {
            if settings.garage.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        MotoGlyphView(size: 40).frame(width: 90, height: 90)
                            .background(Theme.rideGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        Text("Ajoute ta moto").font(.title2.bold())
                        Text("Son type choisit les routes, son autonomie place les pleins, son compteur suit l'entretien.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button { bikeSheet = .add } label: {
                            Label("Ajouter une moto", systemImage: "plus.circle.fill").font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .buttonBorderShape(.roundedRectangle(radius: 16))
                    }
                    .padding(.vertical, 12)
                }
                .listRowBackground(Color.clear)
            }

            if !settings.garage.isEmpty {
                Section {
                    ForEach(settings.garage) { bike in
                        NavigationLink { MaintenanceView(bike: bike) } label: { bikeCard(bike) }
                            .swipeActions(edge: .trailing) {
                                Button("Supprimer", role: .destructive) { deleting = bike }
                                Button("Modifier") { bikeSheet = .edit(bike) }.tint(Theme.info)
                            }
                            .contextMenu {
                                Button { bikeSheet = .edit(bike) } label: { Label("Modifier la moto", systemImage: "pencil") }
                                if settings.primaryBike?.id != bike.id {
                                    Button { settings.primaryBikeId = bike.id } label: {
                                        Label("Compter mes sorties sur celle-ci", systemImage: "gauge.with.needle")
                                    }
                                }
                                Button(role: .destructive) { deleting = bike } label: { Label("Supprimer", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text("Mes motos")
                } footer: {
                    Text("Touche une moto pour son carnet d'entretien. Glisse ou appui long pour la modifier.")
                }

                let upcoming = nextJobs
                Section {
                    if upcoming.isEmpty {
                        Label("Tout est à jour", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.ok)
                    }
                    ForEach(upcoming, id: \.key) { job in
                        NavigationLink { MaintenanceView(bike: job.bike) } label: {
                            HStack(spacing: 12) {
                                IconBadge(icon: MaintenanceView.icon(job.item.id), tint: MaintenanceView.color(job.status.level))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.item.label).font(.subheadline.bold())
                                    Text("\(job.bike.model) · \(job.status.text)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("À prévoir")
                }
            }
        }
        .motoList()
        .navigationTitle("Garage")
        .onAppear { settings.garage.forEach { _ = maintenance.book(for: $0) } }   // books created / completed
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { bikeSheet = .add } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                    .accessibilityLabel("Ajouter une moto")
            }
        }
        .sheet(item: $bikeSheet) { sheet in
            switch sheet {
            case .add:
                BikeEditorView(bike: nil) { bike in
                    settings.garage.append(bike)
                    if settings.garage.count == 1 { settings.primaryBikeId = bike.id }
                }
            case .edit(let bike):
                BikeEditorView(bike: bike) { updated in
                    if let i = settings.garage.firstIndex(where: { $0.id == updated.id }) { settings.garage[i] = updated }
                }
            }
        }
        .confirmationDialog("Supprimer \(deleting?.model ?? "") et son carnet d'entretien ?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                guard let bike = deleting else { return }
                settings.garage.removeAll { $0.id == bike.id }
                maintenance.removeBooks(notIn: Set(settings.garage.map(\.id)))
            }
        }
    }

    /// Jobs due soon or late across the garage, most urgent first.
    private var nextJobs: [(key: String, bike: Bike, item: MaintenanceItem, status: MaintenanceBook.Status)] {
        settings.garage.flatMap { bike -> [(key: String, bike: Bike, item: MaintenanceItem, status: MaintenanceBook.Status)] in
            (maintenance.books[bike.id]?.attention() ?? []).map { (key: "\(bike.id)-\($0.item.id)", bike: bike, item: $0.item, status: $0.status) }
        }
        .sorted { $0.status.level > $1.status.level }
        .prefix(6).map { $0 }
    }

    private func bikeCard(_ bike: Bike) -> some View {
        let book = maintenance.books[bike.id]
        let urgent = book?.attention().first
        let primary = settings.primaryBike?.id == bike.id
        return HStack(spacing: 14) {
            MotoGlyphView(size: 22)
                .frame(width: 56, height: 56)
                .background(primary ? AnyShapeStyle(Theme.rideGradient) : AnyShapeStyle(Color.gray.opacity(0.35)),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(bike.model).font(.headline).lineLimit(1)
                    if primary {
                        Text("MA MOTO").font(.caption2.weight(.heavy)).foregroundStyle(Theme.accent)
                    }
                }
                Text("\(bike.category?.label ?? "Type à renseigner") · \(Int(bike.usableRangeMeters / 1000)) km d'autonomie utile")
                    .font(.caption).foregroundStyle(bike.category == nil ? Theme.hazard : .secondary)
                HStack(spacing: 8) {
                    if let km = book?.odometerKm {
                        Text("\(Int(km).formatted(.number.locale(Locale(identifier: "fr_FR")))) km")
                            .font(.caption.bold().monospacedDigit())
                    }
                    let color = urgent.map { MaintenanceView.color($0.status.level) } ?? Theme.ok
                    Text(urgent.map { "\($0.item.label) \($0.status.text)" } ?? (book == nil ? "Carnet à ouvrir" : "Entretien à jour"))
                        .font(.caption.bold()).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(color.opacity(0.2), in: Capsule())
                        .foregroundStyle(color)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
