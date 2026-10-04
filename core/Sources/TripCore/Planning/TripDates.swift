import Foundation

/// Dates chosen after the route (schema v9): the rider created the trip without dates, the PC proposed the best
/// periods, the rider picked one.
extension Trip {
    /// Lines the PC writes in `mustCheck` for the trip's dates (seasonal closures, weather of the season).
    public static let seasonalMarks = ["📅 ", "🌦 "]

    /// Fixes the trip on `start` ("yyyy-MM-dd"): every stage gets its date, the end date follows, and the dates are no
    /// longer to be chosen. `checks`: the PC's lines for these dates, replacing those of the previous dates.
    /// false when `start` is not a date.
    @discardableResult
    public mutating func fixDates(start: String, checks: [String] = []) -> Bool {
        guard let first = ISODate.parse(start) else { return false }
        let count = max(days.count, params.dayCount)
        params.dateStart = ISODate.format(first)
        params.dateEnd = ISODate.format(first.addingTimeInterval(Double(count - 1) * 86_400))
        for i in days.indices { days[i].date = ISODate.format(first.addingTimeInterval(Double(i) * 86_400)) }
        params.flexibleDates = nil
        setSeasonalChecks(checks)
        return true
    }

    /// Replaces the PC's seasonal lines, keeping the planner's own points to check.
    public mutating func setSeasonalChecks(_ checks: [String]) {
        mustCheck = mustCheck.filter { line in !Trip.seasonalMarks.contains { line.hasPrefix($0) } } + checks
    }
}
