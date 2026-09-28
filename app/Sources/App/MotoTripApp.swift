import SwiftUI

@main
struct MotoTripApp: App {
    @StateObject private var store = TripStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var offlineMaps = OfflineMapStore()
    @StateObject private var rides = RideStore()
    @StateObject private var sync = SyncService()
    @StateObject private var maintenance = MaintenanceStore()
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
                .onOpenURL { url in store.importFile(at: url) }   // AirDrop / "Ouvrir avec"
                .preferredColorScheme(settings.forceDark ? .dark : nil)
                .task {
                    // After each SideStore refresh the expiry moves: keep the reminder in step (if allowed).
                    if let expiry = SigningInfo.expirationDate { await Reminders.scheduleSignatureReminder(expiry: expiry) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Silent sync with the PC when the app opens or comes back (never while riding: no network need).
            if phase == .active { Task { await sync.sync(store: store, rides: rides, settings: settings) } }
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case home, favorites, trips, create, settings }
    @State private var tab: Tab = .home

    var body: some View {
        TabView(selection: $tab) {
            HomeView(tab: $tab)
                .tabItem { Label("Accueil", systemImage: "house.fill") }
                .tag(Tab.home)
            FavoritesView()
                .tabItem { Label("Favoris", systemImage: "star.fill") }
                .tag(Tab.favorites)
            TripsListView()
                .tabItem { Label("Trips", systemImage: "map.fill") }
                .tag(Tab.trips)
            CreateTripView()
                .tabItem { Label("Créer", systemImage: "sparkles") }
                .tag(Tab.create)
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(.orange)
    }
}
