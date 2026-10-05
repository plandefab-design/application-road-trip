import Foundation

/// One maintenance task of a bike, due every `intervalKm` and/or every `intervalMonths`.
public struct MaintenanceItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var intervalKm: Double?
    public var intervalMonths: Int?
    /// Odometer at the last time it was done (nil = never recorded).
    public var lastDoneKm: Double?
    /// ISO date « yyyy-MM-dd » of the last time it was done.
    public var lastDoneDate: String?

    public init(id: String = UUID().uuidString, label: String, intervalKm: Double? = nil, intervalMonths: Int? = nil,
                lastDoneKm: Double? = nil, lastDoneDate: String? = nil) {
        self.id = id
        self.label = label
        self.intervalKm = intervalKm
        self.intervalMonths = intervalMonths
        self.lastDoneKm = lastDoneKm
        self.lastDoneDate = lastDoneDate
    }
}

/// Maintenance book of one garage bike: odometer (advanced by every ride) and its maintenance items.
/// Stored by the app next to the garage, never inside trip.json.
public struct MaintenanceBook: Codable, Hashable, Sendable {
    public var bikeId: String
    public var odometerKm: Double
    public var items: [MaintenanceItem]

    public init(bikeId: String, odometerKm: Double = 0, items: [MaintenanceItem] = []) {
        self.bikeId = bikeId
        self.odometerKm = odometerKm
        self.items = items
    }

    /// Starting items. Intervals are only STARTING VALUES shown as such in the app: the rider sets them from
    /// the bike's service book (they depend on the model).
    public static func starter(bikeId: String, category: BikeCategory?, odometerKm: Double = 0, today: String) -> MaintenanceBook {
        MaintenanceBook(bikeId: bikeId, odometerKm: odometerKm,
                        items: standardItems(category: category).map { s in
                            MaintenanceItem(id: s.id, label: s.label, intervalKm: s.km, intervalMonths: s.months,
                                            lastDoneKm: odometerKm, lastDoneDate: today)
                        })
    }

    /// The maintenance a rider follows, as in Liberty Rider's maintenance book (tyre pressure, tyre wear, chain
    /// greasing and tension, chain kit, pads and discs, oil change, brake fluid, coolant, yearly service), plus the
    /// air filter (and spokes for enduro). Intervals are starting values, to set from the bike's service book.
    public static func standardItems(category: BikeCategory?) -> [(id: String, label: String, km: Double?, months: Int?)] {
        let offroad = (category?.offroadLevel ?? 0) > 0
        var items: [(id: String, label: String, km: Double?, months: Int?)] = [
            ("tyre-pressure", "Pression des pneus", 500, 1),
            ("tyres", "Usure des pneus", 1_000, nil),
            ("chain-lube", "Graissage de la chaîne", offroad ? 300 : 500, nil),
            ("chain-check", "Tension de la chaîne", 1_000, nil),
            ("chain-kit", "Kit chaîne (remplacement)", offroad ? 15_000 : 20_000, nil),
            ("brake-pads", "Plaquettes et disques de frein", 5_000, 12),
            ("oil", "Vidange (huile + filtre)", 6_000, 12),
            ("brake-fluid", "Purge du liquide de frein", nil, 24),
            ("coolant", "Purge du liquide de refroidissement", nil, 24),
            ("service", "Entretien annuel", 12_000, 12),
            ("air-filter", "Filtre à air", offroad ? 6_000 : 12_000, nil),
        ]
        if category == .enduro { items.append(("spokes", "Rayons et roulements de roues", 1_500, nil)) }
        return items
    }

    /// An existing book brought up to date: standard items it lacks are added (counted from today), standard labels
    /// are renamed; the rider's intervals, history and own items are kept.
    public func completed(category: BikeCategory?, today: String) -> MaintenanceBook {
        var book = self
        for s in Self.standardItems(category: category) {
            if let i = book.items.firstIndex(where: { $0.id == s.id }) {
                book.items[i].label = s.label
            } else {
                book.items.append(MaintenanceItem(id: s.id, label: s.label, intervalKm: s.km, intervalMonths: s.months,
                                                  lastDoneKm: odometerKm, lastDoneDate: today))
            }
        }
        return book
    }

    public enum Level: Int, Comparable, Sendable {
        case ok = 0, soon, due, overdue
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Status: Equatable, Sendable {
        public let level: Level
        /// Km left before it is due (negative = overdue), nil without a km interval.
        public let remainingKm: Double?
        /// Days left before it is due (negative = overdue), nil without a time interval.
        public let remainingDays: Int?

        /// « dans 300 km », « en retard de 120 km », « dans 12 jours »…
        public var text: String {
            var parts: [String] = []
            if let km = remainingKm { parts.append(km >= 0 ? "dans \(Int(km.rounded())) km" : "en retard de \(Int((-km).rounded())) km") }
            if let d = remainingDays { parts.append(d >= 0 ? "dans \(d) jour\(d > 1 ? "s" : "")" : "en retard de \(-d) jour\(d < -1 ? "s" : "")") }
            return parts.isEmpty ? "intervalle à régler" : parts.joined(separator: " ou ")
        }
    }

    /// « Soon »: within 10 % of the km interval (at least 300 km, at most a quarter of the interval), or within a quarter of the time interval (max 30 days).
    public func status(of item: MaintenanceItem, today: Date = Date()) -> Status {
        var remainingKm: Double?
        if let interval = item.intervalKm, interval > 0 {
            remainingKm = (item.lastDoneKm ?? 0) + interval - odometerKm
        }
        var remainingDays: Int?
        if let months = item.intervalMonths, months > 0, let done = item.lastDoneDate.flatMap(ISODate.parse) {
            let utc = Calendar.utc
            if let due = utc.date(byAdding: .month, value: months, to: done) {
                remainingDays = Int((due.timeIntervalSince(today) / 86_400).rounded(.down))
            }
        }
        func level(km: Double?, days: Int?, softKm: Double, softDays: Int) -> Level {
            if let km, km < -softKm { return .overdue }
            if let days, days < -30 { return .overdue }
            if let km, km <= 0 { return .due }
            if let days, days <= 0 { return .due }
            if let km, km <= softKm { return .soon }
            if let days, days <= softDays { return .soon }
            return .ok
        }
        // Never more than a quarter of the interval: a 300 km item (chain greasing off-road) is not « soon » the day it is done.
        let interval = item.intervalKm ?? 0
        let soft = interval > 0 ? min(max(300, interval * 0.1), interval * 0.25) : 300
        let softDays = min(30, (item.intervalMonths ?? 12) * 30 / 4)
        return Status(level: level(km: remainingKm, days: remainingDays, softKm: soft, softDays: softDays), remainingKm: remainingKm, remainingDays: remainingDays)
    }

    /// Items needing attention, most urgent first.
    public func attention(today: Date = Date(), atLeast: Level = .soon) -> [(item: MaintenanceItem, status: Status)] {
        items.map { ($0, status(of: $0, today: today)) }
            .filter { $0.1.level >= atLeast }
            .sorted { $0.1.level != $1.1.level ? $0.1.level > $1.1.level : ($0.1.remainingKm ?? .infinity) < ($1.1.remainingKm ?? .infinity) }
    }

    /// Items that fall due during a trip of `tripKm` starting now (to do before leaving).
    public func dueDuringTrip(tripKm: Double, today: Date = Date()) -> [MaintenanceItem] {
        var future = self
        future.odometerKm += tripKm
        return items.filter { future.status(of: $0, today: today).level >= .due && status(of: $0, today: today).level < .overdue }
            + items.filter { status(of: $0, today: today).level == .overdue }
    }

    public mutating func addRide(km: Double) {
        guard km > 0, km.isFinite else { return }
        odometerKm += km
    }

    public mutating func markDone(_ itemId: String, today: String) {
        guard let i = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[i].lastDoneKm = odometerKm
        items[i].lastDoneDate = today
    }
}
