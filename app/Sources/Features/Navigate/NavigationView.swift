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
         camerasEnabled: Bool, traffic: TrafficClient?, directions: Bool = true,
         onFinished: @escaping (RideLog?) -> Void = { _ in },
         onPaceUpdate: @escaping (PaceEstimator) -> Void) {
        self.location = location
        self.onFinished = onFinished
        _session = StateObject(wrappedValue: NavigationSession(trip: trip, day: day, location: location, voice: voice,
                                                               pace: pace, camerasEnabled: camerasEnabled, traffic: traffic,
                                                               directions: directions, onPaceUpdate: onPaceUpdate))
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
                        VoiceModeButton(directions: session.directionsSpoken) { session.setDirections(!session.directionsSpoken) }
                    }
                }
                Spacer()
                let online = [session.weatherStatus, session.trafficStatus].compactMap { $0 }
                if !online.isEmpty {
                    Text(online.joined(separator: " · ")).font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .glass(radius: 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                priorityBadge
                if session.detour != nil {
                    Button { session.endDetour() } label: {
                        Label("Reprendre l'itinéraire", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.info)
                    .buttonBorderShape(.roundedRectangle(radius: 18))
                } else {
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
        // The detour (or its way back after a wrong turn), else the way back to the track.
        let extra = session.detour.map { session.detourBack?.route ?? $0.route } ?? session.rejoinRoute
        c.detour = extra?.track.points ?? []
        // Up-to-date cameras and hazards: the day's (merged with the latest pack) and the detour's.
        c.alerts = (session.alerts + (extra?.alerts ?? []))
            .filter { settings.radarAnnouncements || !$0.kind.isCamera }
            .compactMap { a in a.point.map { MapContent.AlertDot(point: $0, isCamera: a.kind.isCamera) } }
        return c
    }

    // MARK: Top banner

    private var topBanner: some View {
        HStack(spacing: 14) {
            if let detour = session.detour {
                if let back = session.detourBack {
                    WayBackBanner(back: back, label: "Retour vers \(detour.route.name)")
                } else {
                    DetourBanner(name: detour.route.name, update: session.detourUpdate)
                }
            } else if session.offRoute, session.rejoinRoute != nil {
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
                ManeuverIcon(instruction: turn.instruction)
                VStack(alignment: .leading) {
                    Text(Format.distance(turn.distance)).font(.title.bold())
                    Text(TurnGuide.banner(turn.instruction)).font(.title3).lineLimit(2).minimumScaleFactor(0.7)
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
        .glass(radius: 24, tint: session.offRoute ? Theme.camera : nil)
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
        .glass(radius: 18)
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
        .glass(radius: 20, tint: Theme.info)
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
        .glass(radius: 20, tint: .purple)
    }

    /// Speed camera (with its limit) or hazard within 500 m.
    private func alertBadge(_ alert: RoadAlert, distance: Double) -> some View {
        AlertBadge(alert: alert, distance: distance)
    }

    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + String(s.dropFirst())
    }

    /// One badge at a time, the most pressing: camera or hazard close by, then a live incident (serious within
    /// 10 km, roadworks within 1 km), then the validated stop within 5 km (fuel, restaurant, hotel), then the
    /// weather within 60 km, then the pause suggestion.
    @ViewBuilder private var priorityBadge: some View {
        let progress = session.snapshot?.progress ?? 0
        let incident = session.incidentsAhead.first { i in
            let d = i.along - progress
            return d > 0 && d <= (i.incident.category.isMinor ? 1_000 : 10_000)
        }
        if let next = session.nextAlert {
            alertBadge(next.alert, distance: next.distance)
        } else if let incident {
            incidentBadge(incident, distance: incident.along - progress)
        } else if session.detour == nil, let stop = session.nextStop {
            StopBadge(stop: stop.stop, distance: stop.distance)
        } else if let h = session.weatherAhead, h.along - progress <= 60_000 {
            weatherBadge(h, distance: h.along - progress)
        } else if let pause = session.pauseSuggestion {
            HStack(spacing: 10) {
                Image(systemName: pause.spot.kind == .cafe ? "cup.and.saucer.fill" : pause.spot.kind == .viewpoint ? "binoculars.fill" : "drop.fill")
                    .font(.system(size: 26, weight: .bold))
                VStack(alignment: .leading) {
                    Text("Pause : \(pause.spot.name)").font(.headline).lineLimit(1)
                    Text("\(pause.spot.kind.label) · \(Format.distance(pause.distance))").font(.subheadline)
                }
                Spacer()
            }
            .padding(10)
            .glass(radius: 20, tint: Theme.ok)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            QuitButton(title: "Quitter", icon: "xmark", confirm: $confirmQuit) { dismiss() }
            SOSButton(name: settings.sosName, phone: settings.sosPhone, location: location)
        }
    }
}

/// Glass « Quitter / Terminer » button: a first tap arms it (« Appuie encore »), a second one within 3 s quits,
/// so a glove brushing the screen never ends the ride.
struct QuitButton: View {
    let title: String
    let icon: String
    @Binding var confirm: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if confirm { action() } else {
                confirm = true
                Task { try? await Task.sleep(nanoseconds: 3_000_000_000); confirm = false }
            }
        } label: {
            Label(confirm ? "Appuie encore" : title, systemImage: confirm ? "hand.tap.fill" : icon)
                .font(.title3.bold())
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 60)
                .glass(radius: 18, tint: confirm ? Theme.accent : nil)
        }
        .buttonStyle(.plain)
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
