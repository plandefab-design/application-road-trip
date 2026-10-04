import Foundation

/// A date of the calendar (no time, no time zone), with plain arithmetic: comparing every start date of a year
/// stays cheap and exact (days counted from 1970-01-01, proleptic Gregorian).
public struct CalendarDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), (1...CalendarDay.length(of: month, in: year)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// « yyyy-MM-dd ».
    public init?(_ iso: String) {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    /// The calendar day of `date` in `timeZone`.
    public init(_ date: Date, timeZone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(daysSinceEpoch: CalendarDay.days(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1))
    }

    public init(daysSinceEpoch z: Int) {
        // civil_from_days (H. Hinnant)
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let m = mp < 10 ? mp + 3 : mp - 9
        year = yoe + era * 400 + (m <= 2 ? 1 : 0)
        month = m
        day = doy - (153 * mp + 2) / 5 + 1
    }

    public var daysSinceEpoch: Int { CalendarDay.days(year: year, month: month, day: day) }

    public func adding(days: Int) -> CalendarDay { CalendarDay(daysSinceEpoch: daysSinceEpoch + days) }

    /// Days from `self` to `other` (negative when `other` is earlier).
    public func days(to other: CalendarDay) -> Int { other.daysSinceEpoch - daysSinceEpoch }

    /// 1 for 1 January.
    public var dayOfYear: Int { daysSinceEpoch - CalendarDay.days(year: year, month: 1, day: 1) + 1 }

    /// 0 = Sunday … 6 = Saturday.
    public var weekday: Int { ((daysSinceEpoch % 7) + 11) % 7 }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    public static func < (a: CalendarDay, b: CalendarDay) -> Bool { a.daysSinceEpoch < b.daysSinceEpoch }

    public static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    public static func length(of month: Int, in year: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// days_from_civil (H. Hinnant)
    private static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
