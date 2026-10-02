import SwiftUI
import TripCore

/// What was actually ridden: real track on the map and the key numbers.
struct RideSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var rides: RideStore
    @EnvironmentObject private var store: TripStore
    @State private var reuseMessage: String?
    @State private var renaming: RideLog?
    let ride: RideLog

    /// The stored version (favourite, name changed here).
    private var current: RideLog { rides.rides.first { $0.id == ride.id } ?? ride }
    private var isFavorite: Bool { current.isFavorite }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    TripMapView(content: MapContent(lines: [.init(id: "ride", points: ride.track, highlighted: true)]))
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        tile("Distance", Format.distance(ride.summary.distance), "road.lanes")
                        tile("En mouvement", Format.duration(minutes: ride.summary.movingTime / 60), "timer")
                        tile("Moyenne", "\(Int((ride.summary.averageMovingSpeed * 3.6).rounded())) km/h", "speedometer")
                        tile("Vitesse max", "\(Int((ride.summary.maxSpeed * 3.6).rounded())) km/h", "gauge.with.dots.needle.100percent")
                        tile("Virages", "\(ride.summary.bends)", "point.topleft.down.to.point.bottomright.curvepath")
                        tile("Dénivelé +", ride.summary.ascent.map { "\(Int($0.rounded())) m" } ?? "—", "mountain.2.fill")
                    }
                    if let start = ride.summary.startedAt, let end = ride.summary.endedAt {
                        Text("\(start.formatted(date: .abbreviated, time: .shortened)) → \(end.formatted(date: .omitted, time: .shortened)) · total \(Format.duration(minutes: ride.summary.totalTime / 60))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button { rides.toggleFavorite(ride) } label: {
                            Label(isFavorite ? "Favori" : "Mettre en favori", systemImage: isFavorite ? "star.fill" : "star")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(.yellow)
                        Button {
                            store.save(ride.asTrip())
                            reuseMessage = "Trip créé : Mes trips › « ⭐ … ». Touche « Préparer » puis « Rouler »."
                        } label: {
                            Label("Refaire ce trajet", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                    if let reuseMessage { Text(reuseMessage).font(.caption).foregroundStyle(.green) }
                    ShareLink(item: gpxFile(), preview: SharePreview("Trace réelle.gpx")) {
                        Label("Exporter la trace réelle (GPX)", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    Text(ride.uploaded ? "Sauvegardée sur le PC ✓" : "Sera sauvegardée sur le PC à la prochaine synchro.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .motoList()
            .navigationTitle(current.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { renaming = current } label: { Label("Renommer", systemImage: "pencil") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() } }
            }
            .renameRideAlert($renaming, rides: rides)
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.bold()).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func gpxFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(ride.id).gpx")
        let gpx = GPX.write(name: "\(current.title) — trace réelle",
                            tracks: [(name: "Trace réelle", line: Polyline(ride.track))], waypoints: [])
        try? gpx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
