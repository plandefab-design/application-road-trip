import Foundation

/// The trip's road book (« feuille de route »), laid out like a rider's own: kicker, title, recap of the stages,
/// points to check, then each stage with its timetable, lunch and lodging cards, the fuel stops, the plan B and the
/// trip's brief. Pure content (blocks): the app draws it on screen and as an A4 PDF.
public struct RoadBook: Equatable, Sendable {
    public enum Tone: String, Equatable, Sendable {
        case warning, ok, caution, danger
    }

    public enum Block: Equatable, Sendable {
        case kicker(String)
        case title(String)
        case subtitle(String)
        /// Section title (orange rule underneath).
        case heading(String)
        /// Stage title « Jour 1 — Cadenet → Puget-Théniers (~355 km) ».
        case dayHeading(String)
        case paragraph(String)
        /// Centred recap lines (« Jour 1 — … »).
        case recap([String])
        /// Coloured box: title and lines (bullets when `bullets`).
        case callout(tone: Tone, title: String?, lines: [String], bullets: Bool)
        case table(columns: [String], rows: [[String]])
        /// Address card: label (« Déjeuner jour 1 — Sisteron »), title (« Restaurant — Le Cours »), lines.
        case card(label: String, title: String, lines: [String])
        case numbered([String])
        case bullets([String])
        /// Label / value lines (the brief).
        case facts([Fact])
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
    /// Page header (« Boucle Col de la Bonnette — feuille de route »).
    public let header: String
    public let blocks: [Block]

    public init(title: String, subtitle: String, header: String, blocks: [Block]) {
        self.title = title
        self.subtitle = subtitle
        self.header = header
        self.blocks = blocks
    }

    public static let timetableColumns = ["Heure indicative", "Étape", "Distance", "Notes"]

    // MARK: Build

    public static func build(_ trip: Trip, pace: PaceEstimator = PaceEstimator(), timeZone: TimeZone = .current,
                             validatedAt: Date? = nil) -> RoadBook {
        let nights = max(0, trip.days.count - 1)
        let subtitle = "Feuille de route — \(trip.days.count) jour\(trip.days.count > 1 ? "s" : "") / \(nights) nuit\(nights > 1 ? "s" : "")"
        var blocks: [Block] = [.kicker("ROAD TRIP MOTO"), .title(trip.name), .subtitle(subtitle)]

        blocks.append(.heading("RECAP ROAD TRIP"))
        blocks.append(.recap(trip.days.map(dayTitle(in: trip))))
        if trip.days.contains(where: { $0.track != nil }) { blocks.append(.map(day: nil)) }

        blocks.append(.heading("Vérifier avant le départ"))
        blocks.append(.callout(tone: .warning, title: "⚠ Points impératifs", lines: mustCheck(trip), bullets: true))

        for day in trip.days {
            blocks += stage(day, trip: trip, pace: pace, timeZone: timeZone)
        }

        let fuel = fuelList(trip)
        if !fuel.isEmpty {
            blocks.append(.heading("Ravitaillements prévus"))
            blocks.append(.paragraph("Au moins tous les \(Int(trip.params.fuelIntervalMeters / 1000)) km, conformément à l'autonomie réservoir :"))
            blocks.append(.numbered(fuel))
        }

        if let plan = trip.planB {
            blocks.append(.heading(plan.title))
            if let intro = plan.intro, !intro.isEmpty { blocks.append(.paragraph(intro)) }
            let tones: [Tone] = [.ok, .caution, .danger]
            for (i, c) in plan.cases.enumerated() {
                blocks.append(.callout(tone: tones[min(i, tones.count - 1)], title: c.title, lines: [c.text] + (c.lines ?? []), bullets: false))
            }
            if let rule = plan.rule, !rule.isEmpty {
                blocks.append(.callout(tone: .danger, title: "Règle absolue", lines: [rule], bullets: false))
            }
        }

        blocks.append(.pageBreak)
        blocks.append(.heading("Cahier des charges"))
        blocks.append(.facts(brief(trip.params)))
        let constraints = trip.params.constraints.trimmingCharacters(in: .whitespacesAndNewlines)
        if !constraints.isEmpty { blocks.append(.paragraph("Contraintes : \(constraints)")) }
        let checklist = TripChecklist.merged(trip)
        if !checklist.isEmpty {
            blocks.append(.heading("Avant de partir"))
            blocks.append(.bullets(checklist.map { "\($0.done ? "☑" : "☐") \($0.label) (\($0.due))" }))
        }
        blocks.append(.paragraph(validatedAt.map { "Feuille de route validée le \(dayMonthYear($0, timeZone: timeZone))." }
                                 ?? "Brouillon : feuille de route non validée."))

        return RoadBook(title: trip.name, subtitle: subtitle, header: "\(trip.name) — feuille de route", blocks: blocks)
    }

    /// « Jour 1 — Cadenet → Puget-Théniers  (~355 km) ».
    static func dayTitle(in trip: Trip) -> (TripDay) -> String {
        { day in
            let km = day.distanceKm.map { "  (~\(Int($0.rounded())) km)" } ?? ""
            return "Jour \(day.index) — \(StageTimetable.from(day, in: trip)) → \(StageTimetable.to(day, in: trip))\(km)"
        }
    }

    /// The planner's points, then the reminders every road book needs.
    static func mustCheck(_ trip: Trip) -> [String] {
        var lines = trip.mustCheck
        if trip.days.contains(where: { $0.track != nil }) {
            lines.append("Tracé calculé sur les routes réelles (profil moto) ; horaires indicatifs à ton allure, arrêts compris.")
        }
        if !trip.pois.filter({ $0.type == .lodging || $0.type == .meal }).isEmpty {
            lines.append("Réservations : à confirmer directement auprès des établissements — tarifs non garantis par cette feuille de route.")
        }
        if trip.pois.contains(where: { $0.verification != .verified }) {
            lines.append("Adresses « à vérifier » : pas de source confirmée, appelle avant d'y aller.")
        }
        return lines
    }

    static func stage(_ day: TripDay, trip: Trip, pace: PaceEstimator, timeZone: TimeZone) -> [Block] {
        var blocks: [Block] = [.dayHeading(dayTitle(in: trip)(day))]
        var intro: [String] = []
        if let date = stageDate(day.date) { intro.append(sentenceCase(date) + ".") }
        if let s = day.summary, !s.isEmpty { intro.append(s) }
        if let leave = StageTimetable.departure(day, timeZone: timeZone) {
            intro.append("Départ recommandé : \(StageTimetable.time(leave, timeZone: timeZone, approx: false)) depuis \(StageTimetable.from(day, in: trip)).")
        }
        if !intro.isEmpty { blocks.append(.paragraph(intro.joined(separator: " "))) }
        if day.track != nil { blocks.append(.map(day: day.index)) }
        let rows = StageTimetable.rows(day, in: trip, pace: pace, timeZone: timeZone)
        blocks.append(.table(columns: timetableColumns, rows: rows.map { [$0.time, $0.step, $0.distance, $0.notes] }))

        let groups: [(label: String, choices: [POIChoice], kind: String)] = [
            ("Déjeuner", day.meals, "Restaurant"), ("Hébergement", day.lodging, "Hôtel"),
        ]
        for group in groups {
            let chosen = group.choices.filter(\.selected)
            let shown = chosen.isEmpty ? group.choices : chosen
            for choice in shown {
                guard let poi = trip.poi(id: choice.poiId) else { continue }
                let suffix = chosen.isEmpty && shown.count > 1 ? " (proposition)" : ""
                blocks.append(.card(label: "\(group.label) jour \(day.index) — \(StageTimetable.town(of: poi))\(suffix)",
                                    title: "\(group.kind) — \(poi.name)", lines: cardLines(poi)))
            }
        }
        return blocks
    }

    /// Address, phone and e-mail, the planner's sourced details, website and verification status.
    static func cardLines(_ poi: POI) -> [String] {
        var lines: [String] = []
        if let a = poi.address, !a.isEmpty { lines.append(a) }
        let contact = [poi.phone, poi.email].compactMap { $0 }.filter { !$0.isEmpty }
        if !contact.isEmpty { lines.append("☎  " + contact.joined(separator: "  ·  ")) }
        lines += poi.details ?? []
        if let note = poi.note, !note.isEmpty { lines.append(note) }
        if let w = poi.website, !w.isEmpty { lines.append(w) }
        lines.append(poi.verification == .verified ? "Source vérifiée" : "À vérifier")
        return lines
    }

    /// « Peipin — jour 1, km ~105 », in order over the whole trip.
    static func fuelList(_ trip: Trip) -> [String] {
        trip.days.flatMap { day in
            day.fuelStops.map { "\(StageTimetable.short($0.name)) — jour \(day.index), km ~\(Int($0.kmFromStart.rounded()))" }
        }
    }

    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
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
