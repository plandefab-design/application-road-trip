import Foundation
import TripCore

/// Open-Meteo (no key, CC BY 4.0): hourly forecasts for route samples, one request for all points.
struct WeatherClient {
    func forecasts(for samples: [RouteWeather.Sample], timeout: TimeInterval) async throws -> [RouteWeather.Hourly] {
        guard let url = RouteWeather.requestURL(samples) else { return [] }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: timeout))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try RouteWeather.parse(data)
    }

    /// Before departure: hazards for every traced day, assuming a 9:00 start on the day's date.
    /// Returns French lines for the trip screen.
    func tripReport(_ trip: Trip, pace: PaceEstimator, now: Date = Date()) async -> [String] {
        var lines: [String] = []
        for day in trip.days {
            guard let track = day.track, !track.isEmpty else { continue }
            guard let start = Self.departure(of: day, trip: trip) else {
                lines.append("Jour \(day.index) : date inconnue.")
                continue
            }
            if start > now.addingTimeInterval(15 * 86_400) {
                lines.append("Jour \(day.index) : trop tôt (prévisions à 16 jours).")
                continue
            }
            let samples = RouteWeather.samples(route: track)
            let etas = RouteWeather.etas(samples: samples, route: track, progress: 0, start: max(start, now), pace: pace)
            do {
                let forecasts = try await forecasts(for: samples, timeout: 15)
                let hazards = RouteWeather.hazards(samples: samples, etas: etas, forecasts: forecasts)
                if hazards.isEmpty {
                    lines.append("Jour \(day.index) : rien à signaler (pluie, vent, froid, visibilité).")
                } else {
                    for h in hazards.prefix(4) {
                        lines.append("Jour \(day.index) : \(h.summary) au km \(Int(h.along / 1000)) vers \(Self.hour(h.eta)).")
                    }
                    if hazards.count > 4 { lines.append("Jour \(day.index) : … et \(hazards.count - 4) autre(s) point(s).") }
                }
            } catch {
                lines.append("Jour \(day.index) : météo indisponible (pas de réseau ?).")
            }
        }
        return lines
    }

    /// Day date (or trip start + index − 1) at 9:00 local time.
    static func departure(of day: TripDay, trip: Trip) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!          // ISODate.parse returns UTC midnight
        let dayDate = day.date.flatMap(ISODate.parse)
            ?? ISODate.parse(trip.params.dateStart).flatMap { utc.date(byAdding: .day, value: day.index - 1, to: $0) }
        guard let dayDate else { return nil }
        let c = utc.dateComponents([.year, .month, .day], from: dayDate)
        return Calendar.current.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 9))
    }

    static func hour(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
