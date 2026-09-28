import SwiftUI
import TripCore
import UIKit

/// Riding screen: readable at a glance, big touch targets (gloves), no modal, no text input.
struct NavigationView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: NavigationSession
    @State private var confirmQuit = false
    @State private var recenter = 0
    @State private var showNearby = false

    private let location: LocationService
    private let onFinished: (RideLog?) -> Void

    init(trip: Trip, day: TripDay, location: LocationService, voice: VoiceService, pace: PaceEstimator,
         camerasEnabled: Bool, tomtomKey: String, onFinished: @escaping (RideLog?) -> Void = { _ in },
         onPaceUpdate: @escaping (PaceEstimator) -> Void) {
        let traffic: TrafficClient? = tomtomKey.isEmpty ? nil : TomTomTrafficClient(key: tomtomKey) as TrafficClient
        self.location = location
        self.onFinished = onFinished
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
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        MapRoundButton(icon: "scope", label: "Recentrer sur ma position") { recenter += 1 }
                        MapRoundButton(icon: "magnifyingglass", label: "Autour de moi : essence, hôtel, resto") { showNearby = true }
                    }
                }
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
                if let pause = session.pauseSuggestion {
                    HStack(spacing: 10) {
                        Image(systemName: pause.spot.kind == .cafe ? "cup.and.saucer.fill" : pause.spot.kind == .viewpoint ? "binoculars.fill" : "drop.fill")
                            .font(.system(size: 26, weight: .bold))
                        VStack(alignment: .leading) {
                            Text("Pause conseillée : \(pause.spot.name)").font(.headline).lineLimit(1)
                            Text("\(pause.spot.kind.label) · \(Format.distance(pause.distance))").font(.subheadline)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .foregroundStyle(.white)
                    .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                }
                if session.detour != nil {
                    Button { session.endDetour() } label: {
                        Label("Reprendre l'itinéraire", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                } else {
                    if let delay = session.snapshot?.delay { delayBadge(delay) }
                    bottomCards
                }
                controls
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .sheet(isPresented: $showNearby) {
            NearbySheet(location: location, trip: session.trip) { route in
                session.startDetour(route)
                recenter += 1
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { session.start() }
        .onDisappear {
            session.stop()
            onFinished(session.finishedRide)
        }
    }

    private var mapContent: MapContent {
        var c = MapContent.from(trip: session.trip, highlightDay: session.day.index)
        c.lines = c.lines.filter { $0.id == "day\(session.day.index)" }
        c.followUser = true
        c.recenter = recenter
        let extra = session.detour ?? session.rejoin
        c.detour = extra?.route.track.points ?? []
        // Up-to-date cameras and hazards: the day's (merged with the latest pack) and the detour's.
        c.alerts = (session.alerts + (extra?.route.alerts ?? []))
            .filter { settings.radarAnnouncements || !$0.kind.isCamera }
            .compactMap { a in a.point.map { MapContent.AlertDot(point: $0, isCamera: a.kind.isCamera) } }
        return c
    }

    // MARK: Top banner

    private var topBanner: some View {
        HStack(spacing: 14) {
            if let detour = session.detour {
                DetourBanner(name: detour.route.name, update: session.detourUpdate)
            } else if session.offRoute, session.rejoin != nil {
                DetourBanner(name: "Retour au tracé", update: session.rejoinUpdate)
            } else if session.offRoute {
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
            if let limit = session.speedLimit {
                Text("\(limit)")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(.white))
                    .overlay(Circle().stroke(.red, lineWidth: 5))
                    .foregroundStyle(.black)
            }
            VStack {
                Text("\(Int(session.speedKmh))").font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(session.speedLimit.map { SpeedLimits.isOver(speedKmh: session.speedKmh, limit: $0) } == true ? .red : .white)
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
        AlertBadge(alert: alert, distance: distance)
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
            SOSButton(name: settings.sosName, phone: settings.sosPhone, location: location)
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

/// SOS group, big targets for gloves. No server involved.
/// - long press (1.5 s) on SOS: CALLS the SOS contact;
/// - message button: SMS « SOS » with the town and a map link to the exact position;
/// - check-point button: SMS « tout va bien, je suis à … » (no alarm).
struct SOSButton: View {
    let name: String
    let phone: String
    let location: LocationService
    @State private var sending = false

    var body: some View {
        HStack(spacing: 6) {
            Label(name.isEmpty ? "SOS (maintenir)" : "SOS \(name)", systemImage: "phone.fill")
                .font(.title3.bold())
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
                .onLongPressGesture(minimumDuration: 1.5) { Messaging.open(URL(string: "tel:\(number)")) }
            small("message.fill", .red.opacity(0.75), "SMS SOS avec ma position") {
                await Messaging.sendSOS(to: phone, location: location)
            }
            small("hand.thumbsup.fill", .green, "Petit point : tout va bien, avec ma ville") {
                await Messaging.sendCheckpoint(to: phone, location: location)
            }
        }
        .opacity(phone.isEmpty ? 0.4 : 1)
        .disabled(phone.isEmpty || sending)
    }

    private var number: String { phone.filter { "+0123456789".contains($0) } }

    private func small(_ icon: String, _ color: Color, _ label: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task {
                sending = true
                await action()
                sending = false
            }
        } label: {
            Image(systemName: icon).font(.title3.bold()).frame(width: 48, height: 60)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .accessibilityLabel(label)
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
