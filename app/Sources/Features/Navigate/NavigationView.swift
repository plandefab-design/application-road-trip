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
         camerasEnabled: Bool, tomtomKey: String, onPaceUpdate: @escaping (PaceEstimator) -> Void) {
        let traffic: TrafficClient? = tomtomKey.isEmpty ? nil : TomTomTrafficClient(key: tomtomKey) as TrafficClient
        _session = StateObject(wrappedValue: NavigationSession(trip: trip, day: day, location: location, voice: voice,
                                                               pace: pace, camerasEnabled: camerasEnabled, traffic: traffic,
                                                               onPaceUpdate: onPaceUpdate))
    }

    var body: some View {
        ZStack {
            TripMapView(content: mapContent)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                topBanner
                Spacer()
                if let h = session.weatherAhead, let progress = session.snapshot?.progress, h.along - progress <= 60_000 {
                    weatherBadge(h, distance: h.along - progress)
                }
                let online = [session.weatherStatus, session.trafficStatus].compactMap { $0 }
                if !online.isEmpty {
                    Text(online.joined(separator: " · ")).font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let incident = session.incidentsAhead.first, let progress = session.snapshot?.progress,
                   incident.along - progress <= 10_000 {
                    incidentBadge(incident, distance: incident.along - progress)
                }
                if let next = session.nextAlert { alertBadge(next.alert, distance: next.distance) }
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
            } else if let turn = session.nextTurn {
                Image(systemName: Self.symbol(for: turn.instruction.maneuver)).font(.system(size: 44, weight: .bold))
                VStack(alignment: .leading) {
                    Text(Format.distance(turn.distance)).font(.title.bold())
                    Text(turn.instruction.text).font(.title3).lineLimit(2).minimumScaleFactor(0.7)
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

    static func symbol(for maneuver: Maneuver) -> String {
        switch maneuver {
        case .depart, .straight, .via: "arrow.up"
        case .slightLeft, .keepLeft: "arrow.up.left"
        case .slightRight, .keepRight: "arrow.up.right"
        case .turnLeft, .sharpLeft: "arrow.turn.up.left"
        case .turnRight, .sharpRight: "arrow.turn.up.right"
        case .uTurn: "arrow.uturn.down"
        case .roundabout: "arrow.triangle.turn.up.right.circle"
        case .arrive: "flag.checkered"
        }
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

    /// Next weather hazard on the route within 60 km (Open-Meteo).
    private func weatherBadge(_ h: RouteWeather.Hazard, distance: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: h.kinds.contains(.rain) ? "cloud.rain.fill" : h.kinds.contains(.wind) ? "wind" :
                    h.kinds.contains(.cold) ? "thermometer.snowflake" : "cloud.fog.fill")
                .font(.system(size: 28, weight: .bold))
            VStack(alignment: .leading) {
                Text(h.summary).font(.headline).lineLimit(2)
                Text("\(Format.distance(distance)) · vers \(Format.time(h.eta))").font(.subheadline.monospacedDigit())
            }
            Spacer()
        }
        .padding(10)
        .foregroundStyle(.white)
        .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Live traffic incident within 10 km (TomTom).
    private func incidentBadge(_ item: IncidentAhead, distance: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 30, weight: .bold))
            VStack(alignment: .leading) {
                Text(item.incident.category.label).font(.title3.bold())
                Text(item.incident.delay.map { "\(Format.distance(distance)) · +\(Int(($0 / 60).rounded())) min" } ?? Format.distance(distance))
                    .font(.title3.monospacedDigit())
            }
            Spacer()
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(Color.purple.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Speed camera (with its limit) or hazard within 500 m.
    private func alertBadge(_ alert: RoadAlert, distance: Double) -> some View {
        HStack(spacing: 10) {
            if alert.kind.isCamera, let limit = alert.maxspeed {
                Text("\(limit)")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(.white))
                    .overlay(Circle().stroke(.red, lineWidth: 5))
                    .foregroundStyle(.black)
            } else {
                Image(systemName: alert.kind.isCamera ? "camera.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30, weight: .bold))
            }
            VStack(alignment: .leading) {
                Text(Self.sentenceCase(alert.label))
                    .font(.title3.bold())
                Text(Format.distance(distance)).font(.title3.monospacedDigit())
            }
            Spacer()
        }
        .padding(12)
        .foregroundStyle(.white)
        .background((alert.kind.isCamera ? Color.red : Color.orange).opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
    }

    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + String(s.dropFirst())
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
