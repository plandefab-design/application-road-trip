import SwiftUI
import TripCore

@main
struct MotoTripApp: App {
    @StateObject private var store = TripStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var offlineMaps = OfflineMapStore()
    @StateObject private var rides = RideStore()
    @StateObject private var sync = SyncService()
    @StateObject private var maintenance = MaintenanceStore()
    @StateObject private var group = GroupSession(storage: DeviceGroupStorage(), voiceRoom: LiveKitVoiceRoom())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(offlineMaps)
                .environmentObject(rides)
                .environmentObject(sync)
                .environmentObject(maintenance)
                .environmentObject(group)
                .onOpenURL { url in
                    // A group invitation link, else AirDrop / "Ouvrir avec".
                    if let invite = GroupInvite.parse(url) { Task { await group.receive(invite) } } else { store.importFile(at: url) }
                }
                .preferredColorScheme(settings.lightTheme ? .light : .dark)
                .task {
                    MetricsRecorder.shared.start()                   // real battery / launch / hang figures, kept on the iPhone
                    // After each SideStore refresh the expiry moves: keep the reminder in step (if allowed).
                    if let expiry = SigningInfo.expirationDate { await Reminders.scheduleSignatureReminder(expiry: expiry) }
                    await offlineMaps.purge(trips: store.trips)      // space: maps of past or deleted trips
                    group.setAppActive(true)
                    if group.phase == .signedIn { await group.refreshGroups() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // When the app opens or comes back (never while riding: no network need): the camera pack from GitHub,
            // then a silent sync with the PC when it answers.
            group.setAppActive(phase == .active)
            guard phase == .active else { return }
            if group.phase == .signedIn { Task { await group.refreshGroups() } }
            Task { await AlertPackStore.shared.refresh() }
            Task { await sync.sync(store: store, rides: rides, settings: settings) }
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case home, favorites, trips, group, settings }
    @EnvironmentObject private var group: GroupSession
    @State private var tab: Tab = .home

    var body: some View {
        TabView(selection: $tab) {
            HomeView(tab: $tab)
                .tabItem { Label("Rouler", systemImage: "location.north.line.fill") }
                .tag(Tab.home)
            FavoritesView()
                .tabItem { Label("Favoris", systemImage: "star.fill") }
                .tag(Tab.favorites)
            TripsListView()
                .tabItem { Label("Trips", systemImage: "map.fill") }
                .tag(Tab.trips)
            GroupView()
                .tabItem { Label("Groupe", systemImage: "person.3.fill") }
                .badge(group.unread)
                .tag(Tab.group)
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Theme.accent)
        .onChange(of: group.pendingInvite) { _, invite in
            if invite != nil { tab = .group }             // an invitation was opened: finish it in the group tab
        }
    }
}
