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

    init(location: LocationService, voice: VoiceService, camerasEnabled: Bool, onFinished: @escaping (RideLog?) -> Void) {
        self.location = location
        self.onFinished = onFinished
        _session = StateObject(wrappedValue: FreeRideSession(guide: AlertPackStore.shared.guide, camerasEnabled: camerasEnabled,
                                                             location: location, voice: voice))
    }

    var body: some View {
        ZStack {
            TripMapView(content: MapContent(lines: [.init(id: "ride", points: session.trackPreview, highlighted: true)],
                                            alerts: session.nearbyAlerts,
                                            followUser: true, recenter: recenter,
                                            detour: session.detour?.route.track.points ?? []))
                .ignoresSafeArea()
            VStack(spacing: 8) {
                header
                if let detour = session.detour {
                    HStack(spacing: 14) { DetourBanner(name: detour.route.name, update: session.detourUpdate); Spacer() }
                        .padding(14)
                        .foregroundStyle(.white)
                        .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
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
                        MapRoundButton(icon: "magnifyingglass", label: "Autour de moi : essence, hôtel, resto") { showNearby = true }
                    }
                }
                Spacer()
                if let next = session.nextAlert { AlertBadge(alert: next.alert, distance: next.distance) }
                if session.detour != nil {
                    Button { session.endDetour() } label: {
                        Label("Arrêter le guidage", systemImage: "xmark.circle.fill")
                            .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
                controls
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .sheet(isPresented: $showNearby) {
            NearbySheet(location: location, trip: nil) { route in
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
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                if confirmQuit { dismiss() } else {
                    confirmQuit = true
                    Task { try? await Task.sleep(nanoseconds: 3_000_000_000); confirmQuit = false }
                }
            } label: {
                Label(confirmQuit ? "Appuie encore" : "Terminer", systemImage: "flag.checkered")
                    .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent)
            .tint(.gray)
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
        .foregroundStyle(.white)
        .background((alert.kind.isCamera ? Color.red : Color.orange).opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
    }
}
