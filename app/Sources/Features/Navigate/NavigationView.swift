import SwiftUI
import TripCore
import UIKit

/// Riding screen: readable at a glance, big touch targets (gloves), no modal, no text input.
struct NavigationView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: NavigationSession
    @State private var confirmQuit = false

    init(trip: Trip, day: TripDay, location: LocationService, voice: VoiceService, pace: PaceEstimator,
         onPaceUpdate: @escaping (PaceEstimator) -> Void) {
        _session = StateObject(wrappedValue: NavigationSession(trip: trip, day: day, location: location, voice: voice,
                                                               pace: pace, onPaceUpdate: onPaceUpdate))
    }

    var body: some View {
        ZStack {
            TripMapView(content: mapContent)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                topBanner
                Spacer()
                if let delay = session.snapshot?.delay { delayBadge(delay) }
                bottomCards
                controls
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .preferredColorScheme(.dark)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    private var mapContent: MapContent {
        var c = MapContent.from(trip: session.trip, highlightDay: session.day.index)
        c.lines = c.lines.filter { $0.id == "day\(session.day.index)" }
        c.followUser = true
        return c
    }

    // MARK: Top banner

    private var topBanner: some View {
        HStack(spacing: 14) {
            if session.offRoute {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 44, weight: .bold))
                    .rotationEffect(.degrees(session.rejoinBearing ?? 0))
                VStack(alignment: .leading) {
                    Text("Hors tracé").font(.title2.bold())
                    if let d = session.rejoinDistance { Text("Tracé à \(Format.distance(d))").font(.title3) }
                }
            } else {
                Image(systemName: "arrow.up").font(.system(size: 44, weight: .bold))
                VStack(alignment: .leading) {
                    Text("Suivre le tracé").font(.title2.bold())
                    Text("Étape \(session.day.index) · \(Format.distance(session.route.length))").font(.title3)
                }
            }
            Spacer()
            VStack {
                Text("\(Int(session.speedKmh))").font(.system(size: 40, weight: .heavy, design: .rounded))
                Text("km/h").font(.caption)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
        .background(session.offRoute ? Color.red.opacity(0.9) : Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Bottom cards (fuel · next stop · end of day)

    private var bottomCards: some View {
        HStack(spacing: 8) {
            card(icon: "fuelpump.fill", title: "Plein", info: session.snapshot?.nextFuel)
            card(icon: "fork.knife", title: "Arrêt", info: session.snapshot?.nextStop)
            card(icon: "flag.checkered", title: "Fin", info: session.snapshot?.endOfDay,
                 warning: session.snapshot?.arrivesAfterSunset == true)
        }
    }

    private func card(icon: String, title: String, info: TargetInfo?, warning: Bool = false) -> some View {
        VStack(spacing: 4) {
            Label(title, systemImage: icon).font(.headline)
            if let info {
                Text(Format.distance(info.distance)).font(.title2.bold())
                Text(Format.time(info.eta)).font(.title3.monospacedDigit())
                    .foregroundStyle(warning ? .orange : .white)
            } else {
                Text("—").font(.title2.bold())
                Text(" ").font(.title3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
    }

    private func delayBadge(_ delay: TimeInterval) -> some View {
        let minutes = Int((delay / 60).rounded())
        let late = minutes > 0
        return Text(late ? "Retard \(minutes) min" : "Avance \(-minutes) min")
            .font(.headline)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(late ? Color.orange : Color.green, in: Capsule())
            .foregroundStyle(.black)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            bigButton("Quitter", "xmark", .gray) {
                if confirmQuit { dismiss() } else {
                    confirmQuit = true
                    Task { try? await Task.sleep(nanoseconds: 3_000_000_000); confirmQuit = false }
                }
            }
            .overlay(alignment: .top) {
                if confirmQuit { Text("Appuie encore").font(.caption.bold()).offset(y: -18) }
            }
            SOSButton(name: settings.sosName, phone: settings.sosPhone, position: session.recorded.last)
        }
    }

    private func bigButton(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
    }
}

/// SOS: long press (1.5 s) opens Messages with the position pre-filled. No server involved.
struct SOSButton: View {
    let name: String
    let phone: String
    let position: GeoPoint?

    var body: some View {
        Label("SOS (maintenir)", systemImage: "sos")
            .font(.title3.bold())
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
            .onLongPressGesture(minimumDuration: 1.5) { send() }
            .opacity(phone.isEmpty ? 0.4 : 1)
    }

    private func send() {
        guard !phone.isEmpty else { return }
        var body = "SOS moto — besoin d'aide."
        if let p = position {
            body += String(format: " Position : %.5f, %.5f https://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f#map=16/%.5f/%.5f",
                           p.lat, p.lon, p.lat, p.lon, p.lat, p.lon)
        }
        let number = phone.filter { "+0123456789".contains($0) }
        var comps = URLComponents()
        comps.scheme = "sms"
        comps.path = number
        comps.queryItems = [URLQueryItem(name: "body", value: body)]
        // iOS expects "sms:NUMBER&body=…"
        if let s = comps.string?.replacingOccurrences(of: "?body=", with: "&body="), let url = URL(string: s) {
            UIApplication.shared.open(url)
        }
    }
}

enum Format {
    static func distance(_ m: Double) -> String {
        m >= 10_000 ? "\(Int((m / 1000).rounded())) km"
            : m >= 1_000 ? String(format: "%.1f km", m / 1000)
            : "\(Int((m / 10).rounded() * 10)) m"
    }

    static func time(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    static func duration(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60) h \(String(format: "%02ld", m % 60))" : "\(m) min"
    }
}
