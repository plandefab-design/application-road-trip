import Foundation

/// The weather of the past years at a place (Open-Meteo historical archive, CC BY 4.0), indexed by day of the year:
/// the same week of every year in a few lookups.
public struct Climate: Sendable {
    public struct Day: Equatable, Sendable {
        public let day: CalendarDay
        /// Rain (mm), morning low and afternoon high (°C).
        public let rain: Double, low: Double, high: Double

        public init(day: CalendarDay, rain: Double, low: Double, high: Double) {
            self.day = day
            self.rain = rain
            self.low = low
            self.high = high
        }
    }

    public struct Stats: Equatable, Sendable {
        /// Share of days with at least 1 mm of rain.
        public let rain: Double
        /// Mean morning low and afternoon high, °C.
        public let low: Double, high: Double
    }

    /// Years of history asked for (the last full years).
    public static let years = 6
    public static let archiveURL = "https://archive-api.open-meteo.com/v1/archive"
    static let rainyMM = 1.0

    private let byDay: [[Day]]          // index = day of the year, 1…365 (31 December of leap years with 30)

    public init(_ days: [Day]) {
        var byDay = [[Day]](repeating: [], count: 366)
        for d in days { byDay[min(d.day.dayOfYear, 365)].append(d) }
        self.byDay = byDay
    }

    /// The same week of the year (± `halfWidth` days around `day`) over every year; nil with fewer than 10 days known.
    public func stats(_ day: CalendarDay, halfWidth: Int = 3) -> Stats? {
        let doy = min(day.dayOfYear, 365)
        var rows: [Day] = []
        for k in -halfWidth...halfWidth { rows += byDay[(doy - 1 + k + 365) % 365 + 1] }
        guard rows.count >= 10 else { return nil }
        let n = Double(rows.count)
        return Stats(rain: Double(rows.filter { $0.rain >= Climate.rainyMM }.count) / n,
                     low: rows.reduce(0) { $0 + $1.low } / n, high: rows.reduce(0) { $0 + $1.high } / n)
    }

    // MARK: Open-Meteo archive

    /// The place asked for: rounded to 0.05° (≈ 5 km), so the stages of an area share one request and one cache.
    public static func place(_ p: GeoPoint) -> GeoPoint {
        GeoPoint(lat: (p.lat * 20).rounded() / 20, lon: (p.lon * 20).rounded() / 20)
    }

    /// File name of a place's history in the iPhone's cache.
    public static func cacheName(_ p: GeoPoint) -> String {
        let q = place(p)
        return String(format: "%.2f_%.2f_%dy.json", q.lat, q.lon, years)
    }

    /// Daily rain, low and high of the last `years` full years at `p` (one request).
    public static func archiveRequest(_ p: GeoPoint, today: CalendarDay) -> URL? {
        let q = place(p)
        var comps = URLComponents(string: archiveURL)
        comps?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", q.lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", q.lon)),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "start_date", value: "\(today.year - years)-01-01"),
            URLQueryItem(name: "end_date", value: "\(today.year - 1)-12-31"),
            URLQueryItem(name: "daily", value: "precipitation_sum,temperature_2m_min,temperature_2m_max"),
        ]
        return comps?.url
    }

    /// The archive's answer (`{"daily": {"time", "precipitation_sum", "temperature_2m_min", "temperature_2m_max"}}`);
    /// days with a missing value are skipped.
    public static func parseArchive(_ data: Data) throws -> [Day] {
        struct Answer: Decodable {
            struct Daily: Decodable {
                let time: [String]
                let precipitation_sum: [Double?]
                let temperature_2m_min: [Double?]
                let temperature_2m_max: [Double?]
            }
            let daily: Daily
        }
        let d = try JSONDecoder().decode(Answer.self, from: data).daily
        var out: [Day] = []
        out.reserveCapacity(d.time.count)
        for (i, t) in d.time.enumerated() where i < d.precipitation_sum.count && i < d.temperature_2m_min.count
            && i < d.temperature_2m_max.count {
            guard let day = CalendarDay(t), let rain = d.precipitation_sum[i], let low = d.temperature_2m_min[i],
                  let high = d.temperature_2m_max[i] else { continue }
            out.append(Day(day: day, rain: rain, low: low, high: high))
        }
        return out
    }
}
