import Foundation

public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public let severity: Severity
    public let code: String
    public let message: String

    public var description: String { "[\(severity.rawValue)] \(code): \(message)" }
}

/// Structural validation of a trip.json (independent of any network service).
public enum TripValidator {
    public static func validate(_ trip: Trip) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func err(_ code: String, _ msg: String) { issues.append(.init(severity: .error, code: code, message: msg)) }
        func warn(_ code: String, _ msg: String) { issues.append(.init(severity: .warning, code: code, message: msg)) }

        if trip.schemaVersion != Trip.currentSchemaVersion {
            err("schema.version", "schemaVersion \(trip.schemaVersion) ≠ \(Trip.currentSchemaVersion)")
        }
        if trip.name.trimmingCharacters(in: .whitespaces).isEmpty {
            err("trip.name", "Nom du trip vide")
        }

        // Dates
        let start = ISODate.parse(trip.params.dateStart)
        let end = ISODate.parse(trip.params.dateEnd)
        if start == nil { err("params.dateStart", "Date de début invalide : \(trip.params.dateStart)") }
        if end == nil { err("params.dateEnd", "Date de fin invalide : \(trip.params.dateEnd)") }
        if let s = start, let e = end, e < s { err("params.dates", "La date de fin précède la date de début") }

        // Bikes
        if trip.params.bikes.isEmpty { warn("params.bikes", "Aucune moto renseignée : autonomie inconnue") }
        for bike in trip.params.bikes where bike.rangeKm <= 0 {
            err("params.bikes.range", "Autonomie invalide pour \(bike.model)")
        }

        // Days
        for (i, day) in trip.days.enumerated() where day.index != i + 1 {
            err("days.index", "Étape \(i + 1) : index \(day.index) attendu \(i + 1)")
        }
        if let s = start, let e = end, !trip.days.isEmpty {
            let span = ISODate.days(from: s, to: e) + 1
            if trip.days.count > span {
                err("days.count", "\(trip.days.count) étapes pour \(span) jours de trip")
            }
        }

        // POI references
        let ids = Set(trip.pois.map(\.id))
        for day in trip.days {
            for ref in day.meals + day.lodging where !ids.contains(ref.poiId) {
                err("days.poiRef", "Étape \(day.index) : POI \(ref.poiId) introuvable")
            }
            if let track = day.track, track.points.contains(where: { !$0.isValid }) {
                err("days.track", "Étape \(day.index) : coordonnées invalides dans le tracé")
            }
            // Fuel interval (SPEC §5.2 invariant)
            let limitKm = trip.params.fuelIntervalMeters / 1000
            var last = 0.0
            let stops = day.fuelStops.map(\.kmFromStart).sorted()
            for km in stops {
                if km - last > limitKm + 0.001 {
                    err("days.fuel", String(format: "Étape %ld : %.0f km sans plein (max %.0f)", day.index, km - last, limitKm))
                }
                last = km
            }
            if let dist = day.distanceKm, dist - last > limitKm + 0.001 {
                warn("days.fuel.end", String(format: "Étape %ld : %.0f km entre le dernier plein et l'arrivée", day.index, dist - last))
            }
        }

        // Never-invent rule
        for poi in trip.pois where poi.verification == .verified && (poi.source ?? "").isEmpty {
            err("pois.source", "POI « \(poi.name) » marqué vérifié sans source")
        }
        for poi in trip.pois {
            if let p = poi.point, !p.isValid { err("pois.point", "POI « \(poi.name) » : coordonnées invalides") }
        }
        return issues
    }

    public static func isValid(_ trip: Trip) -> Bool {
        !validate(trip).contains { $0.severity == .error }
    }
}

/// Minimal ISO-8601 calendar-date helper (UTC, "yyyy-MM-dd"), locale-independent.
public enum ISODate {
    public static func parse(_ s: String) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        let cal = Calendar.utc
        guard let date = cal.date(from: comps) else { return nil }
        // Reject overflow like 2027-02-31
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == parts[0], back.month == parts[1], back.day == parts[2] else { return nil }
        return date
    }

    public static func format(_ d: Date) -> String {
        let cal = Calendar.utc
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func days(from a: Date, to b: Date) -> Int {
        Int(((b.timeIntervalSince(a)) / 86_400).rounded())
    }

    public static func month(_ d: Date) -> Int {
        let cal = Calendar.utc
        return cal.component(.month, from: d)
    }
}

extension Calendar {
    /// Gregorian calendar in UTC: trip dates (« yyyy-MM-dd ») are calendar days, never moments.
    static var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }
}
