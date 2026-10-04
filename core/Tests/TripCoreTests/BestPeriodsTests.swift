import XCTest
@testable import TripCore

/// Best period for a trip without dates, computed on the iPhone. Synthetic route, closures and weather only.
final class BestPeriodsTests: XCTestCase {
    /// About `km` kilometres due north from 44° N, 6° E.
    func northTrack(_ km: Double) -> Polyline {
        Polyline((0...Int(km * 1000 / 111)).map { GeoPoint(lat: 44.0 + Double($0) * 0.001, lon: 6.0) })
    }

    lazy var winterRoad = SeasonalClosure(road: "D 900", periods: [ClosurePeriod(11, 1, 4, 30)],
                                          points: [GeoPoint(lat: 44.010, lon: 6.0), GeoPoint(lat: 44.015, lon: 6.0),
                                                   GeoPoint(lat: 44.020, lon: 6.0)])
    let pass = MountainPass(point: GeoPoint(lat: 44.016, lon: 6.0005), ele: 2000, name: "Col test")

    func trip() -> Trip {
        var params = TripParams(start: Place(name: "A"), dateStart: "2027-03-01", dateEnd: "2027-03-02")
        params.flexibleDates = true
        return Trip(name: "T", params: params, days: [TripDay(index: 1, drivingTimeMin: 120, track: northTrack(5)),
                                                      TripDay(index: 2, drivingTimeMin: 150, track: northTrack(5))])
    }

    /// Rain every day of May and October, 34 °C in July and August, mild otherwise, 2021–2026.
    func climate() -> Climate {
        var days: [Climate.Day] = []
        var d = CalendarDay(year: 2021, month: 1, day: 1)!
        while d.year < 2027 {
            days.append(Climate.Day(day: d, rain: [5, 10].contains(d.month) ? 6 : 0, low: 10,
                                    high: [7, 8].contains(d.month) ? 34 : 22))
            d = d.adding(days: 1)
        }
        return Climate(days)
    }

    func testThreeOpenDryMildPeriodsFarEnoughApart() {
        let trip = trip()
        let stages = BestPeriods.stages(of: trip, pack: SeasonPack(version: "1", closures: [winterRoad], passes: [pass]))
        XCTAssertEqual(stages.map(\.place), ["Col test", "Col test"])
        XCTAssertEqual(stages[0].closures, [winterRoad])
        let options = BestPeriods.options(trip: trip, stages: stages, climates: [climate(), climate()],
                                          today: CalendarDay(year: 2027, month: 1, day: 1)!)
        XCTAssertEqual(options.count, 3)
        let starts = options.compactMap { CalendarDay($0.start) }
        XCTAssertTrue(starts.allSatisfy { [6, 9].contains($0.month) }, "\(starts)")     // open, dry, not hot
        for (i, a) in starts.enumerated() { for b in starts[(i + 1)...] { XCTAssertGreaterThanOrEqual(abs(a.days(to: b)), 10) } }
        let first = options[0]
        XCTAssertEqual(CalendarDay(first.start)!.days(to: CalendarDay(first.end)!), 1)
        XCTAssertTrue(first.label.hasPrefix("Du "), first.label)
        XCTAssertTrue(first.reasons.contains { $0.contains("ouverts") })
        XCTAssertTrue(first.reasons.contains { $0.hasPrefix("Pluie 0 jour sur 10") })
        XCTAssertTrue(first.reasons.contains { $0.hasPrefix("Arrivée bien avant la nuit") })
    }

    func testAClosedRoadRulesTheSeasonOutAndIsCheckedNearItsDates() {
        let trip = trip()
        let road = SeasonalClosure(road: "D 900", periods: [ClosurePeriod(9, 1, 6, 10)], points: winterRoad.points)
        let stages = BestPeriods.stages(of: trip, pack: SeasonPack(version: "1", closures: [road], passes: [pass]))
        let options = BestPeriods.options(trip: trip, stages: stages, climates: [], today: CalendarDay(year: 2027, month: 1, day: 1)!)
        let starts = options.compactMap { CalendarDay($0.start) }
        XCTAssertEqual(starts.first, CalendarDay(year: 2027, month: 6, day: 11))     // the day after the reopening
        XCTAssertTrue(starts.allSatisfy { (6...8).contains($0.month) })
        // Just reopened: the road book asks to check it on both days, named after the pass.
        XCTAssertEqual(options[0].checks, ["11 juin", "12 juin"].map {
            "📅 Col test (D 900) : fermé du 1er sept. au 10 juin (OpenStreetMap). Ton passage le \($0) est proche de ces dates : vérifie l'ouverture effective."
        })
        // Closed the whole year: nothing to propose.
        let never = SeasonalClosure(road: "D 900", periods: [ClosurePeriod(1, 1, 12, 31)], points: winterRoad.points)
        let closed = BestPeriods.stages(of: trip, pack: SeasonPack(version: "1", closures: [never]))
        XCTAssertEqual(BestPeriods.options(trip: trip, stages: closed, climates: [], today: CalendarDay(year: 2027, month: 1, day: 1)!), [])
    }

    func testAClosureOnAnotherRoadIsIgnored() {
        let elsewhere = SeasonalClosure(road: "D 1", periods: [ClosurePeriod(1, 1, 12, 31)],
                                        points: [GeoPoint(lat: 44.01, lon: 6.01), GeoPoint(lat: 44.02, lon: 6.01)])
        XCTAssertEqual(SeasonalChecks.closures(on: northTrack(5), among: [elsewhere, winterRoad]), [winterRoad])
    }

    func testSunsetMarginFollowsTheSeason() {
        let stage = BestPeriods.stages(of: trip(), pack: SeasonPack(version: "1"))[0]
        let june = BestPeriods.daylightMargin(stage, on: CalendarDay(year: 2027, month: 6, day: 21)!)!
        let december = BestPeriods.daylightMargin(stage, on: CalendarDay(year: 2027, month: 12, day: 21)!)!
        XCTAssertGreaterThan(june - december, 3)
        // 9:00 + 2 h 15, sunset about 21:20 legal time at 44° N, 6° E in June.
        XCTAssertEqual(june, 21.33 - 11.25, accuracy: 0.25)
    }

    func testLegalTimeAndLabels() {
        XCTAssertEqual(LegalTime.utcOffset(on: CalendarDay(year: 2027, month: 3, day: 27)!, lon: 6), 1)
        XCTAssertEqual(LegalTime.utcOffset(on: CalendarDay(year: 2027, month: 3, day: 28)!, lon: 6), 2)     // last Sunday of March
        XCTAssertEqual(LegalTime.utcOffset(on: CalendarDay(year: 2027, month: 10, day: 31)!, lon: 6), 1)
        XCTAssertEqual(LegalTime.utcOffset(on: CalendarDay(year: 2027, month: 7, day: 1)!, lon: -8.6), 1)   // Porto
        let d = { CalendarDay($0)! }
        XCTAssertEqual(BestPeriods.label(d("2027-08-21"), d("2027-08-22")), "Du 21 au 22 août 2027")
        XCTAssertEqual(BestPeriods.label(d("2027-06-30"), d("2027-07-02")), "Du 30 juin au 2 juil. 2027")
        XCTAssertEqual(BestPeriods.label(d("2027-12-31"), d("2028-01-01")), "Du 31 déc. 2027 au 1er janv. 2028")
        XCTAssertEqual(BestPeriods.label(d("2027-05-01"), d("2027-05-01")), "Le 1er mai 2027")
    }

    func testStageHours() {
        XCTAssertEqual(BestPeriods.hours(drivingMinutes: 120), 2.25, accuracy: 1e-9)
        XCTAssertEqual(BestPeriods.hours(drivingMinutes: 300), 5 + 0.75 + 1.25, accuracy: 1e-9)
    }
}

/// Season data published by GitHub, read by the iPhone.
final class SeasonPackTests: XCTestCase {
    func testCompactWireFormat() throws {
        let json = #"""
        {"version": "ab12", "closures": [["D 902", [[10, 15, 6, 1]], [44.8, 6.6, 44.81, 6.61]]],
         "passes": [[44.8, 6.6, 2360, "Col d'Izoard"], [45.0, 6.4, null, "Col sans altitude"]]}
        """#
        let pack = try JSONDecoder().decode(SeasonPack.self, from: Data(json.utf8))
        XCTAssertEqual(pack.closures[0].road, "D 902")
        XCTAssertEqual(pack.closures[0].periods, [ClosurePeriod(10, 15, 6, 1)])
        XCTAssertEqual(pack.closures[0].points, [GeoPoint(lat: 44.8, lon: 6.6), GeoPoint(lat: 44.81, lon: 6.61)])
        XCTAssertEqual(pack.passes.map(\.ele), [2360, nil])
        XCTAssertEqual(try JSONDecoder().decode(SeasonPack.self, from: JSONEncoder().encode(pack)), pack)
    }

    func testClosurePeriods() {
        let winter = ClosurePeriod(11, 1, 5, 31)
        let d = { CalendarDay($0)! }
        XCTAssertTrue(winter.isClosed(on: d("2027-01-15")))
        XCTAssertTrue(winter.isClosed(on: d("2027-05-31")))
        XCTAssertFalse(winter.isClosed(on: d("2027-06-01")))
        XCTAssertEqual(winter.daysFromBoundary(d("2027-06-10")), 10)
        XCTAssertEqual(winter.daysFromBoundary(d("2027-10-25")), 7)
        XCTAssertFalse(ClosurePeriod(3, 13, 3, 19).isClosed(on: d("2027-03-20")))
    }

    func testWeatherLineOnlyWhenItMatters() {
        let day = CalendarDay(year: 2027, month: 5, day: 20)!
        XCTAssertNil(SeasonalChecks.weatherLine(stage: 1, day: day, place: "Col", stats: .init(rain: 0.1, low: 9, high: 24), years: 6))
        XCTAssertEqual(SeasonalChecks.weatherLine(stage: 2, day: day, place: "Col d'Izoard",
                                                  stats: .init(rain: 0.4, low: -1.2, high: 20), years: 6),
                       "🌦 Météo de saison, jour 2 (20 mai, Col d'Izoard) : pluie 4 jours sur 10, -1 °C au petit matin (Open-Meteo, 6 dernières années).")
    }

    func testClimateWeekOfTheYearAndArchiveParsing() throws {
        let json = #"""
        {"daily": {"time": ["2025-06-20", "2025-06-21", "2025-06-22"], "precipitation_sum": [0.0, 3.2, null],
                   "temperature_2m_min": [8.0, 10.0, 9.0], "temperature_2m_max": [22.0, 24.0, 23.0]}}
        """#
        let days = try Climate.parseArchive(Data(json.utf8))
        XCTAssertEqual(days.count, 2)                                       // the day with a missing value is skipped
        XCTAssertNil(Climate(days).stats(CalendarDay(year: 2027, month: 6, day: 21)!))   // fewer than 10 days known
        let tenYears = (2015...2024).flatMap { y in days.map { Climate.Day(day: CalendarDay(year: y, month: 6, day: $0.day.day)!,
                                                                             rain: $0.rain, low: $0.low, high: $0.high) } }
        let stats = try XCTUnwrap(Climate(tenYears).stats(CalendarDay(year: 2027, month: 6, day: 21)!))
        XCTAssertEqual(stats.rain, 0.5, accuracy: 1e-9)
        XCTAssertEqual(stats.low, 9, accuracy: 1e-9)
        XCTAssertEqual(Climate.cacheName(GeoPoint(lat: 44.812, lon: 6.687)), "44.80_6.70_6y.json")
        let url = try XCTUnwrap(Climate.archiveRequest(GeoPoint(lat: 44.812, lon: 6.687), today: CalendarDay(year: 2026, month: 10, day: 4)!))
        XCTAssertTrue(url.absoluteString.contains("start_date=2020-01-01"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("end_date=2025-12-31"))
    }

    func testCalendarDayArithmetic() {
        let d = CalendarDay(year: 2028, month: 2, day: 28)!
        XCTAssertEqual(d.adding(days: 1).iso, "2028-02-29")
        XCTAssertEqual(d.adding(days: 2).iso, "2028-03-01")
        XCTAssertEqual(CalendarDay(year: 2028, month: 12, day: 31)!.dayOfYear, 366)
        XCTAssertEqual(CalendarDay("2026-10-04")!.weekday, 0)                  // a Sunday
        XCTAssertNil(CalendarDay("2027-02-29"))
        XCTAssertEqual(CalendarDay(daysSinceEpoch: d.daysSinceEpoch), d)
        XCTAssertEqual(CalendarDay(Date(timeIntervalSince1970: 86_400 * 3 + 3600), timeZone: TimeZone(identifier: "UTC")!).iso, "1970-01-04")
    }
}
