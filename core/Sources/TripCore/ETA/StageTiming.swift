import Foundation

/// Time budget of one stage (day): riding time plus the stops a rider really makes, and the arrival time for a
/// given departure. Shown per stage in the trip and in the road book (PDF).
public struct StageTiming: Equatable, Sendable {
    /// On the bike, seconds (routing engine's time, corrected by the rider's learned pace).
    public let riding: TimeInterval
    public let fuelStops: Int
    public let breaks: Int
    /// Meal stops: the restaurants chosen for the day, else one lunch break on a long day.
    public let meals: Int
    public let departure: Date?

    public var stopsDuration: TimeInterval {
        Double(fuelStops) * StageTimer.fuelStop + Double(breaks) * StageTimer.breakStop + Double(meals) * StageTimer.mealStop
    }
    public var total: TimeInterval { riding + stopsDuration }
    public var arrival: Date? { departure?.addingTimeInterval(total) }
}

public enum StageTimer {
    public static let fuelStop: TimeInterval = 10 * 60
    public static let breakStop: TimeInterval = 15 * 60
    public static let mealStop: TimeInterval = 75 * 60
    /// A break every 1 h 30 of riding (SPEC: pauses every 1 h 30 to 2 h); a fuel stop counts as one.
    public static let ridingBetweenBreaks: TimeInterval = 90 * 60
    /// Days with this much riding include a lunch stop even when no restaurant was chosen.
    public static let lunchAfterRiding: TimeInterval = 4 * 3600
    public static let defaultDepartureHour = 9

    /// nil when the stage has neither a track nor a planned time.
    public static func estimate(_ day: TripDay, in trip: Trip, pace: PaceEstimator = PaceEstimator(),
                                departure: Date? = nil) -> StageTiming? {
        let planned = day.drivingTimeMin.map { $0 * 60 }
        let riding: TimeInterval
        if let track = day.track, !track.isEmpty {
            riding = pace.drivingTime(SegmentBuilder.segments(for: track, plannedDuration: planned))
        } else if let planned, planned > 0 {
            riding = planned
        } else {
            return nil
        }
        let fuel = day.fuelStops.count
        let breaks = max(0, Int(riding / ridingBetweenBreaks) - fuel)
        let chosenMeals = trip.selectedStops(for: day).filter { $0.type == .meal }.count
        let meals = chosenMeals > 0 ? chosenMeals : (riding >= lunchAfterRiding ? 1 : 0)
        return StageTiming(riding: riding, fuelStops: fuel, breaks: breaks, meals: meals,
                           departure: departure ?? defaultDeparture(for: day))
    }

    /// The stage's date at 9:00, local time (nil without a date).
    public static func defaultDeparture(for day: TripDay, timeZone: TimeZone = .current) -> Date? {
        guard let date = day.date, let midnightUTC = ISODate.parse(date) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: midnightUTC)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: defaultDepartureHour))
    }
}
