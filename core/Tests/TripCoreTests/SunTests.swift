import XCTest
@testable import TripCore

final class SunTests: XCTestCase {
    let paris = GeoPoint(lat: 48.8566, lon: 2.3522)

    func utcMinutes(_ d: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.hour, .minute], from: d)
        return Double(c.hour! * 60 + c.minute!)
    }

    /// Reference: Paris sets about 21:58 CEST (19:58 UTC) at the June solstice and 16:56 CET (15:56 UTC) at the
    /// December solstice.
    func testParisAtTheSolstices() throws {
        XCTAssertEqual(utcMinutes(try XCTUnwrap(Sun.sunset(on: "2027-06-21", at: paris))), 19 * 60 + 58, accuracy: 5)
        XCTAssertEqual(utcMinutes(try XCTUnwrap(Sun.sunset(on: "2027-12-21", at: paris))), 15 * 60 + 56, accuracy: 5)
    }

    func testPolarDayHasNoSunset() {
        XCTAssertNil(Sun.sunset(on: "2027-06-21", at: GeoPoint(lat: 78.2, lon: 15.6)))   // Svalbard, midnight sun
    }
}
