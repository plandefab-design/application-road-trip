import SwiftUI
import TripCore

/// Riding screen without an itinerary: speed, next camera / hazard ahead, distance and time, big buttons.
struct FreeRideView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: FreeRideSession
    @State private var confirmQuit = false
    @State private var recenter = 0
    @State private var showNearby = false
    private let location: LocationService
    private let onFinished: (RideLog?) -> Void

    /// true = opened from « Où tu vas ? »: the route planner is shown right away.
    private let startWithAddress: Bool
    @State private var showPlanner = false
    /// Stops of the current route, in order (the last one is the destination), to edit it again.
    @State private var plannedStops: [FavoritePlaces.Place] = []
    @State private var routeNote: String?

    /// Favourite destination to be guided to right away (Favoris tab).
    private let destination: FavoritePlaces.Place?

    init(location: LocationService, voice: VoiceService, camerasEnabled: Bool, traffic: TrafficClient?, directions: Bool = true,
         startWithAddress: Bool = false, destination: FavoritePlaces.Place? = nil, onFinished: @escaping (RideLog?) -> Void) {
        self.location = location
        self.startWithAddress = startWithAddress
        self.destination = destination
        self.onFinished = onFinished
        _session = StateObject(wrappedValue: FreeRideSession(guide: AlertPackStore.shared.guide, camerasEnabled: camerasEnabled, traffic: traffic,
                                                             directions: directions, location: location, voice: voice))
    }

    var body: some View {
        ZStack {
            TripMapView(content: MapContent(lines: [.init(id: "ride", points: session.trackPreview, highlighted: true)],
                                            markers: stopMarkers,
                                            alerts: session.nearbyAlerts + (session.detour?.route.alerts ?? [])
                                                .filter { settings.radarAnnouncements || !$0.kind.isCamera }
                                                .compactMap { a in a.point.map { MapContent.AlertDot(point: $0, isCamera: a.kind.isCamera) } },
                                            followUser: true, recenter: recenter,
                                            detour: session.detour?.route.track.points ?? []))
                .ignoresSafeArea()
            VStack(spacing: 8) {
                header
                if let detour = session.detour {
                    HStack(spacing: 14) { DetourBanner(name: detour.route.name, update: session.detourUpdate); Spacer() }
                        .padding(14)
                        .glass(radius: 24, tint: Theme.info)
                    if let routeNote {
                        Text(routeNote).font(.caption.bold()).padding(8).frame(maxWidth: .infinity)
                            .background(Color.orange, in: Capsule()).foregroundStyle(.black)
                    }
                }
                if !session.hasPack {
                    Text("Base radars absente : Réglages › Synchroniser avec le PC")
                        .font(.caption.bold()).padding(8).frame(maxWidth: .infinity)
                        .background(Color.orange, in: Capsule()).foregroundStyle(.black)
                }
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        MapRoundButton(icon: "scope", label: "Recentrer sur ma position") { recenter += 1 }
                        MapRoundButton(icon: "arrow.triangle.turn.up.right.diamond.fill", label: "Itinéraire : destination et étapes") { showPlanner = true }
                        MapRoundButton(icon: "magnifyingglass", label: "Autour de moi : essence, hôtel, resto") { showNearby = true }
                        if session.detour?.route.isRoad == true {
                            VoiceModeButton(directions: session.directionsSpoken) { session.setDirections(!session.directionsSpoken) }
                        }
                    }
                }
                Spacer()
                if let next = session.nextAlert {
                    AlertBadge(alert: next.alert, distance: next.distance)
                } else if let incident = session.incidentAhead {
                    Label(incident, systemImage: "exclamationmark.octagon.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .glass(radius: 20, tint: .purple)
                } else if let stop = session.detourUpdate?.nextStop, stop.distance <= StopGuide.farWarning {
                    StopBadge(stop: stop.stop, distance: stop.distance)
                }
                if session.detour != nil {
                    Button { session.endDetour(); plannedStops = []; routeNote = nil } label: {
                        Label("Arrêter le guidage", systemImage: "xmark.circle.fill")
                            .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.info)
                    .buttonBorderShape(.roundedRectangle(radius: 18))
                }
                controls
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .sheet(isPresented: $showNearby) {
            NearbySheet(location: location, trip: nil) { route in
                plannedStops = []
                routeNote = nil
                session.startDetour(route)
                recenter += 1
            }
        }
        .sheet(isPresented: $showPlanner) {
            RoutePlannerSheet(location: location, stops: remainingStops) { stops, result in
                plannedStops = stops
                routeNote = result.note
                session.startDetour(result.route)
                recenter += 1
            }
            .environmentObject(settings)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            session.start()
            if let destination {
                Task {
                    guard let from = await location.currentPosition() else { return }
                    let result = await RideRouter.route(from: from, through: [destination], mode: settings.rideMode, settings: settings)
                    plannedStops = [destination]
                    routeNote = result.note
                    session.startDetour(result.route)
                    recenter += 1
                }
            } else if startWithAddress {
                showPlanner = true
            }
        }
        .onDisappear {
            session.stop()
            onFinished(session.finishedRide)
        }
    }

    /// Stops of the current route and its destination, as badges on the map.
    private var stopMarkers: [MapContent.Marker] {
        guard let route = session.detour?.route else { return [] }
        var out = route.stops.enumerated().compactMap { i, s in
            route.track.point(at: s.along).map { MapContent.Marker(id: "stop-\(i)", point: $0, title: "📍 \(s.name)", subtitle: nil) }
        }
        out.append(.init(id: "destination", point: route.destination, title: "🏁 \(route.name)", subtitle: nil))
        return out
    }

    /// Stops not reached yet, to change the route on the way.
    private var remainingStops: [FavoritePlaces.Place] {
        guard let d = session.detour, !plannedStops.isEmpty else { return plannedStops }
        let passed = d.route.stops.filter { $0.along < d.progress - StopGuide.arrivedWithin }.count
        return Array(plannedStops.dropFirst(min(passed, plannedStops.count - 1)))
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Balade libre").font(.headline)
                Text(Format.distance(session.distance)).font(.title.bold().monospacedDigit())
                Text(session.startedAt, style: .timer).font(.subheadline.monospacedDigit())
            }
            Spacer()
            VStack {
                Text("\(Int(session.speedKmh))").font(.system(size: 44, weight: .heavy, design: .rounded))
                Text("km/h").font(.caption)
            }
        }
        .padding(14)
        .glass(radius: 24)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            QuitButton(title: "Terminer", icon: "flag.checkered", confirm: $confirmQuit) { dismiss() }
            SOSButton(name: settings.sosName, phone: settings.sosPhone, location: location)
        }
    }
}

/// Speed camera (with its limit) or hazard ahead, shared by both riding screens.
struct AlertBadge: View {
    let alert: RoadAlert
    let distance: Double

    var body: some View {
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
                Text(NavigationView.sentenceCase(alert.label)).font(.title3.bold())
                Text(Format.distance(distance)).font(.title3.monospacedDigit())
            }
            Spacer()
        }
        .padding(12)
        .glass(radius: 20, tint: alert.kind.isCamera ? Theme.camera : Theme.hazard)
    }
}

/// Validated stop of the route (fuel, restaurant, hotel) or waypoint of a free-ride route, within 5 km.
struct StopBadge: View {
    let stop: RouteStop
    let distance: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.icon(stop.kind))
                .font(.system(size: 26, weight: .bold))
                .frame(width: 48, height: 48)
                .background(Circle().fill(.white.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(stop.kind)).font(.caption.bold()).textCase(.uppercase).opacity(0.85)
                Text(stop.name).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer()
            Text(distance < StopGuide.arrivedWithin ? "Arrivé" : Format.distance(distance))
                .font(.title2.bold().monospacedDigit())
        }
        .padding(12)
        .glass(radius: 20, tint: Theme.accent)
    }

    static func icon(_ kind: RouteStop.Kind) -> String {
        switch kind {
        case .fuel: "fuelpump.fill"
        case .meal: "fork.knife"
        case .lodging: "bed.double.fill"
        case .waypoint: "mappin.circle.fill"
        }
    }

    static func title(_ kind: RouteStop.Kind) -> String {
        switch kind {
        case .fuel: "Ravitaillement"
        case .meal: "Restaurant"
        case .lodging: "Hôtel · fin d'étape"
        case .waypoint: "Étape"
        }
    }
}
