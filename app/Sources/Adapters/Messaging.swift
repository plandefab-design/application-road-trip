import CoreLocation
import Foundation
import TripCore
import UIKit

/// SMS to the SOS contact: SOS with the position, or a simple « check-point » with the town.
/// iOS never lets an app send an SMS silently: Messages opens pre-filled, the rider taps send.
@MainActor
enum Messaging {
    /// Opens on any phone (iPhone or Android), single parameter so nothing can be cut.
    static func mapLink(_ p: GeoPoint) -> String {
        String(format: "https://maps.google.com/?q=%.5f,%.5f", p.lat, p.lon)
    }

    /// Strict encoding: every « & ? = # / : , » and accent is percent-encoded, so the body is never truncated.
    static func smsURL(to phone: String, body: String) -> URL? {
        let number = phone.filter { "+0123456789".contains($0) }
        guard !number.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "sms:\(number)&body=\(encoded)")
    }

    static func open(_ url: URL?) {
        if let url { UIApplication.shared.open(url) }
    }

    /// « Sault (Vaucluse) » from the position; nil offline or after 5 s.
    static func placeName(_ p: GeoPoint) async -> String? {
        // A real 5 s limit: the SOS message never waits longer for the town's name.
        await Deadline.run(5) { () -> String? in
            let marks = try await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: p.lat, longitude: p.lon))
            guard let m = marks.first else { return nil }
            let town = m.locality ?? m.subLocality ?? m.name
            let area = m.subAdministrativeArea ?? m.administrativeArea
            return [town, area.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        } ?? nil
    }

    static func sosBody(position: GeoPoint?, place: String?) -> String {
        var body = "🆘 SOS moto — j'ai besoin d'aide."
        if let place { body += " Je suis vers \(place)." }
        if let p = position { body += " Ma position : \(mapLink(p))" } else { body += " (position GPS indisponible)" }
        return body
    }

    static func checkpointBody(position: GeoPoint?, place: String?) -> String {
        var body = "👍 Petit point moto : tout va bien"
        body += place.map { ", je suis à \($0)." } ?? "."
        if let p = position { body += " \(mapLink(p))" }
        return body
    }

    static func sendSOS(to phone: String, location: LocationService) async {
        let p = await location.currentPosition()
        var place: String?
        if let p { place = await placeName(p) }
        open(smsURL(to: phone, body: sosBody(position: p, place: place)))
    }

    static func sendCheckpoint(to phone: String, location: LocationService) async {
        let p = await location.currentPosition()
        var place: String?
        if let p { place = await placeName(p) }
        open(smsURL(to: phone, body: checkpointBody(position: p, place: place)))
    }
}
