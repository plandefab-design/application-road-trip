import XCTest
@testable import TripCore

/// Synthetic trip only — names, places and phone numbers are placeholders, not facts.
final class RoadBookTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func at(_ km: Double) -> GeoPoint { Fixtures.point(onNorthLineAtKm: km) }

    func sampleTrip() -> Trip {
        let params = TripParams(start: Place(name: "Départ A (Vaucluse)"), end: nil, dateStart: "2027-06-12", dateEnd: "2027-06-13",
                                bikes: [Bike(model: "Moto test", rangeKm: 250, category: .roadster)],
                                maxKmPerDay: 280, budgetPerDayEur: 120, tripStyle: .kiff, level: .confirme)
        let meal = POI(id: "m1", type: .meal, name: "Resto test", address: "1 rue X, 04200 Villetest", phone: "0000",
                       point: at(150), email: "resto@example.org", details: ["Spécialité : test"])
        let hotel = POI(id: "h1", type: .lodging, name: "Hôtel test", source: "https://example.org", verification: .verified)
        var day1 = TripDay(index: 1, date: "2027-06-12", distanceKm: 212, drivingTimeMin: 240,
                           highlights: [Highlight(name: "Col fictif", type: .pass, point: at(100)),
                                        Highlight(name: "Village C", type: .viewpoint, point: at(180))],
                           track: Fixtures.northLine(km: 212, stepM: 1_000),
                           fuelStops: [FuelStopRef(name: "Station test", point: at(120), kmFromStart: 120)],
                           meals: [POIChoice(poiId: "m1", selected: true)], lodging: [POIChoice(poiId: "h1")])
        day1.to = "Ville B"
        day1.departure = "07:30"
        day1.summary = "Grosse journée."
        let day2 = TripDay(index: 2, date: "2027-06-13", distanceKm: 90, drivingTimeMin: 100,
                           track: Fixtures.northLine(km: 90, stepM: 1_000))
        let plan = TripPlanB(title: "Plan B — si le col est fermé", intro: "Décision au pied du col.",
                             cases: [.init(title: "Cas 1", text: "Plan inchangé."),
                                     .init(title: "Cas 2", text: "Nuit plus tôt.", lines: ["Hôtel de repli"]),
                                     .init(title: "Cas 3", text: "On ne passe pas.")],
                             rule: "Jamais de descente de nuit.")
        return Trip(name: "Trip test", params: params, days: [day1, day2], pois: [meal, hotel],
                    mustCheck: ["Col fictif : vérifier l'ouverture la veille."], planB: plan)
    }

    func book() -> RoadBook { RoadBook.build(sampleTrip(), timeZone: utc) }

    func testTitleRecapAndPointsToCheck() {
        let b = book()
        XCTAssertEqual(Array(b.blocks.prefix(3)), [.kicker("ROAD TRIP MOTO"), .title("Trip test"), .subtitle("Feuille de route — 2 jours / 1 nuit")])
        XCTAssertEqual(b.header, "Trip test — feuille de route")
        XCTAssertTrue(b.blocks.contains(.recap(["Jour 1 — Départ A → Ville B  (~212 km)", "Jour 2 — Ville B → Départ A  (~90 km)"])))
        guard case .callout(.warning, let title, let lines, true)? = b.blocks.first(where: {
            if case .callout(.warning, _, _, _) = $0 { return true } else { return false }
        }) else { return XCTFail("points impératifs missing") }
        XCTAssertEqual(title, "⚠ Points impératifs")
        XCTAssertEqual(lines.first, "Col fictif : vérifier l'ouverture la veille.")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Réservations : à confirmer") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Adresses « à vérifier »") })
    }

    /// 212 km in 4 h at an even pace (straight synthetic road), departure 7:30: break after the pass, fuel inside
    /// the next leg, lunch, then arrival with the stops counted once.
    func testTimetable() {
        let rows = StageTimetable.rows(sampleTrip().days[0], in: sampleTrip(), timeZone: utc)
        XCTAssertEqual(rows.map(\.time), ["7h30", "~7h30", "~9h40", "~10h45", "~12h00", "~12h35", "~13h10"])
        XCTAssertEqual(rows.map(\.step), ["Départ Départ A", "Départ A → Col fictif", "Col fictif → Villetest",
                                         "Déjeuner à Villetest (~1 h 15)", "Villetest → Village C", "Village C → Ville B",
                                         "Arrivée Ville B"])
        XCTAssertEqual(rows.map(\.distance), ["—", "100 km", "50 km", "—", "30 km", "32 km", "—"])
        XCTAssertEqual(rows[1].notes, "Col · Pause (~15 min)")
        XCTAssertEqual(rows[2].notes, "Ravitaillement à Station test")
        XCTAssertEqual(rows[3].notes, "Restaurant Resto test")
        XCTAssertTrue(rows[6].notes.hasPrefix("Coucher du soleil ~"))
    }

    func testStageBlocksAndCards() {
        let b = book()
        XCTAssertTrue(b.blocks.contains(.dayHeading("Jour 1 — Départ A → Ville B  (~212 km)")))
        XCTAssertTrue(b.blocks.contains(.paragraph("Samedi 12 juin. Grosse journée. Départ recommandé : 7h30 depuis Départ A.")))
        XCTAssertTrue(b.blocks.contains(.card(label: "Déjeuner jour 1 — Villetest", title: "Restaurant — Resto test",
                                              lines: ["1 rue X, 04200 Villetest", "☎  0000  ·  resto@example.org",
                                                      "Spécialité : test", "À vérifier"])))
        XCTAssertTrue(b.blocks.contains(.card(label: "Hébergement jour 1 — Hôtel test", title: "Hôtel — Hôtel test",
                                              lines: ["Source vérifiée"])))
        XCTAssertTrue(b.blocks.contains(.numbered(["Station test — jour 1, km ~120"])))
    }

    func testPlanBCasesAreColouredAndTheRuleIsRed() {
        let callouts = book().blocks.compactMap { block -> (RoadBook.Tone, String?)? in
            if case .callout(let tone, let title, _, false) = block { return (tone, title) }
            return nil
        }
        XCTAssertEqual(callouts.map(\.0), [.ok, .caution, .danger, .danger])
        XCTAssertEqual(callouts.last?.1, "Règle absolue")
        XCTAssertTrue(book().blocks.contains(.callout(tone: .caution, title: "Cas 2", lines: ["Nuit plus tôt.", "Hôtel de repli"], bullets: false)))
    }

    func testValidatedMention() {
        let book = RoadBook.build(sampleTrip(), timeZone: utc, validatedAt: ISODate.parse("2027-05-02")!)
        XCTAssertTrue(book.blocks.contains(.paragraph("Feuille de route validée le 2 mai 2027.")))
    }

    /// A book made of chosen blocks (the app's PDF checks draw each kind of block alone).
    func testBookFromBlocks() {
        let book = RoadBook(title: "T", subtitle: "S", header: "H", blocks: [.paragraph("p"), .pageBreak])
        XCTAssertEqual(book.blocks, [.paragraph("p"), .pageBreak])
        XCTAssertEqual(book.header, "H")
    }

    func testDepartureTimeFromThePlanner() {
        var day = TripDay(index: 1, date: "2027-06-12")
        XCTAssertEqual(StageTimetable.departure(day, timeZone: utc)?.timeIntervalSince(ISODate.parse("2027-06-12")!), 9 * 3600)
        day.departure = "7h45"
        XCTAssertEqual(StageTimetable.departure(day, timeZone: utc)?.timeIntervalSince(ISODate.parse("2027-06-12")!), 7 * 3600 + 45 * 60)
    }

    func testTownFromAddress() {
        XCTAssertEqual(StageTimetable.town(of: POI(type: .meal, name: "X", address: "2 Allée Y, 04200 Ville Test")), "Ville Test")
        XCTAssertEqual(StageTimetable.town(of: POI(type: .meal, name: "Sans adresse")), "Sans adresse")
    }

    func testFingerprintIsStableAndFollowsChanges() {
        let trip = sampleTrip()
        XCTAssertEqual(RoadBook.fingerprint(trip), RoadBook.fingerprint(trip))
        var changed = trip
        changed.days[0].lodging = [POIChoice(poiId: "h1", selected: true)]
        XCTAssertNotEqual(RoadBook.fingerprint(trip), RoadBook.fingerprint(changed))
        var renamed = trip
        renamed.name = "Autre nom"
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

    func testSchemaV8RoundTrip() throws {
        let again = try TripCodec.decode(TripCodec.encode(sampleTrip()))
        XCTAssertEqual(again.planB?.cases.count, 3)
        XCTAssertEqual(again.mustCheck.count, 1)
        XCTAssertEqual(again.days[0].departure, "07:30")
        XCTAssertEqual(again.pois[0].details, ["Spécialité : test"])
    }
}
