import Foundation

/// One line of a stage's timetable, as in a rider's road book: « ~12h30 · Peipin → Jausiers · 115 km ·
/// Ravitaillement à Jausiers ».
public struct TimetableRow: Equatable, Sendable {
    public let time: String
    public let step: String
    public let distance: String
    public let notes: String

    public init(time: String, step: String, distance: String, notes: String) {
        self.time = time
        self.step = step
        self.distance = distance
        self.notes = notes
    }
}

/// The timetable of a stage, computed on the real track: departure, each leg between the places to see (with its
/// distance, fuel stops and passes), lunch, a short break every 1 h 30 of riding, arrival and the daylight margin.
/// Times use the routing engine's duration corrected by the rider's pace; nothing is typed by hand.
public enum StageTimetable {
    public static let breakEvery: TimeInterval = StageTimer.ridingBetweenBreaks
    public static let maxOffset = 3_000.0

    // MARK: Places

    /// « Cadenet » for « Cadenet (Vaucluse) ».
    static func short(_ name: String) -> String {
        name.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces) ?? name
    }

    /// Where the stage starts: written by the planner, else the trip start or the previous stage's end.
    public static func from(_ day: TripDay, in trip: Trip) -> String {
        if let f = day.from, !f.isEmpty { return f }
        guard let i = trip.days.firstIndex(where: { $0.index == day.index }), i > 0 else { return short(trip.params.start.name) }
        return to(trip.days[i - 1], in: trip)
    }

    /// Where the stage ends: written by the planner, else the drop-off point (or the start, for a loop) on the last
    /// stage, else the town of the chosen lodging, else the last place to see.
    public static func to(_ day: TripDay, in trip: Trip) -> String {
        if let t = day.to, !t.isEmpty { return t }
        if day.index == trip.days.last?.index { return short(trip.params.end?.name ?? trip.params.start.name) }
        if let lodging = day.lodging.first(where: \.selected).flatMap({ trip.poi(id: $0.poiId) }) { return town(of: lodging) }
        return day.highlights.last.map { short($0.name) } ?? "fin d'étape"
    }

    /// Town of a place from its address (« 2 Allée de Verdun, 04200 Sisteron » → « Sisteron »), else its name.
    public static func town(of poi: POI) -> String {
        if let a = poi.address, let r = a.range(of: #"\b\d{5}\s+[^,]+"#, options: .regularExpression) {
            return String(a[r]).drop(while: { $0.isNumber || $0 == " " }).trimmingCharacters(in: .whitespaces)
        }
        return poi.name
    }

    /// Recommended departure: the planner's « 07:30 » on the stage date, else 9:00 (local time).
    public static func departure(_ day: TripDay, timeZone: TimeZone = .current) -> Date? {
        guard let base = StageTimer.defaultDeparture(for: day, timeZone: timeZone) else { return nil }
        guard let text = day.departure else { return base }
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "h" || $0 == "H" }).compactMap { Int($0) }
        guard let h = parts.first, (0..<24).contains(h) else { return base }
        let m = parts.count > 1 ? parts[1] : 0
        return base.addingTimeInterval(TimeInterval((h - StageTimer.defaultDepartureHour) * 3600 + m * 60))
    }

    // MARK: Rows

    private enum Kind { case place(Highlight), fuel(FuelStopRef), meal(POI) }
    private struct Event { let along: Double; let kind: Kind }

    public static func rows(_ day: TripDay, in trip: Trip, pace: PaceEstimator = PaceEstimator(),
                            timeZone: TimeZone = .current) -> [TimetableRow] {
        let start = from(day, in: trip), end = to(day, in: trip)
        guard let track = day.track, !track.isEmpty else {
            // Not traced yet: the places in order, without times or distances.
            return [TimetableRow(time: "—", step: "Départ \(start)", distance: "—", notes: "—")]
                + day.highlights.map { TimetableRow(time: "—", step: short($0.name), distance: "—", notes: $0.type == .pass ? "Col" : "—") }
                + [TimetableRow(time: "—", step: "Arrivée \(end)", distance: "—", notes: "Tracé à calculer")]
        }

        let segments = SegmentBuilder.segments(for: track, plannedDuration: day.drivingTimeMin.map { $0 * 60 })
        func riding(_ along: Double) -> TimeInterval { pace.remainingTime(to: along, segments: segments, stops: []) }
        func locate(_ p: GeoPoint?) -> Double? {
            guard let p, let m = track.locate(p), m.lateralOffset <= maxOffset else { return nil }
            return m.distanceAlong
        }

        var events: [Event] = day.highlights.compactMap { h in locate(h.point).map { Event(along: $0, kind: .place(h)) } }
        events += day.fuelStops.compactMap { f in locate(f.point).map { Event(along: $0, kind: .fuel(f)) } }
        let meals = trip.selectedStops(for: day).filter { $0.type == .meal }
        events += meals.compactMap { m in locate(m.point).map { Event(along: $0, kind: .meal(m)) } }
        events.sort { $0.along < $1.along }

        let leave = departure(day, timeZone: timeZone)
        var stops: TimeInterval = 0                       // time stopped so far, before the current leg
        var pending: TimeInterval = 0                     // stops inside the current leg (counted once it is listed)
        var lastStopRiding: TimeInterval = 0              // riding time at the last stop (breaks every 1 h 30)
        var lastAlong = 0.0, lastName = start
        var fuelNotes: [String] = []
        var lunchDone = !meals.isEmpty
        let longDay = riding(track.length) >= StageTimer.lunchAfterRiding
        func clock(_ along: Double) -> Date? { leave?.addingTimeInterval(riding(along) + stops) }

        var rows = [TimetableRow(time: leave.map { time($0, timeZone: timeZone, approx: false) } ?? "—",
                                 step: "Départ \(start)", distance: "—", notes: "—")]

        func leg(to name: String, at along: Double, extra: [String] = []) {
            guard along - lastAlong >= 500 else { return }
            let notes = fuelNotes + extra
            rows.append(TimetableRow(time: clock(lastAlong).map { time($0, timeZone: timeZone) } ?? "—",
                                     step: "\(lastName) → \(name)", distance: km(along - lastAlong),
                                     notes: notes.isEmpty ? "—" : notes.joined(separator: " · ")))
            fuelNotes = []
            stops += pending                              // the leg starts before its own stops
            pending = 0
            lastAlong = along
            lastName = name
        }

        func lunch(at along: Double, place: String, restaurant: String?) {
            rows.append(TimetableRow(time: clock(along).map { time($0, timeZone: timeZone) } ?? "—",
                                     step: "Déjeuner à \(place) (~\(RoadBook.duration(StageTimer.mealStop)))",
                                     distance: "—", notes: restaurant.map { "Restaurant \($0)" } ?? "—"))
            stops += StageTimer.mealStop
            lastStopRiding = riding(along)
            lunchDone = true
        }

        for event in events {
            switch event.kind {
            case .fuel(let f):
                fuelNotes.append("Ravitaillement à \(short(f.name))")
                pending += StageTimer.fuelStop
                lastStopRiding = riding(event.along)
            case .meal(let m):
                let place = town(of: m)
                leg(to: place, at: event.along)
                lunch(at: event.along, place: place, restaurant: m.name)
            case .place(let h):
                var extra: [String] = h.type == .pass ? ["Col"] : []
                if riding(event.along) - lastStopRiding >= breakEvery {
                    extra.append("Pause (~\(RoadBook.duration(StageTimer.breakStop)))")
                    pending += StageTimer.breakStop
                    lastStopRiding = riding(event.along)
                }
                leg(to: short(h.name), at: event.along, extra: extra)
                // No restaurant chosen on a long stage: lunch at the first place reached after noon.
                if !lunchDone, longDay, let t = clock(event.along), hour(t, timeZone: timeZone) >= 12 {
                    lunch(at: event.along, place: short(h.name), restaurant: nil)
                }
            }
        }
        leg(to: end, at: track.length)

        stops += pending                                  // stops of a last leg too short to be listed
        let arrival = clock(track.length)
        var arrivalNote = "—"
        if let arrival, let date = day.date, let last = track.points.last, let sunset = Sun.sunset(on: date, at: last) {
            let margin = sunset.timeIntervalSince(arrival)
            arrivalNote = margin >= 0
                ? "Coucher du soleil ~\(time(sunset, timeZone: timeZone, approx: false)) — marge ~\(RoadBook.duration(margin))"
                : "⚠ Coucher du soleil ~\(time(sunset, timeZone: timeZone, approx: false)) : arrivée de nuit"
        }
        rows.append(TimetableRow(time: arrival.map { time($0, timeZone: timeZone) } ?? "—",
                                 step: "Arrivée \(end)", distance: "—", notes: arrivalNote))
        return rows
    }

    // MARK: Formatting

    /// « 7h30 », « ~11h15 » (rounded to 5 min).
    static func time(_ date: Date, timeZone: TimeZone, approx: Bool = true) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 300).rounded() * 300)
        let c = cal.dateComponents([.hour, .minute], from: rounded)
        return (approx ? "~" : "") + "\(c.hour ?? 0)h" + String(format: "%02d", c.minute ?? 0)
    }

    static func hour(_ date: Date, timeZone: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.component(.hour, from: date)
    }

    static func km(_ metres: Double) -> String { "\(max(1, Int((metres / 1000).rounded()))) km" }
}
