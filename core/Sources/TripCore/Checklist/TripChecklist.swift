import Foundation

/// Pre-trip checklist (A9, SPEC §4.3): generated items merged with the planner's, with their due dates.
public enum TripChecklist {
    /// Items every trip needs; labels are stable keys (an existing item with the same label is kept as is).
    public static func defaults(for trip: Trip) -> [ChecklistItem] {
        var items: [ChecklistItem] = []
        let hasPasses = trip.days.contains { $0.highlights.contains { $0.type == .pass } }
        if hasPasses {
            items.append(.init(id: "auto-passes", label: "Vérifier l'ouverture effective des cols et tunnels", due: "J-15"))
        }
        if !trip.pois.filter({ $0.type == .lodging }).isEmpty || trip.days.count > 1 {
            items.append(.init(id: "auto-lodging", label: "Réserver les hébergements", due: "J-15"))
        }
        items += [
            .init(id: "auto-weather", label: "Vérifier la météo sur la route", due: "J-3"),
            .init(id: "auto-passes-j1", label: "Revérifier les cols (état post-hivernal, fermetures)", due: "J-1"),
            .init(id: "auto-offline", label: "Télécharger la carte hors ligne (Wi-Fi)", due: "J-1"),
            .init(id: "auto-sidestore", label: "Rafraîchir Moto Road dans SideStore", due: "J-1"),
            .init(id: "auto-battery", label: "Charger téléphone et batterie externe, prévoir le câble", due: "J-1"),
        ]
        if !hasPasses { items.removeAll { $0.id == "auto-passes-j1" } }
        return items
    }

    /// Planner items first, then generated ones whose label is not already present. Done flags are kept.
    public static func merged(_ trip: Trip) -> [ChecklistItem] {
        let existing = trip.checklist
        let labels = Set(existing.map { $0.label.lowercased() })
        let ids = Set(existing.map(\.id))
        return existing + defaults(for: trip).filter { !labels.contains($0.label.lowercased()) && !ids.contains($0.id) }
    }

    /// Days before departure for « J-15 », « J-1 », « J » ; nil when unreadable.
    public static func daysBefore(_ due: String) -> Int? {
        let s = due.trimmingCharacters(in: .whitespaces).uppercased()
        if s == "J" || s == "J-0" { return 0 }
        guard s.hasPrefix("J-"), let n = Int(s.dropFirst(2)), n >= 0 else { return nil }
        return n
    }

    /// Calendar day (UTC midnight, like ISODate) on which an item is due.
    public static func dueDate(_ item: ChecklistItem, tripStart: String) -> Date? {
        guard let start = ISODate.parse(tripStart), let n = daysBefore(item.due) else { return nil }
        return start.addingTimeInterval(-Double(n) * 86_400)
    }
}
