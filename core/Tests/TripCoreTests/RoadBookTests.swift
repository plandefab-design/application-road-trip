import XCTest
@testable import TripCore

/// Synthetic trip only — names and places are placeholders, not facts.
final class RoadBookTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func sampleTrip() -> Trip {
        let params = TripParams(start: Place(name: "Départ A"), end: nil, dateStart: "2027-06-12", dateEnd: "2027-06-13",
                                zone: ["FR-PROVENCE"], bikes: [Bike(model: "Moto test", rangeKm: 250, category: .roadster)],
                                maxKmPerDay: 280, budgetPerDayEur: 120, tripStyle: .kiff, level: .confirme)
        let meal = POI(id: "m1", type: .meal, name: "Resto test", phone: "0000")
        let hotel = POI(id: "h1", type: .lodging, name: "Hôtel test", source: "https://example.org", verification: .verified)
        let day1 = TripDay(index: 1, date: "2027-06-12", distanceKm: 212, drivingTimeMin: 240,
                           highlights: [Highlight(name: "Col test")], track: Fixtures.northLine(km: 212, stepM: 1_000),
                           fuelStops: [FuelStopRef(name: "Station test", point: GeoPoint(lat: 45, lon: 6), kmFromStart: 120)],
                           meals: [POIChoice(poiId: "m1", selected: true)], lodging: [POIChoice(poiId: "h1")])
        let day2 = TripDay(index: 2, date: "2027-06-13", distanceKm: 90, drivingTimeMin: 100,
                           track: Fixtures.northLine(km: 90, stepM: 1_000))
        return Trip(name: "Trip test", params: params, days: [day1, day2], pois: [meal, hotel])
    }

    func facts(_ book: RoadBook) -> [String: String] {
        var out: [String: String] = [:]
        for case .facts(let list) in book.blocks { for f in list where out[f.label] == nil { out[f.label] = f.value } }
        return out
    }

    func testBriefAndSummary() {
        let book = RoadBook.build(sampleTrip(), timeZone: utc)
        XCTAssertEqual(book.subtitle, "du 12 au 13 juin 2027 · 2 étapes · 302 km")
        let f = facts(book)
        XCTAssertEqual(f["Point de chute"], "Boucle (retour au départ)")
        XCTAssertEqual(f["Moto"], "Moto test (Roadster) · 250 km d'autonomie")
        XCTAssertEqual(f["Style"], "Kiff (virages) · niveau confirmé")
        XCTAssertEqual(f["Budget"], "120 € par jour")
        XCTAssertEqual(f["Routes"], "sans autoroute, sans voie rapide, sinuosité 4/5")
        XCTAssertEqual(f["Temps de conduite"], "5 h 40")
        XCTAssertEqual(book.blocks.first, .map(day: nil))
    }

    func testStageTimesStopsAndPlaces() {
        let book = RoadBook.build(sampleTrip(), timeZone: utc)
        XCTAssertTrue(book.blocks.contains(.heading("Étape 1 · samedi 12 juin")))
        XCTAssertTrue(book.blocks.contains(.map(day: 1)))
        // Day 1: 4 h riding, 1 fuel (10 min), 1 break (2 due − 1 fuel, 15 min), 1 chosen meal (75 min) = 5 h 40.
        XCTAssertTrue(book.blocks.contains(.facts([
            .init("Distance", "212 km"), .init("Conduite", "4 h 00"),
            .init("Arrêts", "1 plein, 1 pause, 1 repas · 1 h 40"), .init("Total", "5 h 40"),
            .init("Horaires", "départ 09:00 → arrivée vers 14:40"),
        ])))
        XCTAssertTrue(book.blocks.contains(.bullets(["km 120 — Station test"])))
        XCTAssertTrue(book.blocks.contains(.bullets(["✔︎ Resto test · 0000 · à vérifier"])))
        XCTAssertTrue(book.blocks.contains(.bullets(["Hôtel test · vérifié"])))
        XCTAssertTrue(book.blocks.contains(.paragraph("Brouillon : cahier des charges non validé.")))
    }

    func testValidatedMention() {
        let date = ISODate.parse("2027-05-02")!
        let book = RoadBook.build(sampleTrip(), timeZone: utc, validatedAt: date)
        XCTAssertTrue(book.blocks.contains(.paragraph("Cahier des charges validé le 2 mai 2027.")))
    }

    func testFingerprintIsStableAndFollowsChanges() {
        let trip = sampleTrip()
        XCTAssertEqual(RoadBook.fingerprint(trip), RoadBook.fingerprint(trip))
        var changed = trip
        changed.days[0].lodging = [POIChoice(poiId: "h1", selected: true)]       // hotel picked
        XCTAssertNotEqual(RoadBook.fingerprint(trip), RoadBook.fingerprint(changed))
        var renamed = trip
        renamed.name = "Autre nom"                                               // not part of the validation
        XCTAssertEqual(RoadBook.fingerprint(trip), RoadBook.fingerprint(renamed))
    }

    func testBlockers() {
        XCTAssertEqual(RoadBook.blockers(sampleTrip()), [])
        var trip = sampleTrip()
        trip.days[1].track = nil
        XCTAssertEqual(RoadBook.blockers(trip), ["Tracé à calculer pour l'étape 2."])
    }

    func testDurationFormat() {
        XCTAssertEqual(RoadBook.duration(45 * 60), "45 min")
        XCTAssertEqual(RoadBook.duration(4 * 3600 + 5 * 60), "4 h 05")
    }
}
