import Foundation

/// The trip's « cahier des charges » and road book, validated by the rider then exported as PDF: the brief
/// (13 parameters), then every stage with its times, stops and addresses. Pure content: the app lays it out.
public struct RoadBook: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case heading(String)
        /// Label / value lines (« Distance » · « 212 km »).
        case facts([Fact])
        case bullets([String])
        case paragraph(String)
        /// Map of the whole trip (nil) or of one stage (its index).
        case map(day: Int?)
        case pageBreak
    }

    public struct Fact: Equatable, Sendable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public let title: String
    public let subtitle: String
    public let blocks: [Block]

    // MARK: Build

    public static func build(_ trip: Trip, pace: PaceEstimator = PaceEstimator(), timeZone: TimeZone = .current,
                             validatedAt: Date? = nil) -> RoadBook {
        var blocks: [Block] = [.map(day: nil)]
        blocks.append(.heading("Cahier des charges"))
        blocks.append(.facts(brief(trip.params)))
        let constraints = trip.params.constraints.trimmingCharacters(in: .whitespacesAndNewlines)
        if !constraints.isEmpty { blocks.append(.paragraph("Contraintes : \(constraints)")) }

        let timings = trip.days.map { StageTimer.estimate($0, in: trip, pace: pace) }
        blocks.append(.heading("Résumé"))
        blocks.append(.facts(summary(trip, timings: timings)))

        for (day, timing) in zip(trip.days, timings) {
            blocks.append(.pageBreak)
            blocks += stage(day, timing: timing, trip: trip, timeZone: timeZone)
        }

        let checklist = TripChecklist.merged(trip)
        if !checklist.isEmpty {
            blocks.append(.pageBreak)
            blocks.append(.heading("Avant de partir"))
            blocks.append(.bullets(checklist.map { "\($0.done ? "☑" : "☐") \($0.label) (\($0.due))" }))
        }
        blocks.append(.paragraph(validatedAt.map { "Cahier des charges validé le \(dayMonthYear($0, timeZone: timeZone))." }
                                 ?? "Brouillon : cahier des charges non validé."))
        blocks.append(.paragraph("Les adresses « à vérifier » n'ont pas de source confirmée : appelle avant d'y aller."))

        let km = trip.days.compactMap(\.distanceKm).reduce(0, +)
        return RoadBook(title: trip.name,
                        subtitle: "\(period(trip.params)) · \(trip.days.count) étape\(trip.days.count > 1 ? "s" : "") · \(Int(km.rounded())) km",
                        blocks: blocks)
    }

    static func brief(_ p: TripParams) -> [Fact] {
        var f: [Fact] = [Fact("Départ", p.start.name)]
        f.append(Fact("Point de chute", p.end.map(\.name) ?? "Boucle (retour au départ)"))
        if !p.mandatoryStops.isEmpty {
            f.append(Fact("Passages obligatoires",
                          p.mandatoryStops.map { s in s.place.name + (s.at.map { " (\($0))" } ?? "") }.joined(separator: " · ")))
        }
        f.append(Fact("Période", period(p)))
        if !p.zone.isEmpty {
            let names = Dictionary(Catalog.regions().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            f.append(Fact("Zone", p.zone.map { names[$0] ?? $0 }.joined(separator: ", ")))
        }
        f.append(Fact("Moto\(p.bikes.count > 1 ? "s" : "")", p.bikes.isEmpty ? "Non renseignée"
                      : p.bikes.map { "\($0.model)\($0.category.map { " (\($0.label))" } ?? "") · \(Int($0.rangeKm)) km d'autonomie" }
                        .joined(separator: " ; ")))
        f.append(Fact("Pilote", (p.riders == .duo ? "Duo" : "Solo") + (p.luggage ? ", avec bagagerie" : ", sans bagagerie")))
        f.append(Fact("Km par jour", "\(Int(p.maxKmPerDay)) km max"))
        var style = p.tripStyle?.label ?? (p.style < 0.5 ? "Conduite pure" : "Contemplatif")
        if let level = p.level { style += " · niveau \(level.label.lowercased())" }
        f.append(Fact("Style", style))
        f.append(Fact("Budget", p.budgetPerDayEur.map { "\(Int($0)) € par jour" } ?? "Libre"))
        var roads: [String] = []
        if p.roads.avoidMotorway { roads.append("sans autoroute") }
        if p.roads.avoidTrunk { roads.append("sans voie rapide") }
        roads.append("sinuosité \(p.roads.curvinessLevel)/5")
        f.append(Fact("Routes", roads.joined(separator: ", ")))
        f.append(Fact("Pleins", "tous les \(Int(p.fuelIntervalMeters / 1000)) km maximum"))
        return f
    }

    static func summary(_ trip: Trip, timings: [StageTiming?]) -> [Fact] {
        let known = timings.compactMap { $0 }
        var f = [Fact("Distance", "\(Int(trip.days.compactMap(\.distanceKm).reduce(0, +).rounded())) km")]
        if !known.isEmpty {
            f.append(Fact("Temps de conduite", duration(known.reduce(0) { $0 + $1.riding })))
            f.append(Fact("Avec les arrêts", duration(known.reduce(0) { $0 + $1.total })))
        }
        let cameras = trip.days.reduce(0) { $0 + $1.alerts.filter(\.kind.isCamera).count }
        let hazards = trip.days.reduce(0) { $0 + $1.alerts.filter { !$0.kind.isCamera }.count }
        if cameras + hazards > 0 { f.append(Fact("Radars · dangers", "\(cameras) · \(hazards)")) }
        return f
    }

    static func stage(_ day: TripDay, timing: StageTiming?, trip: Trip, timeZone: TimeZone) -> [Block] {
        var title = "Étape \(day.index)"
        if let date = day.date.flatMap(ISODate.parse) { title += " · \(weekdayDayMonth(date))" }
        var blocks: [Block] = [.heading(title)]
        if day.track != nil { blocks.append(.map(day: day.index)) }

        var f: [Fact] = []
        if let km = day.distanceKm { f.append(Fact("Distance", "\(Int(km.rounded())) km")) }
        if let t = timing {
            f.append(Fact("Conduite", duration(t.riding)))
            var stops: [String] = []
            if t.fuelStops > 0 { stops.append("\(t.fuelStops) plein\(t.fuelStops > 1 ? "s" : "")") }
            if t.breaks > 0 { stops.append("\(t.breaks) pause\(t.breaks > 1 ? "s" : "")") }
            if t.meals > 0 { stops.append("\(t.meals) repas") }
            if !stops.isEmpty { f.append(Fact("Arrêts", "\(stops.joined(separator: ", ")) · \(duration(t.stopsDuration))")) }
            f.append(Fact("Total", duration(t.total)))
            if let departure = StageTimer.defaultDeparture(for: day, timeZone: timeZone) {
                let arrival = departure.addingTimeInterval(t.total)
                f.append(Fact("Horaires", "départ \(clock(departure, timeZone: timeZone)) → arrivée vers \(clock(arrival, timeZone: timeZone))"))
            }
        }
        if let c = day.curvinessScore { f.append(Fact("Sinuosité", "\(Int(c.rounded()))/100")) }
        if let a = day.ascentM, a > 0 { f.append(Fact("Dénivelé", "+\(Int(a.rounded())) m")) }
        let cameras = day.alerts.filter(\.kind.isCamera).count, hazards = day.alerts.count - cameras
        if cameras + hazards > 0 { f.append(Fact("Radars · dangers", "\(cameras) · \(hazards)")) }
        blocks.append(.facts(f))

        if !day.highlights.isEmpty {
            blocks.append(.heading("À ne pas manquer"))
            blocks.append(.bullets(day.highlights.map(\.name)))
        }
        if !day.fuelStops.isEmpty {
            blocks.append(.heading("Pleins"))
            blocks.append(.bullets(day.fuelStops.map { "km \(Int($0.kmFromStart.rounded())) — \($0.name)" }))
        }
        for (label, choices) in [("Repas", day.meals), ("Hébergement", day.lodging)] where !choices.isEmpty {
            blocks.append(.heading(label))
            blocks.append(.bullets(choices.compactMap { choice in
                trip.poi(id: choice.poiId).map { poiLine($0, chosen: choice.selected) }
            }))
        }
        return blocks
    }

    static func poiLine(_ poi: POI, chosen: Bool) -> String {
        var parts = ["\(chosen ? "✔︎ " : "")\(poi.name)"]
        if let a = poi.address, !a.isEmpty { parts.append(a) }
        if let p = poi.phone, !p.isEmpty { parts.append(p) }
        parts.append(poi.verification == .verified ? "vérifié" : "à vérifier")
        return parts.joined(separator: " · ")
    }

    // MARK: Formatting (French, locale-independent)

    static let weekdays = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
    static let months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre",
                         "octobre", "novembre", "décembre"]

    static func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// « samedi 12 juin » for a stage date (yyyy-MM-dd); nil when unreadable.
    public static func stageDate(_ isoDate: String?) -> String? {
        isoDate.flatMap(ISODate.parse).map(weekdayDayMonth)
    }

    /// « 09:00 » in the given time zone.
    public static func clockText(_ date: Date, timeZone: TimeZone = .current) -> String { clock(date, timeZone: timeZone) }

    static func weekdayDayMonth(_ utcMidnight: Date) -> String {
        let c = utcCalendar().dateComponents([.weekday, .day, .month], from: utcMidnight)
        return "\(weekdays[(c.weekday ?? 1) - 1]) \(c.day ?? 0) \(months[(c.month ?? 1) - 1])"
    }

    static func dayMonthYear(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.day, .month, .year], from: date)
        return "\(c.day ?? 0) \(months[(c.month ?? 1) - 1]) \(c.year ?? 0)"
    }

    static func period(_ p: TripParams) -> String {
        guard let s = ISODate.parse(p.dateStart), let e = ISODate.parse(p.dateEnd) else { return "\(p.dateStart) → \(p.dateEnd)" }
        let cal = utcCalendar()
        let cs = cal.dateComponents([.day, .month, .year], from: s), ce = cal.dateComponents([.day, .month, .year], from: e)
        let end = "\(ce.day ?? 0) \(months[(ce.month ?? 1) - 1]) \(ce.year ?? 0)"
        if s == e { return "le \(end)" }
        let start = cs.month == ce.month && cs.year == ce.year ? "\(cs.day ?? 0)" : "\(cs.day ?? 0) \(months[(cs.month ?? 1) - 1])"
        return "du \(start) au \(end)"
    }

    /// « 4 h 05 », « 45 min ».
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

// MARK: - Validation

extension RoadBook {
    /// Stable fingerprint of what the rider validates (route, stages, chosen places): if the trip changes after
    /// validation (chat, recomputed route, parameters), the fingerprint changes and the trip must be validated again.
    public static func fingerprint(_ trip: Trip) -> String {
        var text = "\(trip.params.start.name)|\(trip.params.end?.name ?? "")|\(trip.params.dateStart)|\(trip.params.dateEnd)"
        for day in trip.days {
            text += "#\(day.index)|\(day.date ?? "")|\(Int((day.distanceKm ?? 0).rounded()))|\(day.track?.points.count ?? 0)"
            text += "|" + day.highlights.map(\.name).joined(separator: ",")
            text += "|" + (day.meals + day.lodging).map { "\($0.poiId)\($0.selected ? "+" : "-")" }.joined(separator: ",")
        }
        // FNV-1a 64: deterministic across launches and platforms (Swift's Hasher is not).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// What still blocks the validation, in the rider's words (empty = ready to validate).
    public static func blockers(_ trip: Trip) -> [String] {
        var out: [String] = []
        if trip.days.isEmpty { out.append("Aucune étape : termine le trip avec Claude.") }
        let untraced = trip.days.filter { $0.track == nil }.map(\.index)
        if !untraced.isEmpty {
            out.append("Tracé à calculer pour l'étape \(untraced.map(String.init).joined(separator: ", ")).")
        }
        out += TripValidator.validate(trip).filter { $0.severity == .error }.map(\.message)
        return out
    }
}
