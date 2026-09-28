import XCTest
@testable import TripCore

final class TurnGuideTests: XCTestCase {
    // Fixture instructions (synthetic positions and texts).
    let instructions = [
        TurnInstruction(along: 0, maneuver: .depart, text: "Continuez sur Rue A"),
        TurnInstruction(along: 800, maneuver: .straight, text: "Continuez sur D1"),
        TurnInstruction(along: 1_500, maneuver: .turnLeft, text: "Tournez à gauche sur D2", street: "D2"),
        TurnInstruction(along: 1_600, maneuver: .via, text: "Point de passage atteint"),
        TurnInstruction(along: 4_000, maneuver: .roundabout, text: "Au rond-point, prenez la 2e sortie", exit: 2),
        TurnInstruction(along: 9_000, maneuver: .arrive, text: "Arrivée"),
    ]

    func testNextSkipsSilentAndPassedManeuvers() {
        XCTAssertEqual(TurnGuide.next(instructions, progress: 0)?.index, 2)
        XCTAssertEqual(TurnGuide.next(instructions, progress: 1_500)?.index, 4)
        XCTAssertEqual(TurnGuide.next(instructions, progress: 1_200)?.distance, 300)
        XCTAssertNil(TurnGuide.next(instructions, progress: 4_000))   // only arrival left: silent
    }

    func testFarThenNearAnnouncement() {
        XCTAssertNil(TurnGuide.announcement(instructions, progress: 0, speed: 10))          // 1 500 m ahead
        let soon = TurnGuide.announcement(instructions, progress: 1_250, speed: 10)          // 250 m, far = 300
        XCTAssertEqual(soon, .init(key: "turn-2-soon", text: "Dans 250 mètres, tournez à gauche sur D2"))
        let now = TurnGuide.announcement(instructions, progress: 1_450, speed: 10)           // 50 m, near = 60
        XCTAssertEqual(now, .init(key: "turn-2-now", text: "Tournez à gauche sur D2", urgent: true))
    }

    func testLeadDistanceGrowsWithSpeed() {
        XCTAssertEqual(TurnGuide.thresholds(speed: 0).far, 300)
        XCTAssertEqual(TurnGuide.thresholds(speed: 30).far, 600)     // 108 km/h → 20 s ahead
        XCTAssertEqual(TurnGuide.thresholds(speed: 30).near, 180)
        XCTAssertNotNil(TurnGuide.announcement(instructions, progress: 1_000, speed: 30))   // 500 m ahead at speed
    }

    func testSpokenDistance() {
        XCTAssertEqual(TurnGuide.spokenDistance(10), "Dans 50 mètres")
        XCTAssertEqual(TurnGuide.spokenDistance(312), "Dans 300 mètres")
        XCTAssertEqual(TurnGuide.spokenDistance(1_000), "Dans 1 kilomètre")
        XCTAssertEqual(TurnGuide.spokenDistance(1_540), "Dans 1,5 kilomètre")
        XCTAssertEqual(TurnGuide.spokenDistance(2_000), "Dans 2 kilomètres")
    }

    /// Invariant: riding the whole day at any speed, every announced maneuver gets exactly one
    /// « now » announcement, never before its « soon » one, and silent maneuvers are never spoken.
    func testEachManeuverAnnouncedOnceInOrder() {
        for speed in [5.0, 15, 30] {
            var spoken: [String] = []
            var progress = 0.0
            while progress <= 9_000 {
                if let a = TurnGuide.announcement(instructions, progress: progress, speed: speed), !spoken.contains(a.key) {
                    spoken.append(a.key)
                }
                progress += speed      // one GPS fix per second
            }
            XCTAssertEqual(spoken.filter { $0.hasSuffix("-now") }, ["turn-2-now", "turn-4-now"], "speed \(speed)")
            for i in [2, 4] {
                if let soon = spoken.firstIndex(of: "turn-\(i)-soon"), let now = spoken.firstIndex(of: "turn-\(i)-now") {
                    XCTAssertLessThan(soon, now)
                }
            }
            XCTAssertFalse(spoken.contains { $0.hasPrefix("turn-1-") || $0.hasPrefix("turn-3-") || $0.hasPrefix("turn-5-") })
        }
    }

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
