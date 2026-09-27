import Foundation

/// Road classes used to learn the rider's pace separately (SPEC §5.1).
public enum RoadClass: String, Codable, CaseIterable, Sendable {
    /// Mountain passes, hairpins.
    case curvy
    /// Secondary roads.
    case secondary
    /// Transit/link roads.
    case link
}

/// A remaining piece of route with the routing engine's expected speed.
public struct RouteSegment: Equatable, Sendable {
    public var distance: Double        // metres
    public var routingSpeed: Double    // m/s, from GraphHopper
    public var roadClass: RoadClass
    public init(distance: Double, routingSpeed: Double, roadClass: RoadClass) {
        self.distance = distance
        self.routingSpeed = routingSpeed
        self.roadClass = roadClass
    }
}

/// A planned stop ahead (fuel, meal, break) with its expected duration.
public struct PlannedStop: Equatable, Sendable {
    public var distanceAlong: Double   // metres from current position
    public var duration: TimeInterval
    public init(distanceAlong: Double, duration: TimeInterval) {
        self.distanceAlong = distanceAlong
        self.duration = duration
    }
    public static let defaultFuelDuration: TimeInterval = 10 * 60
}

/// Learns the ratio "actual speed / routing speed" per road class and predicts remaining time.
///
/// k_c = EMA(α) of the window ratio Σ actual distance / Σ expected distance,
/// fed only while moving (v > `movingThreshold`), in windows of `windowDuration` seconds.
public struct PaceEstimator: Codable, Equatable, Sendable {
    public static let alpha = 0.2
    public static let windowDuration: TimeInterval = 60
    public static let movingThreshold = 8.0 / 3.6      // 8 km/h in m/s
    public static let bounds: ClosedRange<Double> = 0.4...1.6

    public private(set) var k: [RoadClass: Double]
    private var window: [RoadClass: Window] = [:]

    struct Window: Codable, Equatable {
        var elapsed: TimeInterval = 0
        var actual: Double = 0
        var expected: Double = 0
    }

    /// - Parameter history: coefficients learnt on previous trips (default 1.0).
    public init(history: [RoadClass: Double] = [:]) {
        var k: [RoadClass: Double] = [:]
        for c in RoadClass.allCases {
            k[c] = Self.clamp(history[c] ?? 1.0)
        }
        self.k = k
    }

    static func clamp(_ v: Double) -> Double {
        min(max(v, bounds.lowerBound), bounds.upperBound)
    }

    public func coefficient(_ c: RoadClass) -> Double { k[c] ?? 1.0 }

    /// Feed one GPS sample.
    /// - Parameters:
    ///   - speed: measured speed, m/s
    ///   - routingSpeed: speed expected by the routing engine on the current segment, m/s
    ///   - dt: time since the previous sample, s
    public mutating func add(speed: Double, routingSpeed: Double, roadClass c: RoadClass, dt: TimeInterval) {
        guard dt > 0, dt < 30, speed.isFinite, routingSpeed > 0 else { return }
        guard speed > Self.movingThreshold else { return }   // stops/pauses never bias the pace
        var w = window[c] ?? Window()
        w.elapsed += dt
        w.actual += speed * dt
        w.expected += routingSpeed * dt
        if w.elapsed >= Self.windowDuration {
            let ratio = w.actual / w.expected
            let old = coefficient(c)
            k[c] = Self.clamp(old + Self.alpha * (ratio - old))
            w = Window()
        }
        window[c] = w
    }

    /// Predicted driving time for the given segments, seconds (no stops).
    public func drivingTime(_ segments: [RouteSegment]) -> TimeInterval {
        segments.reduce(0) { acc, s in
            guard s.routingSpeed > 0 else { return acc }
            return acc + s.distance / (s.routingSpeed * coefficient(s.roadClass))
        }
    }

    /// Remaining time to a target `distance` metres ahead: driving + planned stops before it.
    public func remainingTime(to distance: Double, segments: [RouteSegment], stops: [PlannedStop]) -> TimeInterval {
        var left = distance
        var partial: [RouteSegment] = []
        for s in segments where left > 0 {
            var piece = s
            piece.distance = min(s.distance, left)
            partial.append(piece)
            left -= piece.distance
        }
        let stopTime = stops.filter { $0.distanceAlong < distance }.reduce(0) { $0 + $1.duration }
        return drivingTime(partial) + stopTime
    }

    // Codable for [RoadClass: Double] keyed by raw value.
    enum CodingKeys: String, CodingKey { case k }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([String: Double].self, forKey: .k)
        var hist: [RoadClass: Double] = [:]
        for (key, v) in raw { if let rc = RoadClass(rawValue: key) { hist[rc] = v } }
        self.init(history: hist)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var raw: [String: Double] = [:]
        for (key, v) in k { raw[key.rawValue] = v }
        try c.encode(raw, forKey: .k)
    }
}
