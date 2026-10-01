import SwiftUI
import TripCore

/// Maintenance book of one bike: odometer, items with their status, « fait aujourd'hui », intervals.
struct MaintenanceView: View {
    @EnvironmentObject private var maintenance: MaintenanceStore
    let bike: Bike

    @State private var book: MaintenanceBook?
    @State private var odometerText = ""
    @State private var editing: MaintenanceItem?
    @State private var confirmDone: MaintenanceItem?

    var body: some View {
        Form {
            if let book {
                Section {
                    HStack {
                        TextField("Kilométrage", text: $odometerText)
                            .keyboardType(.numberPad)
                            .font(.title2.bold().monospacedDigit())
                        Text("km").foregroundStyle(.secondary)
                    }
                    Button("Mettre à jour le compteur") {
                        guard var b = self.book, let km = Double(odometerText.filter(\.isNumber)) else { return }
                        b.odometerKm = km
                        save(b)
                    }
                    .disabled(Double(odometerText.filter(\.isNumber)) == book.odometerKm)
                } header: {
                    Text("Compteur")
                } footer: {
                    Text("Recopie le compteur de la moto une fois ; ensuite chaque sortie enregistrée avec « Ma moto » l'augmente automatiquement.")
                }

                Section {
                    ForEach(sortedItems(book), id: \.item.id) { entry in
                        Button { confirmDone = entry.item } label: { row(entry.item, entry.status) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("Modifier") { editing = entry.item }.tint(.blue)
                                Button("Supprimer", role: .destructive) { remove(entry.item) }
                            }
                    }
                    Button {
                        editing = MaintenanceItem(label: "", intervalKm: 5_000, lastDoneKm: book.odometerKm,
                                                  lastDoneDate: ISODate.format(Date()))
                    } label: { Label("Ajouter une opération", systemImage: "plus") }
                } header: {
                    Text("Entretien")
                } footer: {
                    Text("Touche une ligne quand c'est fait. Glisse pour modifier l'intervalle. Les intervalles proposés sont indicatifs : règle-les selon le carnet d'entretien de ta moto.")
                }
            }
        }
        .motoList()
        .navigationTitle(bike.model)
        .keyboardDoneButton()
        .onAppear {
            let b = maintenance.book(for: bike)
            book = b
            odometerText = String(Int(b.odometerKm))
        }
        .confirmationDialog(confirmDone?.label ?? "", isPresented: Binding(get: { confirmDone != nil }, set: { if !$0 { confirmDone = nil } }),
                            titleVisibility: .visible) {
            Button("Fait aujourd'hui à \(Int(book?.odometerKm ?? 0)) km") {
                guard var b = book, let item = confirmDone else { return }
                b.markDone(item.id, today: ISODate.format(Date()))
                save(b)
            }
        }
        .sheet(item: $editing) { item in
            MaintenanceItemEditor(item: item) { edited in
                guard var b = book else { return }
                if let i = b.items.firstIndex(where: { $0.id == edited.id }) { b.items[i] = edited } else { b.items.append(edited) }
                save(b)
            }
        }
    }

    private func sortedItems(_ book: MaintenanceBook) -> [(item: MaintenanceItem, status: MaintenanceBook.Status)] {
        book.items.map { ($0, book.status(of: $0)) }
            .sorted { $0.1.level != $1.1.level ? $0.1.level > $1.1.level : ($0.1.remainingKm ?? .infinity) < ($1.1.remainingKm ?? .infinity) }
    }

    private func row(_ item: MaintenanceItem, _ status: MaintenanceBook.Status) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Self.color(status.level)).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.subheadline.bold())
                Text(status.text + interval(item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func interval(_ item: MaintenanceItem) -> String {
        let parts = [item.intervalKm.map { "\(Int($0)) km" }, item.intervalMonths.map { "\($0) mois" }].compactMap { $0 }
        return parts.isEmpty ? "" : " · tous les " + parts.joined(separator: " / ")
    }

    static func color(_ level: MaintenanceBook.Level) -> Color {
        switch level {
        case .ok: .green
        case .soon: .yellow
        case .due: .orange
        case .overdue: .red
        }
    }

    private func save(_ b: MaintenanceBook) {
        maintenance.update(b)
        book = b
        odometerText = String(Int(b.odometerKm))
    }

    private func remove(_ item: MaintenanceItem) {
        guard var b = book else { return }
        b.items.removeAll { $0.id == item.id }
        save(b)
    }
}

/// Label and intervals of one maintenance operation.
struct MaintenanceItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: MaintenanceItem
    let onSave: (MaintenanceItem) -> Void
    @State private var km = ""
    @State private var months = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Opération (ex. Vidange)", text: $item.label)
                HStack { Text("Tous les"); TextField("km", text: $km).keyboardType(.numberPad).multilineTextAlignment(.trailing); Text("km") }
                HStack { Text("ou tous les"); TextField("mois", text: $months).keyboardType(.numberPad).multilineTextAlignment(.trailing); Text("mois") }
                Text("Laisse vide ce qui ne s'applique pas. Le premier des deux atteint déclenche l'alerte.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .motoList()
            .navigationTitle("Opération")
            .keyboardDoneButton()
            .onAppear {
                km = item.intervalKm.map { String(Int($0)) } ?? ""
                months = item.intervalMonths.map(String.init) ?? ""
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        item.intervalKm = Double(km.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
                        item.intervalMonths = Int(months.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
                        onSave(item)
                        dismiss()
                    }
                    .disabled(item.label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
