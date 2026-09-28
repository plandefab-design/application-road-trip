import SwiftUI

@main
struct MotoTripApp: App {
    @StateObject private var store = TripStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var offlineMaps = OfflineMapStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(offlineMaps)
                .onOpenURL { url in store.importFile(at: url) }   // AirDrop / "Ouvrir avec"
                .preferredColorScheme(settings.forceDark ? .dark : nil)
                .task {
                    // After each SideStore refresh the expiry moves: keep the reminder in step (if allowed).
                    if let expiry = SigningInfo.expirationDate { await Reminders.scheduleSignatureReminder(expiry: expiry) }
                }
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case home, trips, create, settings }
    @State private var tab: Tab = .home

    var body: some View {
        TabView(selection: $tab) {
            HomeView(tab: $tab)
                .tabItem { Label("Accueil", systemImage: "house.fill") }
                .tag(Tab.home)
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
