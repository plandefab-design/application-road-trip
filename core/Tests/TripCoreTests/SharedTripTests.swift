import XCTest
@testable import TripCore

final class SharedTripTests: XCTestCase {
    private func senderTrip() -> Trip {
        var trip = Trip(name: "Alpes 3 jours", status: .ready, params: Fixtures.params(),
                        days: [TripDay(index: 1, distanceKm: 250, track: Fixtures.northLine(km: 5)),
                               TripDay(index: 2, distanceKm: 310.5)],
                        checklist: [ChecklistItem(label: "Vérifier l'état du col", due: "J-1", done: true),
                                    ChecklistItem(label: "Charger la batterie", due: "J-1", done: true)],
                        offlinePack: OfflinePack(tiles: "maplibre-offline", radars: "radars.json", integrity: .ok),
                        updatedAt: "2026-10-01T10:00:00Z")
        trip.mustCheck = ["Col fermé ?"]
        return trip
    }

    func testSummaryCountsDaysAndKilometres() {
        let summary = SharedTripRules.summary(of: senderTrip())
        XCTAssertEqual(summary.days, 2)
        XCTAssertEqual(summary.distanceKm, 560.5, accuracy: 1e-9)
    }

    func testImportedCopyHasItsOwnIdentityAndNoOfflineClaim() {
        let original = senderTrip()
        let copy = SharedTripRules.prepareForImport(original)
        XCTAssertNotEqual(copy.id, original.id, "never overwrites or syncs onto the sender's trip")
        XCTAssertNil(copy.updatedAt)
        XCTAssertEqual(copy.offlinePack, OfflinePack())
        XCTAssertEqual(copy.offlinePack.integrity, .unknown)
    }

    func testImportedCopyAsksForTheMapsAndTheChecklistAgain() {
        let copy = SharedTripRules.prepareForImport(senderTrip())
        XCTAssertEqual(copy.status, .validated, "ready/active/done are the sender's state, not the friend's")
        XCTAssertTrue(copy.checklist.allSatisfy { !$0.done })
        XCTAssertEqual(copy.checklist.count, 2)
    }

    func testRoadBookContentSurvivesTheTrip() {
        let original = senderTrip()
        let copy = SharedTripRules.prepareForImport(original)
        XCTAssertEqual(copy.name, original.name)
        XCTAssertEqual(copy.days, original.days)
        XCTAssertEqual(copy.mustCheck, original.mustCheck)
        XCTAssertEqual(copy.params, original.params)
    }

    func testEarlierStatusesAreKept() {
        for status in [TripStatus.draft, .proposed, .validated] {
            var trip = senderTrip()
            trip.status = status
            XCTAssertEqual(SharedTripRules.prepareForImport(trip).status, status)
        }
    }

    func testTwoImportsOfTheSameTripAreTwoTrips() {
        let original = senderTrip()
        XCTAssertNotEqual(SharedTripRules.prepareForImport(original).id, SharedTripRules.prepareForImport(original).id)
    }

    func testTheFileSurvivesTheCodecRoundTripAndStaysUnderTheServerLimit() throws {
        let data = try TripCodec.encode(senderTrip())
        XCTAssertLessThan(data.count, SharedTripRules.maxFileBytes)
        let back = try TripCodec.decode(data)
        XCTAssertEqual(back.name, "Alpes 3 jours")
        XCTAssertEqual(back.days.count, 2)
    }
}
