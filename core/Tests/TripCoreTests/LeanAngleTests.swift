import XCTest
@testable import TripCore

/// Lean angle from speed and rate of turn (physics of a steady turn). Synthetic samples only.
final class LeanAngleTests: XCTestCase {
    func testSteadyTurnPhysics() {
        // 90 km/h (25 m/s) turning left at 0.3924 rad/s: tan = 25 × 0.3924 / 9.81 = 1 → 45° to the left.
        XCTAssertEqual(LeanAngle.estimate(speed: 25, yawRate: 0.3924), -45, accuracy: 0.1)
        XCTAssertEqual(LeanAngle.estimate(speed: 25, yawRate: -0.3924), 45, accuracy: 0.1)
        XCTAssertEqual(LeanAngle.estimate(speed: 3, yawRate: 0.5), 0)              // walking pace: not an angle
        XCTAssertEqual(LeanAngle.estimate(speed: 60, yawRate: 3), -LeanAngle.maxAngle)  // gyroscope spike capped
    }

    /// Two bends at 25 Hz: a right one up to about 35°, a left one up to about 22°.
    func testRideStatistics() {
        var tracker = LeanTracker()
        var t = 0.0
        func ride(seconds: Double, speed: Double, angle: Double) {
            let yaw = -tan(angle * .pi / 180) * LeanAngle.gravity / speed      // right = negative rate of turn
            for _ in 0..<Int(seconds * 25) { tracker.update(speed: speed, yawRate: yaw, time: t); t += 0.04 }
        }
        ride(seconds: 2, speed: 20, angle: 0)
        ride(seconds: 3, speed: 20, angle: 35)
        ride(seconds: 2, speed: 20, angle: 0)
        ride(seconds: 3, speed: 15, angle: -22)
        ride(seconds: 2, speed: 15, angle: 0)
        let s = tracker.summary
        XCTAssertEqual(s.maxRight, 35, accuracy: 1)
        XCTAssertEqual(s.maxLeft, 22, accuracy: 1)
        XCTAssertEqual([s.over20, s.over30, s.over40], [2, 1, 0])
        XCTAssertEqual(tracker.current, 0, accuracy: 0.5)
    }

    /// Property: a single jolt (one sample) never makes a bend nor a record.
    func testJoltIsSmoothedOut() {
        var tracker = LeanTracker()
        for i in 0..<50 { tracker.update(speed: 20, yawRate: 0, time: Double(i) * 0.04) }
        tracker.update(speed: 20, yawRate: 1.5, time: 2.0)
        for i in 1...50 { tracker.update(speed: 20, yawRate: 0, time: 2.0 + Double(i) * 0.04) }
        XCTAssertLessThan(max(tracker.summary.maxLeft, tracker.summary.maxRight), 15)
        XCTAssertEqual(tracker.summary.over20, 0)
    }
}
