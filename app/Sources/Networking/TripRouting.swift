import Foundation
import TripCore

/// Road tracks of a trip computed on the PC (GraphHopper, no Claude). The validated stops are stages of the route:
/// the chosen restaurants and hotels go in the first pass; the fuel stops are then placed by the iPhone on real
/// stations along that track (SPEC §5.2), and a second pass routes through those stations so the navigation
/// leads to each of them.
@MainActor
enum TripRouting {
    struct Outcome {
        let ok: Bool
        let message: String
        /// The trip with its new tracks (nil when nothing came back).
        let trip: Trip?
    }

    /// A station farther than this from the track is not on the route yet: second pass.
    static let offRouteStation = 60.0

    static func finalize(_ trip: Trip, settings: AppSettings, onProgress: @escaping @MainActor (String?) -> Void) async -> Outcome {
        guard let client = CompanionClient(urlString: settings.companionURL, token: settings.companionToken) else {
            return Outcome(ok: false, message: "Companion non configuré (Réglages › Companion).", trip: nil)
        }
        do {
            // Fuel stops of an older track would pull the new one toward them: they are placed again below.
            var input = trip
            for i in input.days.indices { input.days[i].fuelStops = [] }
            let first = try await pass(input, client: client, onProgress: onProgress)
            guard var routed = first.trip else { return first }
            let fuelWarnings = routed.planFuelStops()
            if needsStationPass(routed) {
                onProgress("Passage par les stations choisies…")
                // A failure here keeps the first track: the stations stay announced, a few hundred metres aside.
                if let second = try? await pass(routed, client: client, onProgress: onProgress), var through = second.trip {
                    remeasureFuelStops(&through)
                    routed = through
                }
            }
            return Outcome(ok: true, message: ([first.message] + fuelWarnings.map { "⛽ \($0)" }).joined(separator: "\n\n"), trip: routed)
        } catch {
            return Outcome(ok: false, message: "Companion injoignable : PC allumé ? Tailscale actif ? (\(error.localizedDescription))", trip: nil)
        }
    }

    private static func pass(_ trip: Trip, client: CompanionClient, onProgress: @escaping @MainActor (String?) -> Void) async throws -> Outcome {
        let job = try await client.startFinalize(tripId: trip.id, trip: trip)
        let done = try await client.waitForJob(tripId: trip.id, jobId: job.jobId, onProgress: onProgress)
        guard done.status == "done", let reply = done.reply else {
            return Outcome(ok: false, message: "Tracé impossible : \(done.error ?? "erreur inconnue")", trip: nil)
        }
        return Outcome(ok: true, message: reply.text, trip: reply.trip)
    }

    /// true when a chosen station lies off its day's track (the road must go through it).
    static func needsStationPass(_ trip: Trip) -> Bool {
        trip.days.contains { day in
            guard let track = day.track, !track.isEmpty else { return false }
            return day.fuelStops.contains { f in (track.locate(f.point)?.lateralOffset ?? .infinity) > offRouteStation }
        }
    }

    /// Fuel stops kept as chosen, their kilometre re-read on the final track.
    private static func remeasureFuelStops(_ trip: inout Trip) {
        for i in trip.days.indices {
            guard let track = trip.days[i].track, !track.isEmpty else { continue }
            trip.days[i].fuelStops = trip.days[i].fuelStops.map { f in
                guard let m = track.locate(f.point) else { return f }
                return FuelStopRef(name: f.name, point: f.point, kmFromStart: (m.distanceAlong / 1000).rounded())
            }
        }
    }
}
