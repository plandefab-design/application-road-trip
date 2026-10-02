import Foundation

/// Editing a stage from the map: a point touched by the rider becomes a passage of the day, placed in route order;
/// the PC then recomputes the road through the passages.
public enum RouteEdit {
    /// Where a passage at `point` goes in `day.highlights`: between the two consecutive known points of the stage
    /// (start of the track, located passages, end of the track) where it lengthens the ride the least.
    /// Passages without a position keep their place; with nothing to compare, it goes last.
    public static func insertionIndex(of point: GeoPoint, in day: TripDay) -> Int {
        // (index in highlights before which the new passage goes, position)
        var chain: [(index: Int, point: GeoPoint)] = []
        if let first = day.track?.points.first { chain.append((0, first)) }
        for (i, h) in day.highlights.enumerated() {
            if let p = h.point { chain.append((i, p)) }
        }
        if let last = day.track?.points.last { chain.append((day.highlights.count, last)) }
        guard chain.count >= 2 else { return day.highlights.count }
        var best = (cost: Double.infinity, index: day.highlights.count)
        for (a, b) in zip(chain, chain.dropFirst()) {
            let cost = Geo.distance(a.point, point) + Geo.distance(point, b.point) - Geo.distance(a.point, b.point)
            if cost < best.cost { best = (cost, b.index) }
        }
        return best.index
    }

    /// Adds a passage named `name` at `point` in route order; returns its index.
    @discardableResult
    public static func addPassage(_ name: String, at point: GeoPoint, to day: inout TripDay) -> Int {
        let index = insertionIndex(of: point, in: day)
        day.highlights.insert(Highlight(name: name, type: .viewpoint, point: point), at: index)
        return index
    }
}
