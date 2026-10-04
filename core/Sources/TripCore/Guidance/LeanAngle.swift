import Foundation

/// Lean angle from the physics of a turn: tan(angle) = speed × rate of turn / g. Needs no calibration and does not
/// depend on how the phone is mounted: only the speed (GPS) and the rate of turn around the vertical (gyroscope).
public enum LeanAngle {
    public static let gravity = 9.81
    /// Below 15 km/h the angle is not computed (manoeuvres, U-turns, stops).
    public static let minSpeed = 15 / 3.6
    public static let maxAngle = 65.0

    /// Signed angle, degrees: negative = leaning left, positive = right. `yawRate`: rad/s around the vertical,
    /// positive when turning left (counter-clockwise seen from above).
    public static func estimate(speed: Double, yawRate: Double) -> Double {
        guard speed.isFinite, yawRate.isFinite, speed >= minSpeed else { return 0 }
        let angle = atan(speed * yawRate / gravity) * 180 / .pi
        return -min(max(angle, -maxAngle), maxAngle)
    }
}

/// What a ride shows of its lean angles: deepest left and right, bends past 20°, 30° and 40° (whole degrees).
public struct LeanSummary: Codable, Equatable, Sendable {
    public var maxLeft: Double
    public var maxRight: Double
    public var over20: Int
    public var over30: Int
    public var over40: Int

    public init(maxLeft: Double, maxRight: Double, over20: Int, over30: Int, over40: Int) {
        self.maxLeft = maxLeft
        self.maxRight = maxRight
        self.over20 = over20
        self.over30 = over30
        self.over40 = over40
    }
}

/// Live lean angle and the ride's statistics, fed with the gyroscope (about 25 times a second) and the GPS speed.
public struct LeanTracker: Equatable, Sendable {
    /// Smoothing time constant, seconds: gyroscope noise and road bumps are not angles.
    public static let smoothing = 0.4
    /// A bend starts beyond 15° and ends back under 7°; it counts once, with its deepest angle.
    public static let bendStart = 15.0
    public static let bendEnd = 7.0

    /// Smoothed angle, degrees (negative = left).
    public private(set) var current = 0.0
    public private(set) var maxLeft = 0.0
    public private(set) var maxRight = 0.0
    private var peaks: [Double] = []
    private var peak = 0.0
    private var lastTime: TimeInterval?

    public init() {}

    /// One gyroscope sample; returns the smoothed angle. `time` in seconds (any monotonic clock).
    @discardableResult
    public mutating func update(speed: Double, yawRate: Double, time: TimeInterval) -> Double {
        let raw = LeanAngle.estimate(speed: speed, yawRate: yawRate)
        let dt = lastTime.map { min(max(time - $0, 0), 1) } ?? 0
        lastTime = time
        current += (dt > 0 ? dt / (Self.smoothing + dt) : 1) * (raw - current)
        if current < 0 { maxLeft = max(maxLeft, -current) } else { maxRight = max(maxRight, current) }
        let a = abs(current)
        if a >= Self.bendStart {
            peak = max(peak, a)
        } else if a <= Self.bendEnd, peak > 0 {
            peaks.append(peak)
            peak = 0
        }
        return current
    }

    public var summary: LeanSummary {
        let all = peaks + (peak > 0 ? [peak] : [])
        return LeanSummary(maxLeft: maxLeft.rounded(), maxRight: maxRight.rounded(),
                           over20: all.filter { $0 >= 20 }.count, over30: all.filter { $0 >= 30 }.count,
                           over40: all.filter { $0 >= 40 }.count)
    }
}
