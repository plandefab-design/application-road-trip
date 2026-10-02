import Foundation

/// Speed-camera and hazard announcements, pure and offline: alerts are embedded in the trip by the PC.
public enum AlertGuide {
    /// Cameras are announced 500 m ahead and again 150 m before, hazards 300 m ahead.
    public static let cameraLead = 500.0
    public static let hazardLead = 300.0

    public static func lead(for kind: RoadAlertKind) -> Double { kind.isCamera ? cameraLead : hazardLead }

    /// Next alert strictly ahead of `progress`.
    public static func next(_ alerts: [RoadAlert], progress: Double)
        -> (index: Int, alert: RoadAlert, distance: Double)? {
        for (i, a) in alerts.enumerated() where a.along > progress {
            return (i, a, a.along - progress)
        }
        return nil
    }

    /// All announcements due at `progress` (alerts within their lead distance), nearest first. Keys are unique
    /// per alert: the voice service says each one once, so an alert already spoken never masks the next one.
    public static func announcements(_ alerts: [RoadAlert], progress: Double) -> [TurnGuide.Announcement] {
        var out: [TurnGuide.Announcement] = []
        for (i, a) in alerts.enumerated() where a.along > progress {
            let d = a.along - progress
            if d > cameraLead { break }            // sorted by `along`: nothing due further on
            if a.kind.isCamera && d <= FreeRideGuide.nearCamera {
                // Second warning right before the camera.
                let limit = a.maxspeed.map { ", limité à \($0)" } ?? ""
                out.append(TurnGuide.Announcement(key: "alert-\(i)-near", text: "Radar maintenant\(limit)", urgent: true))
            } else if d <= lead(for: a.kind) {
                out.append(TurnGuide.Announcement(key: "alert-\(i)", text: text(for: a, distance: d), urgent: true))
            }
        }
        return out
    }

    /// « Radar dans 500 mètres, limité à 80 » · « Attention, chutes de pierres dans 300 mètres ».
    public static func text(for alert: RoadAlert, distance: Double) -> String {
        let when = TurnGuide.lowercasingFirst(TurnGuide.spokenDistance(distance))
        switch alert.kind {
        case .speedCamera, .sectionCamera:
            // Label from the source: « radar », « radar discriminant », « zone de radar itinérant », « radar tronçon »…
            let fallback = alert.kind == .sectionCamera ? "radar tronçon" : "radar"
            let label = alert.label.lowercased().contains("radar") ? alert.label : fallback
            let limit = alert.maxspeed.map { ", limité à \($0)" } ?? ""
            return "\(sentenceCase(label)) \(when)\(limit)"
        case .redLightCamera:
            return "\(sentenceCase(alert.label.lowercased().contains("radar") ? alert.label : "radar feu rouge")) \(when)"
        case .hazard:
            return "Attention, \(alert.label) \(when)"
        }
    }
}

extension AlertGuide {
    /// A route's alerts completed with fresher ones (e.g. the iPhone's latest pack): an extra alert of the same
    /// family within `within` metres along the route of an existing one is a duplicate. Sorted by `along`.
    public static func merge(_ primary: [RoadAlert], with extra: [RoadAlert], within: Double = 60) -> [RoadAlert] {
        var out = primary
        for e in extra where !out.contains(where: { $0.kind.isCamera == e.kind.isCamera && abs($0.along - e.along) <= within }) {
            out.append(e)
        }
        return out.sorted { $0.along < $1.along }
    }

    /// Alerts re-positioned on the track from their coordinates, sorted by `along`. Trips computed by older PC
    /// versions carry distances that drift on long stages (up to 2 km on 300 km); alerts without a point, or no
    /// longer on the track (> `maxOffset`), keep their stored distance.
    public static func relocated(_ alerts: [RoadAlert], on track: Polyline, maxOffset: Double = 60) -> [RoadAlert] {
        guard track.points.count > 1 else { return alerts }
        return alerts.map { a in
            guard let p = a.point, let m = track.locate(p, hint: a.along, window: 10_000), m.lateralOffset <= maxOffset else { return a }
            var moved = a
            moved.along = m.distanceAlong
            return moved
        }
        .sorted { $0.along < $1.along }
    }

    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
