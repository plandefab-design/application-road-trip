import XCTest
@testable import TripCore

final class MaintenanceBookTests: XCTestCase {
    let today = ISODate.parse("2027-06-01")!

    func book(odometer: Double, lastKm: Double, intervalKm: Double?, months: Int? = nil, lastDate: String = "2027-06-01") -> MaintenanceBook {
        MaintenanceBook(bikeId: "b", odometerKm: odometer,
                        items: [MaintenanceItem(id: "x", label: "Test", intervalKm: intervalKm, intervalMonths: months,
                                                lastDoneKm: lastKm, lastDoneDate: lastDate)])
    }

    func testLevelsByKm() {
        // Interval 6 000 km, soft window max(300, 600) = 600 km.
        XCTAssertEqual(book(odometer: 10_000, lastKm: 10_000, intervalKm: 6_000).status(of: .init(id: "x", label: "", intervalKm: 6_000, lastDoneKm: 10_000), today: today).level, .ok)
        let b = book(odometer: 15_500, lastKm: 10_000, intervalKm: 6_000)
        XCTAssertEqual(b.status(of: b.items[0], today: today).level, .soon)
        XCTAssertEqual(b.status(of: b.items[0], today: today).remainingKm, 500)
        let due = book(odometer: 16_100, lastKm: 10_000, intervalKm: 6_000)
        XCTAssertEqual(due.status(of: due.items[0], today: today).level, .due)
        XCTAssertEqual(due.status(of: due.items[0], today: today).text, "en retard de 100 km")
        let late = book(odometer: 17_000, lastKm: 10_000, intervalKm: 6_000)
        XCTAssertEqual(late.status(of: late.items[0], today: today).level, .overdue)
    }

    func testLevelsByDate() {
        let fresh = book(odometer: 0, lastKm: 0, intervalKm: nil, months: 24, lastDate: "2027-05-01")
        XCTAssertEqual(fresh.status(of: fresh.items[0], today: today).level, .ok)
        let soon = book(odometer: 0, lastKm: 0, intervalKm: nil, months: 24, lastDate: "2025-06-20")
        XCTAssertEqual(soon.status(of: soon.items[0], today: today).level, .soon)
        let late = book(odometer: 0, lastKm: 0, intervalKm: nil, months: 12, lastDate: "2025-01-01")
        XCTAssertEqual(late.status(of: late.items[0], today: today).level, .overdue)
    }

    func testRidesAdvanceTheOdometerAndMarkDoneResets() {
        var b = book(odometer: 1_000, lastKm: 1_000, intervalKm: 500)
        b.addRide(km: 520)
        b.addRide(km: -5)                     // ignored
        XCTAssertEqual(b.odometerKm, 1_520)
        XCTAssertEqual(b.status(of: b.items[0], today: today).level, .due)
        b.markDone("x", today: "2027-06-01")
        XCTAssertEqual(b.items[0].lastDoneKm, 1_520)
        XCTAssertEqual(b.status(of: b.items[0], today: today).level, .ok)
    }

    func testDueDuringTripAndAttentionOrder() {
        var b = MaintenanceBook.starter(bikeId: "b", category: .roadster, odometerKm: 20_000, today: "2027-06-01")
        XCTAssertTrue(b.attention(today: today).isEmpty)                        // everything just done
        let dueSoon = b.dueDuringTrip(tripKm: 1_200, today: today).map(\.id)
        XCTAssertTrue(dueSoon.contains("chain-lube") && dueSoon.contains("tyres"))
        XCTAssertFalse(dueSoon.contains("oil"))
        b.addRide(km: 6_500)
        let first = b.attention(today: today).first
        XCTAssertEqual(first?.status.level, .overdue)                            // most urgent first
    }

    func testStarterDependsOnCategory() {
        let enduro = MaintenanceBook.starter(bikeId: "b", category: .enduro, today: "2027-06-01")
        XCTAssertTrue(enduro.items.contains { $0.id == "spokes" })
        XCTAssertEqual(enduro.items.first { $0.id == "chain-lube" }?.intervalKm, 300)
        let road = MaintenanceBook.starter(bikeId: "b", category: .sport, today: "2027-06-01")
        XCTAssertFalse(road.items.contains { $0.id == "spokes" })
    }

    func testLibertyRiderItemsAreAllThere() {
        let ids = Set(MaintenanceBook.starter(bikeId: "b", category: .roadster, today: "2027-06-01").items.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["tyre-pressure", "tyres", "chain-lube", "chain-check", "chain-kit", "brake-pads",
                                          "oil", "brake-fluid", "coolant", "service"]))
    }

    func testExistingBookIsCompletedWithoutLosingTheRidersSettings() {
        let old = MaintenanceBook(bikeId: "b", odometerKm: 15_000, items: [
            MaintenanceItem(id: "tyres", label: "Pneus : usure et pression", intervalKm: 800, lastDoneKm: 14_000),
            MaintenanceItem(id: "mine", label: "Ma vérif", intervalKm: 300),
        ])
        let book = old.completed(category: .roadster, today: "2027-06-01")
        let tyres = book.items.first { $0.id == "tyres" }
        XCTAssertEqual(tyres?.label, "Usure des pneus")
        XCTAssertEqual(tyres?.intervalKm, 800)                     // the rider's interval
        XCTAssertEqual(tyres?.lastDoneKm, 14_000)                  // and history kept
        XCTAssertTrue(book.items.contains { $0.id == "mine" })
        XCTAssertEqual(book.items.first { $0.id == "tyre-pressure" }?.lastDoneKm, 15_000)   // new item counted from now
        XCTAssertEqual(book.completed(category: .roadster, today: "2027-07-01"), book)    // idempotent
    }
}
