import XCTest
@testable import TripCore

final class TurnGuideTests: XCTestCase {
    // Fixture instructions (synthetic positions, roads and places).
    let instructions = [
        TurnInstruction(along: 0, maneuver: .depart, text: "Continuez sur Rue A", street: "Rue A"),
        TurnInstruction(along: 3_000, maneuver: .turnRight, text: "Tournez à droite sur D 5", ref: "D 5", toward: "Sault, [S 8]"),
        TurnInstruction(along: 3_100, maneuver: .turnLeft, text: "Tournez à gauche sur Chemin B", street: "Chemin B"),
        TurnInstruction(along: 3_300, maneuver: .via, text: "Point de passage atteint"),
        TurnInstruction(along: 6_000, maneuver: .roundabout, text: "Au rond-point, prenez la 2e sortie", exit: 2, ref: "D 943"),
        TurnInstruction(along: 9_000, maneuver: .arrive, text: "Arrivée"),
    ]

    func say(_ progress: Double, _ speed: Double) -> TurnGuide.Announcement? {
        TurnGuide.announcement(instructions, progress: progress, speed: speed)
    }

    // MARK: Wording

    func testPhrasesLikeARoadGPS() {
        XCTAssertEqual(TurnGuide.phrase(instructions[1], withRoad: true), "tournez à droite sur la D5, direction Sault")
        XCTAssertEqual(TurnGuide.phrase(instructions[1], withRoad: false), "tournez à droite")
        XCTAssertEqual(TurnGuide.phrase(instructions[4], withRoad: true), "au rond-point, prenez la deuxième sortie sur la D943")
        XCTAssertEqual(TurnGuide.banner(instructions[2]), "Tournez à gauche sur Chemin B")
        XCTAssertEqual(TurnGuide.roadName(TurnInstruction(along: 0, maneuver: .keepLeft, text: "", ref: "A 7")), "l'A7")
        XCTAssertEqual(TurnGuide.phrase(TurnInstruction(along: 0, maneuver: .sharpRight, text: "", ref: "N 85"), withRoad: true),
                       "tournez fortement à droite sur la N85")
    }

    func testRoutingEngineTextIsCleanedWhenNothingElseIsKnown() {
        let apple = TurnInstruction(along: 0, maneuver: .roundabout, text: "Au rond-point, prenez la 1e sortie")
        XCTAssertEqual(TurnGuide.phrase(apple, withRoad: true), "au rond-point, prenez la première sortie")
        XCTAssertEqual(TurnGuide.cleanText("Tournez fort à gauche"), "Tournez fortement à gauche")
        XCTAssertEqual(TurnGuide.cleanText("Tournez à gauche sur D 543 et conduisez vers Cadenet, [S 8]"),
                       "Tournez à gauche sur D 543, direction Cadenet")
        XCTAssertEqual(TurnGuide.cleanDirection("Aix, Marseille, Toulon"), "Aix et Marseille")
    }

    // MARK: Timing

    func testThreeStepsAtRoadSpeed() {
        // 90 km/h: early ≤ 1 500 m, prepare ≤ 450 m, now ≤ 90 m.
        XCTAssertNil(say(1_400, 25))
        XCTAssertEqual(say(1_500, 25), .init(key: "turn-1-early", text: "Dans 1,5 kilomètre, tournez à droite sur la D5, direction Sault"))
        XCTAssertEqual(say(2_600, 25), .init(key: "turn-1-soon", text: "Dans 400 mètres, tournez à droite sur la D5, direction Sault"))
        XCTAssertEqual(say(2_950, 25), .init(key: "turn-1-now", text: "Tournez à droite, puis tournez à gauche", urgent: true))
    }

    func testChainedManeuverHasNoPreparationButItsOrder() {
        XCTAssertEqual(say(3_020, 25), .init(key: "turn-2-now", text: "Tournez à gauche", urgent: true))
    }

    func testContinueLineAfterAManeuver() {
        XCTAssertEqual(say(3_200, 20), .init(key: "continue-2", text: "Continuez sur Chemin B pendant 2,8 kilomètres"))
        XCTAssertEqual(say(6_200, 20), .init(key: "continue-4", text: "Continuez sur la D943 pendant 2,8 kilomètres"))
    }

    func testRoundaboutAndArrival() {
        XCTAssertEqual(say(5_600, 20)?.text, "Dans 400 mètres, au rond-point, prenez la deuxième sortie sur la D943")
        XCTAssertEqual(say(5_950, 20)?.text, "Au rond-point, prenez la deuxième sortie sur la D943")
        XCTAssertEqual(say(8_700, 20), .init(key: "arrive-soon", text: "Dans 300 mètres, vous arrivez à destination"))
    }

    func testNoEarlyWarningInTown() {
        XCTAssertNil(say(2_300, 8))                                   // 700 m at 29 km/h: too early in town
        XCTAssertEqual(say(2_820, 8)?.key, "turn-1-soon")             // 180 m
    }

    func testLeadDistances() {
        XCTAssertEqual(TurnGuide.leads(speed: 0).prepare, 250)
        XCTAssertEqual(TurnGuide.leads(speed: 0).now, 25)
        XCTAssertEqual(TurnGuide.leads(speed: 30).early, 1_800)
        XCTAssertEqual(TurnGuide.leads(speed: 30).prepare, 500)
        XCTAssertEqual(TurnGuide.leads(speed: 30).now, 90)
    }

    func testNextSkipsSilentAndPassedManeuvers() {
        XCTAssertEqual(TurnGuide.next(instructions, progress: 0)?.index, 1)
        XCTAssertEqual(TurnGuide.next(instructions, progress: 3_100)?.index, 4)
        XCTAssertNil(TurnGuide.next(instructions, progress: 6_000))   // only arrival left
    }

    func testSpokenDistance() {
        XCTAssertEqual(TurnGuide.spokenDistance(10), "Dans 50 mètres")
        XCTAssertEqual(TurnGuide.spokenDistance(312), "Dans 300 mètres")
        XCTAssertEqual(TurnGuide.spokenDistance(1_000), "Dans 1 kilomètre")
        XCTAssertEqual(TurnGuide.spokenDistance(1_540), "Dans 1,5 kilomètre")
        XCTAssertEqual(TurnGuide.spokenDistance(2_000), "Dans 2 kilomètres")
        XCTAssertEqual(TurnGuide.spokenLength(12_300), "12 kilomètres")
    }

    /// Invariant: riding the whole day at any speed (one fix per second), every turn gets exactly one order
    /// (« now »), never before its preparation, preparations in order, and silent points are never spoken.
    func testEachManeuverAnnouncedOnceInOrder() {
        for speed in [5.0, 12, 25, 36] {
            var spoken: [String] = []
            var progress = 0.0
            while progress <= 9_000 {
                if let a = say(progress, speed), !spoken.contains(a.key) { spoken.append(a.key) }
                progress += speed
            }
            XCTAssertEqual(spoken.filter { $0.hasSuffix("-now") }, ["turn-1-now", "turn-2-now", "turn-4-now"], "speed \(speed)")
            for i in [1, 2, 4] {
                let order = ["early", "soon", "now"].compactMap { spoken.firstIndex(of: "turn-\(i)-\($0)") }
                XCTAssertEqual(order, order.sorted(), "speed \(speed), turn \(i)")
            }
            XCTAssertFalse(spoken.contains { $0.hasPrefix("turn-0-") || $0.hasPrefix("turn-3-") || $0.hasPrefix("turn-5-") })
        }
    }

    func testDirectionsAreToldApartFromAlerts() {
        XCTAssertTrue(TurnGuide.isDirection(.init(key: "turn-3-soon", text: "")))
        XCTAssertTrue(TurnGuide.isDirection(.init(key: "detour-continue-2", text: "")))
        XCTAssertTrue(TurnGuide.isDirection(.init(key: "detour-arrive-soon", text: "")))
        XCTAssertFalse(TurnGuide.isDirection(.init(key: "alert-4", text: "", urgent: true)))
        XCTAssertFalse(TurnGuide.isDirection(.init(key: "detour-alert-1-near", text: "")))
        XCTAssertFalse(TurnGuide.isDirection(.init(key: "traffic-x-near", text: "")))
    }

    // MARK: Schema

    func testSchemaV1MigratesAndInstructionsRoundTrip() throws {
        let v1 = """
        {"schemaVersion": 1, "id": "t1", "name": "Mini",
         "params": {"start": {"name": "A"}, "dateStart": "2027-06-01", "dateEnd": "2027-06-01"},
         "days": [{"index": 1}]}
        """
        var trip = try TripCodec.decode(Data(v1.utf8))
        XCTAssertEqual(trip.schemaVersion, Trip.currentSchemaVersion)
        XCTAssertEqual(trip.days[0].instructions, [])
        XCTAssertFalse(TripValidator.validate(trip).contains { $0.code == "schema.version" })

        trip.days[0].instructions = Array(instructions.prefix(3))
        let again = try TripCodec.decode(TripCodec.encode(trip))
        XCTAssertEqual(again.days[0].instructions, trip.days[0].instructions)
        XCTAssertEqual(again.days[0].instructions[1].toward, "Sault, [S 8]")
    }

    func testUnknownManeuverDoesNotBreakTheTrip() throws {
        let json = """
        {"schemaVersion": 2, "id": "t1", "name": "Mini",
         "params": {"start": {"name": "A"}, "dateStart": "2027-06-01", "dateEnd": "2027-06-01"},
         "days": [{"index": 1, "instructions": [{"along": 10, "maneuver": "teleport", "text": "?"}]}]}
        """
        let trip = try TripCodec.decode(Data(json.utf8))
        XCTAssertEqual(trip.days[0].instructions.first?.maneuver, .straight)
    }
}
