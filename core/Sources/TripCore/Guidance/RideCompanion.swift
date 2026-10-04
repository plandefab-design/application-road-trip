import Foundation

// MARK: - Speed limits

public enum SpeedLimits {
    /// Known legal limit at `progress` (metres along the track), nil when unknown. Ranges sorted by `from`.
    public static func limit(_ ranges: [SpeedLimitRange], at progress: Double) -> Int? {
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = ranges[mid]
            if progress < r.from { hi = mid - 1 } else if progress > r.to { lo = mid + 1 } else { return r.kmh }
        }
        return nil
    }

    /// Over the limit with a small GPS tolerance (5 km/h, or 5 % above 100 km/h).
    public static func isOver(speedKmh: Double, limit: Int) -> Bool {
        speedKmh > Double(limit) + max(5, Double(limit) * 0.05)
    }
}

// MARK: - Breaks and pauses

/// Riding time since the last real break (stopped ≥ 5 min), fed with every GPS fix.
public struct BreakTracker: Equatable, Sendable {
    public static let breakDuration: TimeInterval = 5 * 60
    public static let movingSpeed = 2.0   // m/s

    public private(set) var ridingSinceBreak: TimeInterval = 0
    private var stoppedFor: TimeInterval = 0

    public init() {}

    public mutating func update(speed: Double, dt: TimeInterval) {
        guard dt > 0, dt < 120 else { return }          // ignore gaps (tunnel, app suspended)
        if speed >= Self.movingSpeed {
            ridingSinceBreak += dt
            stoppedFor = 0
        } else {
            stoppedFor += dt
            if stoppedFor >= Self.breakDuration { ridingSinceBreak = 0 }
        }
    }
}

public enum PauseAdvisor {
    /// Suggest a pause after 1 h 30 of riding (SPEC: pauses every 1 h 30 to 2 h).
    public static let ridingBeforePause: TimeInterval = 90 * 60
    public static let lookAhead = 15_000.0

    /// Spots re-positioned on the track from their coordinates (same drift fix as AlertGuide.relocated).
    public static func relocated(_ spots: [PauseSpot], on track: Polyline, maxOffset: Double = 500) -> [PauseSpot] {
        guard track.points.count > 1 else { return spots }
        return spots.map { s in
            guard let p = s.point, let m = track.locate(p, hint: s.along, window: 10_000), m.lateralOffset <= maxOffset else { return s }
            var moved = s
            moved.along = m.distanceAlong
            return moved
        }
        .sorted { $0.along < $1.along }
    }

    /// Best spot in the next 15 km once a pause is due: a café first, then a viewpoint, then water; nearest of a kind.
    public static func suggestion(_ pauses: [PauseSpot], progress: Double, ridingSinceBreak: TimeInterval)
        -> (spot: PauseSpot, distance: Double)? {
        guard ridingSinceBreak >= ridingBeforePause else { return nil }
        let ahead = pauses.filter { $0.along > progress + 200 && $0.along <= progress + lookAhead }
        for kind in [PauseKind.cafe, .viewpoint, .water] {
            if let spot = ahead.filter({ $0.kind == kind }).min(by: { $0.along < $1.along }) {
                return (spot, spot.along - progress)
            }
        }
        return nil
    }
}

// MARK: - Ride summary

public struct RideSummary: Codable, Equatable, Sendable {
    public var distance: Double          // metres
    public var movingTime: TimeInterval
    public var totalTime: TimeInterval
    public var maxSpeed: Double          // m/s
    public var ascent: Double?           // metres, nil without altitude
    public var bends: Int
    public var startedAt: Date?
    public var endedAt: Date?
    /// Lean angles measured on the bike (gyroscope); nil for rides recorded before, or without gyroscope.
    public var lean: LeanSummary?

    public var averageMovingSpeed: Double { movingTime > 0 ? distance / movingTime : 0 }

    /// Stats of a recorded ride. `speeds` in m/s (negative = unknown), same length as `points` and `times`.
    public static func summarize(points: [GeoPoint], times: [Date], speeds: [Double]) -> RideSummary {
        let n = min(points.count, times.count, speeds.count)
        var distance = 0.0, moving = 0.0, maxSpeed = 0.0
        var ascent = 0.0, hasAltitude = false
        var lastEle: Double?
        for i in 0..<n {
            if speeds[i] >= 0 && speeds[i] < 90 { maxSpeed = max(maxSpeed, speeds[i]) }   // ignore GPS spikes > 324 km/h
            if let e = points[i].ele {
                hasAltitude = true
                if let last = lastEle {
                    if e - last >= 3 { ascent += e - last; lastEle = e } else if last - e >= 3 { lastEle = e }  // 3 m hysteresis
                } else { lastEle = e }
            }
            guard i > 0 else { continue }
            let d = Geo.distance(points[i - 1], points[i])
            let dt = times[i].timeIntervalSince(times[i - 1])
            distance += d
            if dt > 0, dt < 120, d / dt >= BreakTracker.movingSpeed { moving += dt }
        }
        return RideSummary(distance: distance, movingTime: moving,
                           totalTime: n > 1 ? times[n - 1].timeIntervalSince(times[0]) : 0,
                           maxSpeed: maxSpeed, ascent: hasAltitude ? ascent : nil,
                           bends: bends(in: Polyline(Array(points.prefix(n)))),
                           startedAt: n > 0 ? times[0] : nil, endedAt: n > 0 ? times[n - 1] : nil)
    }

    /// Bends: heading turns by more than 45° within 150 m (sampled every 20 m); each counted once.
    public static func bends(in line: Polyline) -> Int {
        guard line.length > 60 else { return 0 }
        let step = 20.0, window = 150.0
        var headings: [Double] = []
        var d = 0.0
        while d + step <= line.length {
            if let a = line.point(at: d), let b = line.point(at: d + step) { headings.append(Geo.bearing(a, b)) }
            d += step
        }
        let span = Int(window / step)
        var count = 0, i = 0
        while i + span < headings.count {
            var turn = 0.0
            for k in i..<(i + span) {
                var delta = headings[k + 1] - headings[k]
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                turn += delta
            }
            if abs(turn) >= 45 { count += 1; i += span } else { i += 1 }
        }
        return count
    }
}

// MARK: - Sync

public enum TripSync {
    /// Which trips to send to the PC, to fetch and to delete on the PC, from their `updatedAt` (ISO 8601 UTC
    /// compares as text). The most recent wins; a trip missing on one side is copied there, unless the rider
    /// deleted it on the iPhone (`deleted`): then it is deleted on the PC too, never brought back.
    public static func plan(local: [String: String?], remote: [String: String?], deleted: Set<String> = [])
        -> (push: [String], pull: [String], delete: [String]) {
        var push: [String] = [], pull: [String] = [], delete: [String] = []
        for id in Set(local.keys).union(remote.keys).sorted() {
            let onPhone = local.keys.contains(id), onPC = remote.keys.contains(id)
            let l = local[id] ?? nil, r = remote[id] ?? nil
            if deleted.contains(id) && !onPhone {
                if onPC { delete.append(id) }
            } else if onPhone && !onPC {
                push.append(id)
            } else if onPC && !onPhone {
                pull.append(id)
            } else if let l, let r {
                if l > r { push.append(id) } else if l < r { pull.append(id) }
            } else if l != nil {
                push.append(id)
            } else if r != nil {
                pull.append(id)
            }
        }
        return (push, pull, delete)
    }

    public static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
