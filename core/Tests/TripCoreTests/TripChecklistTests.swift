import XCTest
@testable import TripCore

final class TripChecklistTests: XCTestCase {
    func trip(withPass: Bool, checklist: [ChecklistItem] = []) -> Trip {
        let params = TripParams(start: Place(name: "A"), dateStart: "2027-06-15", dateEnd: "2027-06-16")
        let highlights = withPass ? [Highlight(name: "Col fictif", type: .pass)] : []
        return Trip(name: "T", params: params,
                    days: [TripDay(index: 1, highlights: highlights), TripDay(index: 2)], checklist: checklist)
    }

    func testDefaultsDependOnTheTrip() {
        let withPass = TripChecklist.defaults(for: trip(withPass: true)).map(\.id)
        XCTAssertTrue(withPass.contains("auto-passes") && withPass.contains("auto-passes-j1"))
        XCTAssertTrue(withPass.contains("auto-sidestore") && withPass.contains("auto-offline"))
        let flat = TripChecklist.defaults(for: trip(withPass: false)).map(\.id)
        XCTAssertFalse(flat.contains("auto-passes") || flat.contains("auto-passes-j1"))
    }

    func testMergeKeepsPlannerItemsAndDoneFlags() {
        let planner = ChecklistItem(id: "p1", label: "Réserver les hébergements", due: "J-20", done: true, auto: false)
        let merged = TripChecklist.merged(trip(withPass: false, checklist: [planner]))
        XCTAssertEqual(merged.first, planner)
        XCTAssertEqual(merged.filter { $0.label == "Réserver les hébergements" }.count, 1)
        // Idempotent: merging again adds nothing.
        var t = trip(withPass: false)
        t.checklist = merged
        XCTAssertEqual(TripChecklist.merged(t), merged)
    }

    func testDueDates() {
        XCTAssertEqual(TripChecklist.daysBefore("J-15"), 15)
        XCTAssertEqual(TripChecklist.daysBefore("j-1"), 1)
        XCTAssertEqual(TripChecklist.daysBefore("J"), 0)
        XCTAssertNil(TripChecklist.daysBefore("la veille"))
        let item = ChecklistItem(label: "x", due: "J-15")
        XCTAssertEqual(TripChecklist.dueDate(item, tripStart: "2027-06-15"), ISODate.parse("2027-05-31"))
    }
}
