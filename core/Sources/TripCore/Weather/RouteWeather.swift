import Foundation

/// Weather along the route (SPEC §5.3): one point every 15 km, forecast at the estimated passing time,
/// alerts on rain, gusts, cold and poor visibility. Online enrichment only: never required to navigate.
public enum RouteWeather {
    public static let spacing = 15_000.0

    // SPEC §5.3 thresholds.
    public static let rainThreshold = 0.5         // mm/h
    public static let gustThreshold = 60.0        // km/h
    public static let coldThreshold = 5.0         // °C
    public static let visibilityThreshold = 1_000.0 // m

    public struct Sample: Equatable, Sendable {
        public let along: Double
        public let point: GeoPoint
    }

    public struct Hourly: Equatable, Sendable {
        public let times: [Date]
        public let precipitation: [Double?]
        public let gusts: [Double?]
        public let temperature: [Double?]
        public let visibility: [Double?]

        public init(times: [Date], precipitation: [Double?], gusts: [Double?], temperature: [Double?], visibility: [Double?]) {
            self.times = times
            self.precipitation = precipitation
            self.gusts = gusts
            self.temperature = temperature
            self.visibility = visibility
        }

        /// Index of the forecast hour containing `date`, nil when outside the forecast range.
        func index(at date: Date) -> Int? {
            guard let first = times.first, let last = times.last,
                  date >= first, date < last.addingTimeInterval(3_600) else { return nil }
            return times.lastIndex { $0 <= date }
        }
    }

    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case rain, wind, cold, fog

        public var label: String {
            switch self {
            case .rain: "Pluie"
            case .wind: "Rafales"
            case .cold: "Froid"
            case .fog: "Visibilité réduite"
            }
        }
    }

    public struct Hazard: Equatable, Sendable {
        public let along: Double
        public let eta: Date
        public let kinds: [Kind]
        public let precipitation: Double?
        public let gusts: Double?
        public let temperature: Double?

        /// « Pluie 2 mm/h, rafales 70 km/h »
        public var summary: String {
            kinds.map { kind -> String in
                switch kind {
                case .rain: precipitation.map { String(format: "Pluie %.1f mm/h", $0).replacingOccurrences(of: ".", with: ",") } ?? kind.label
                case .wind: gusts.map { "Rafales \(Int($0.rounded())) km/h" } ?? kind.label
                case .cold: temperature.map { "\(Int($0.rounded())) °C" } ?? kind.label
                case .fog: kind.label
                }
            }.joined(separator: ", ")
        }
    }

    // MARK: Sampling

    /// A point every `spacing` metres from `progress` to the end (plus the end), and `extra` distances
    /// (passes, stops), sorted and de-duplicated within 2 km. Limited to `maxCount` points.
    public static func samples(route: Polyline, from progress: Double = 0, extra: [Double] = [],
                               maxCount: Int = 40) -> [Sample] {
        guard route.length > 0 else { return [] }
        var distances = Array(stride(from: max(0, progress), through: route.length, by: spacing)) + [route.length]
        distances += extra.filter { $0 > progress && $0 <= route.length }
        distances.sort()
        var kept: [Double] = []
        for d in distances where kept.last.map({ d - $0 >= 2_000 }) ?? true { kept.append(d) }
        return kept.prefix(maxCount).compactMap { d in route.point(at: d).map { Sample(along: d, point: $0) } }
    }

    // MARK: Open-Meteo

    /// One request for every sample (Open-Meteo accepts coordinate lists and returns one forecast each).
    public static func requestURL(_ samples: [Sample], forecastDays: Int = 16) -> URL? {
        guard !samples.isEmpty else { return nil }
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: samples.map { String(format: "%.4f", $0.point.lat) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: samples.map { String(format: "%.4f", $0.point.lon) }.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: "precipitation,wind_gusts_10m,temperature_2m,visibility"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "GMT"),
            URLQueryItem(name: "forecast_days", value: String(min(16, max(1, forecastDays)))),
        ]
        return comps.url
    }

    /// Parses an Open-Meteo response: an object for one location, an array for several.
    public static func parse(_ data: Data) throws -> [Hourly] {
        struct Location: Decodable {
            struct Series: Decodable {
                let time: [Double]
                let precipitation: [Double?]?
                let wind_gusts_10m: [Double?]?
                let temperature_2m: [Double?]?
                let visibility: [Double?]?
            }
            let hourly: Series
        }
        let decoder = JSONDecoder()
        let locations = (try? decoder.decode([Location].self, from: data)) ?? [try decoder.decode(Location.self, from: data)]
        return locations.map { loc in
            let s = loc.hourly
            let n = s.time.count
            func column(_ values: [Double?]?) -> [Double?] { values ?? Array(repeating: nil, count: n) }
            return Hourly(times: s.time.map { Date(timeIntervalSince1970: $0) },
                          precipitation: column(s.precipitation), gusts: column(s.wind_gusts_10m),
                          temperature: column(s.temperature_2m), visibility: column(s.visibility))
        }
    }

    // MARK: Alerts

    /// Weather hazards at each sample's passing time (`etas[i]` for `samples[i]`), in route order.
    public static func hazards(samples: [Sample], etas: [Date], forecasts: [Hourly]) -> [Hazard] {
        zip(zip(samples, etas), forecasts).compactMap { pair, forecast -> Hazard? in
            let (sample, eta) = pair
            guard let i = forecast.index(at: eta) else { return nil }
            let rain = forecast.precipitation[safe: i] ?? nil
            let gust = forecast.gusts[safe: i] ?? nil
            let temp = forecast.temperature[safe: i] ?? nil
            let vis = forecast.visibility[safe: i] ?? nil
            var kinds: [Kind] = []
            if let rain, rain > rainThreshold { kinds.append(.rain) }
            if let gust, gust > gustThreshold { kinds.append(.wind) }
            if let temp, temp < coldThreshold { kinds.append(.cold) }
            if let vis, vis < visibilityThreshold { kinds.append(.fog) }
            guard !kinds.isEmpty else { return nil }
            return Hazard(along: sample.along, eta: eta, kinds: kinds, precipitation: rain, gusts: gust, temperature: temp)
        }
    }

    /// Estimated passing time at each sample, from `start` at `progress`, with the rider's pace.
    public static func etas(samples: [Sample], route: Polyline, progress: Double, start: Date, pace: PaceEstimator) -> [Date] {
        let ahead = SegmentBuilder.remaining(SegmentBuilder.segments(for: route), after: progress)
        return samples.map { s in
            start.addingTimeInterval(pace.remainingTime(to: max(0, s.along - progress), segments: ahead, stops: []))
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
