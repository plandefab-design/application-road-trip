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
    var body: some View {
        TabView {
            TripsListView()
                .tabItem { Label("Trips", systemImage: "map") }
            CreateTripView()
                .tabItem { Label("Créer", systemImage: "plus.circle") }
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
        }
    }
}
