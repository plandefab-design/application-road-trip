import SwiftUI
import TripCore

struct DayRow: View {
    let trip: Trip
    let day: TripDay
    let selected: Bool
    var pace = PaceEstimator()

    /// One stage at a glance: how far, how long on the bike, when you get there.
    var body: some View {
        let timing = StageTimer.estimate(day, in: trip, pace: pace)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Étape \(day.index)").font(.headline)
                if let date = RoadBook.stageDate(day.date) { Text(date).foregroundStyle(.secondary) }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange) }
            }
            HStack(spacing: 14) {
                if let km = day.distanceKm { Label("\(Int(km.rounded())) km", systemImage: "road.lanes") }
                if let t = timing { Label(RoadBook.duration(t.riding), systemImage: "timer") }
                if let a = day.ascentM, a > 0 { Label("+\(Int(a)) m", systemImage: "mountain.2") }
            }
            .font(.subheadline.bold())
            if let t = timing, let departure = StageTimer.defaultDeparture(for: day) {
                Text("Départ \(RoadBook.clockText(departure)) → arrivée vers \(RoadBook.clockText(departure.addingTimeInterval(t.total)))"
                     + (t.stopsDuration > 0 ? " (arrêts compris : \(RoadBook.duration(t.stopsDuration)))" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !day.highlights.isEmpty {
                Text(day.highlights.prefix(4).map(\.name).joined(separator: " · ")).font(.caption)
            }
            if !day.fuelStops.isEmpty {
                Text("⛽ " + day.fuelStops.map { "km \(Int($0.kmFromStart)) \($0.name)" }.joined(separator: " · ")).font(.caption)
            }
            let chosen = trip.selectedStops(for: day)
            if !chosen.isEmpty {
                Text(chosen.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }
}

struct POIRow: View {
    let poi: POI

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(poi.name).font(.subheadline.bold())
                Spacer()
                // SPEC §0.4: every factual item shows its verification status.
                Text(poi.verification == .verified ? "vérifié" : "non vérifié")
                    .font(.caption2.bold())
                    .foregroundStyle(poi.verification == .verified ? .green : .orange)
            }
            if let a = poi.address { Text(a).font(.caption) }
            HStack {
                if let phone = poi.phone, let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                    Link(phone, destination: url).font(.caption)
                }
                if let w = poi.website, let url = URL(string: w) { Link("Site", destination: url).font(.caption) }
                if let s = poi.source, let url = URL(string: s) { Link("Source", destination: url).font(.caption) }
            }
        }
    }
}
