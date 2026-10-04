import Foundation

/// A period proposed for a trip created without dates (schema v9), with its reasons and the checks of its dates.
public struct DateOption: Equatable, Sendable, Identifiable {
    public let start: String
    public let end: String
    /// « Du 21 au 22 août 2027 ».
    public let label: String
    public let reasons: [String]
    /// Lines for `mustCheck` once chosen (seasonal closures, weather of the season).
    public let checks: [String]
    public var id: String { start }
}

/// Best period for a trip created without dates, computed on the iPhone from sourced data only:
/// - seasonal closures written in OpenStreetMap on each stage's roads (a closed road rules the date out);
/// - the weather of the last 6 years at the stage's highest pass (Open-Meteo archive): rain, cold mornings, heat;
/// - the daylight left when the stage ends (leaving at 9:00, riding time + stops).
/// Every start date from two weeks to a year ahead is scored; the three best (at least 10 days apart) are kept.
public enum BestPeriods {
    public static let firstStartDays = 14         // bookings, preparation
    public static let horizonDays = 365
    public static let count = 3
    public static let apartDays = 10
    public static let departureHour = 9.0

    /// A stage with a computed track, ready to be scored.
    public struct Stage: Sendable {
        public let index: Int
        public let track: Polyline
        /// Where its weather is taken: the highest pass on the route, else the middle of the track.
        public let spot: GeoPoint
        public let place: String
        public let end: GeoPoint
        /// Hours from departure to arrival.
        public let hours: Double
        /// Seasonal closures on its roads (whatever the date).
        public let closures: [SeasonalClosure]
        /// Passes on its roads (they name the closed roads).
        public let passes: [MountainPass]
    }

    /// The stages that have a track, with their weather spot and the closures of their roads.
    public static func stages(of trip: Trip, pack: SeasonPack) -> [Stage] {
        trip.days.compactMap { day in
            guard let track = day.track, track.points.count > 1, let end = track.points.last else { return nil }
            let passes = SeasonalChecks.passes(on: track, among: pack.passes)
            let top = passes.max { ($0.ele ?? 0) < ($1.ele ?? 0) }
            let mid = track.points[track.points.count / 2]
            return Stage(index: day.index, track: track, spot: top?.point ?? mid,
                         place: top?.name ?? day.to ?? "étape \(day.index)", end: end,
                         hours: hours(drivingMinutes: day.drivingTimeMin ?? 0),
                         closures: SeasonalChecks.closures(on: track, among: pack.closures), passes: passes)
        }
    }

    /// Riding (routing time) + a break every 1 h 30 + lunch on a long day.
    public static func hours(drivingMinutes: Double) -> Double {
        let riding = drivingMinutes / 60
        return riding + Double(Int(riding / 1.5)) * 0.25 + (riding >= 4 ? 1.25 : 0)
    }

    /// The best periods. `climates[i]`: the past weather at `stages[i].spot` (nil when unknown: not scored on weather).
    public static func options(trip: Trip, stages: [Stage], climates: [Climate?], today: CalendarDay) -> [DateOption] {
        guard !stages.isEmpty else { return [] }
        let climateOf = { (k: Int) -> Climate? in k < climates.count ? climates[k] : nil }
        var scored: [(score: Double, start: CalendarDay)] = []
        for offset in firstStartDays..<horizonDays {
            let start = today.adding(days: offset)
            var score = 0.0
            var open = true
            for (k, s) in stages.enumerated() {
                let date = start.adding(days: k)
                if s.closures.contains(where: { $0.periods.contains { $0.isClosed(on: date) } }) {
                    open = false
                    break
                }
                if let w = climateOf(k)?.stats(date) {
                    score += 10 * w.rain + 0.8 * max(0, 4 - w.low) + 0.8 * max(0, w.high - 31)
                }
                if let margin = daylightMargin(s, on: date) { score += 3 * max(0, 1.5 - margin) }
            }
            if open { scored.append((score, start)) }
        }
        var chosen: [CalendarDay] = []
        for candidate in scored.sorted(by: { ($0.score, $0.start) < ($1.score, $1.start) }) {
            if chosen.contains(where: { abs($0.days(to: candidate.start)) < apartDays }) { continue }
            chosen.append(candidate.start)
            if chosen.count == count { break }
        }
        let length = max(trip.days.count, 1)
        return chosen.map { option(start: $0, end: $0.adding(days: length - 1), stages: stages, climateOf: climateOf) }
    }

    /// Hours between the planned arrival (9:00 + the stage's hours, local legal time) and sunset at its end.
    static func daylightMargin(_ s: Stage, on date: CalendarDay) -> Double? {
        guard let sunset = Sun.sunset(on: date.iso, at: s.end), let midnight = ISODate.parse(date.iso) else { return nil }
        let local = sunset.timeIntervalSince(midnight) / 3600 + Double(LegalTime.utcOffset(on: date, lon: s.end.lon))
        return local - (departureHour + s.hours)
    }

    private static func option(start: CalendarDay, end: CalendarDay, stages: [Stage],
                               climateOf: (Int) -> Climate?) -> DateOption {
        var reasons: [String] = []
        if stages.contains(where: { !$0.closures.isEmpty }) {
            reasons.append("Cols et routes à fermeture saisonnière ouverts à ces dates (OpenStreetMap).")
        }
        let weather: [(stage: Stage, stats: Climate.Stats)] = stages.enumerated().compactMap { k, s in
            climateOf(k)?.stats(start.adding(days: k)).map { (s, $0) }
        }
        if let coldest = weather.min(by: { $0.stats.low < $1.stats.low }),
           let hottest = weather.max(by: { $0.stats.high < $1.stats.high }) {
            let rain = Int((weather.reduce(0) { $0 + $1.stats.rain } / Double(weather.count) * 10).rounded())
            reasons.append("Pluie \(rain) jour\(rain > 1 ? "s" : "") sur 10 en moyenne sur les \(Climate.years) dernières années (Open-Meteo).")
            reasons.append("\(Int(coldest.stats.low.rounded())) °C au petit matin vers \(coldest.stage.place), "
                           + "\(Int(hottest.stats.high.rounded())) °C l'après-midi au plus chaud.")
        }
        let margins = stages.enumerated().compactMap { k, s in daylightMargin(s, on: start.adding(days: k)) }
        if let least = margins.min() {
            let m = max(0, least)
            if m >= 3 {
                reasons.append("Arrivée bien avant la nuit chaque jour (départ \(Int(departureHour)) h).")
            } else {
                let quarters = Int((m * 4).rounded()) * 15
                reasons.append("Étape la plus juste : arrivée \(quarters / 60) h \(String(format: "%02d", quarters % 60)) avant le coucher du soleil (départ \(Int(departureHour)) h).")
            }
        }
        var checks: [String] = []
        for (k, s) in stages.enumerated() {
            let date = start.adding(days: k)
            checks += SeasonalChecks.closureWarnings(on: date, closures: s.closures, passes: s.passes)
            if let w = climateOf(k)?.stats(date),
               let line = SeasonalChecks.weatherLine(stage: s.index, day: date, place: s.place, stats: w, years: Climate.years) {
                checks.append(line)
            }
        }
        var seen = Set<String>()
        return DateOption(start: start.iso, end: end.iso, label: label(start, end), reasons: reasons,
                          checks: checks.filter { seen.insert($0).inserted })
    }

    /// « Du 21 au 22 août 2027 », « Du 30 juin au 2 juil. 2027 », « Le 3 mai 2027 ».
    public static func label(_ start: CalendarDay, _ end: CalendarDay) -> String {
        let fr = SeasonalChecks.frDate
        let text: String
        if start == end {
            text = "le \(fr(start.month, start.day)) \(start.year)"
        } else if start.year != end.year {
            text = "du \(fr(start.month, start.day)) \(start.year) au \(fr(end.month, end.day)) \(end.year)"
        } else if start.month == end.month {
            text = "du \(start.day == 1 ? "1er" : String(start.day)) au \(fr(end.month, end.day)) \(end.year)"
        } else {
            text = "du \(fr(start.month, start.day)) au \(fr(end.month, end.day)) \(end.year)"
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Legal time in the covered countries: CET/CEST, Portugal WET/WEST (west of 6.5° W); summer time from the last
/// Sunday of March to the last Sunday of October.
public enum LegalTime {
    public static func utcOffset(on day: CalendarDay, lon: Double) -> Int {
        func lastSunday(_ month: Int) -> CalendarDay {
            let d = CalendarDay(year: day.year, month: month, day: 31)!
            return d.adding(days: -d.weekday)
        }
        let base = lon < -6.5 ? 0 : 1
        return base + (lastSunday(3) <= day && day < lastSunday(10) ? 1 : 0)
    }
}
