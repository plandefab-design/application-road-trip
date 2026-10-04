import Foundation

/// Sunset time, offline (Almanac for Computers algorithm, U.S. Naval Observatory; a few minutes of accuracy).
/// Used by the road book to show the margin between the planned arrival and nightfall.
public enum Sun {
    /// Sunset on the calendar day `isoDate` (« yyyy-MM-dd ») at `point`, nil on polar day or night.
    public static func sunset(on isoDate: String, at point: GeoPoint) -> Date? {
        guard let midnightUTC = ISODate.parse(isoDate) else { return nil }
        let cal = Calendar.utc
        guard let dayOfYear = cal.ordinality(of: .day, in: .year, for: midnightUTC) else { return nil }

        func rad(_ d: Double) -> Double { d * .pi / 180 }
        func deg(_ r: Double) -> Double { r * 180 / .pi }
        func normalize(_ v: Double, _ range: Double) -> Double { (v.truncatingRemainder(dividingBy: range) + range).truncatingRemainder(dividingBy: range) }

        let lngHour = point.lon / 15
        let t = Double(dayOfYear) + (18 - lngHour) / 24                     // evening event
        let m = 0.9856 * t - 3.289                                          // mean anomaly
        let l = normalize(m + 1.916 * sin(rad(m)) + 0.020 * sin(rad(2 * m)) + 282.634, 360)   // true longitude
        var ra = normalize(deg(atan(0.91764 * tan(rad(l)))), 360)
        ra += floor(l / 90) * 90 - floor(ra / 90) * 90                     // same quadrant as L
        ra /= 15
        let sinDec = 0.39782 * sin(rad(l))
        let cosDec = cos(asin(sinDec))
        let zenith = 90.833                                                 // official: refraction + sun radius
        let cosH = (cos(rad(zenith)) - sinDec * sin(rad(point.lat))) / (cosDec * cos(rad(point.lat)))
        guard cosH >= -1, cosH <= 1 else { return nil }
        let h = deg(acos(cosH)) / 15
        let localMeanTime = h + ra - 0.06571 * t - 6.622
        let ut = normalize(localMeanTime - lngHour, 24)
        return midnightUTC.addingTimeInterval(ut * 3600)
    }
}
