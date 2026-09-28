import Foundation

/// Turn-by-turn guidance, pure and offline: uses the instructions stored in the trip (computed on the PC
/// before departure), positioned by distance along the day's track. No network, no AI while riding.
public enum TurnGuide {
    public struct Announcement: Equatable, Sendable {
        /// Unique per instruction and phase: the voice service says each key once.
        public let key: String
        public let text: String
    }

    /// Depart, straight-on and via points are silent; arrival is handled by the end-of-day announcement.
    public static func isAnnounced(_ maneuver: Maneuver) -> Bool {
        ![.depart, .straight, .via, .arrive].contains(maneuver)
    }

    /// Next announced maneuver strictly ahead of `progress` (metres along the track).
    public static func next(_ instructions: [TurnInstruction], progress: Double)
        -> (index: Int, instruction: TurnInstruction, distance: Double)? {
        for (i, ins) in instructions.enumerated() where isAnnounced(ins.maneuver) && ins.along > progress {
            return (i, ins, ins.along - progress)
        }
        return nil
    }

    /// Lead distances for a speed in m/s: about 20 s ahead (at least 300 m) and 6 s ahead (at least 60 m).
    public static func thresholds(speed: Double) -> (far: Double, near: Double) {
        let v = max(0, speed.isFinite ? speed : 0)
        return (far: max(300, v * 20), near: max(60, v * 6))
    }

    /// Announcement due at `progress`, if any: « Dans 300 mètres, tournez à gauche… » then « Tournez à gauche… ».
    public static func announcement(_ instructions: [TurnInstruction], progress: Double, speed: Double) -> Announcement? {
        guard let n = next(instructions, progress: progress) else { return nil }
        let t = thresholds(speed: speed)
        if n.distance <= t.near {
            return Announcement(key: "turn-\(n.index)-now", text: n.instruction.text)
        }
        if n.distance <= t.far {
            return Announcement(key: "turn-\(n.index)-soon",
                                text: "\(spokenDistance(n.distance)), \(lowercasingFirst(n.instruction.text))")
        }
        return nil
    }

    /// « Dans 300 mètres » (rounded to 50 m) or « Dans 1,5 kilomètre ».
    public static func spokenDistance(_ metres: Double) -> String {
        if metres < 950 {
            let rounded = max(50, Int((metres / 50).rounded()) * 50)
            return "Dans \(rounded) mètres"
        }
        let km = (metres / 100).rounded() / 10
        let value = km == km.rounded() ? String(Int(km)) : String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",")
        return "Dans \(value) kilomètre\(km >= 2 ? "s" : "")"
    }

    public static func lowercasingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }
}
