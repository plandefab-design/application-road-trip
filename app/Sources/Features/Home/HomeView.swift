import SwiftUI
import TripCore

/// « Rouler »: Moto Road's cockpit. Your bike, the ride in progress if any, one big button to ride now, where to
/// go, favourite places in one tap. Carbon and racing orange, big targets, few words: made to be used helmet on.
struct HomeView: View {
    @EnvironmentObject private var store: TripStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var maintenance: MaintenanceStore
    @EnvironmentObject private var rides: RideStore
    @EnvironmentObject private var sync: SyncService
    @ObservedObject private var saved = FavoritePlaces.shared
    @ObservedObject private var alertPack = AlertPackStore.shared
    @ObservedObject private var activeRide = ActiveRide.shared
    @Binding var tab: RootView.Tab
    @State private var path: [String] = []
    @StateObject private var location = LocationService()
    @State private var voice = VoiceService()
    @State private var ride: Ride?
    @State private var showRides = false
    @State private var pendingRide: RideLog?
    @State private var shownRide: RideLog?

    /// What the riding screen opens with.
    enum Ride: Identifiable {
        case free, address, place(FavoritePlaces.Place), trip(Trip, TripDay)
        var id: String {
            switch self {
            case .free: "free"
            case .address: "address"
            case .place(let p): "place-\(p.id)"
            case .trip(let t, let d): "trip-\(t.id)-\(d.index)"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    bikeCard
                    if let resume = resumeTarget { sessionChip(resume.trip, resume.day) }
                    rideButton
                    whereButton
                    if !saved.favorites.isEmpty { favoritesStrip }
                    warnings
                    sosRow
                    bottomRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(Theme.bar, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .navigationDestination(for: String.self) { TripDetailView(tripId: $0) }
            .navigationDestination(isPresented: $showRides) { RidesListView() }
            .onAppear {
                location.requestPermissions()   // asked here, never while riding
                location.warmUp()               // GPS already locked when « Rouler » is tapped
            }
            .fullScreenCover(item: $ride, onDismiss: finishRide) { ride in
                switch ride {
                case .free, .address:
                    FreeRideView(location: location, voice: voice, traffic: LiveTraffic.client(settings), directions: settings.voiceEnabled, startWithAddress: ride.id == "address", onFinished: record)
                case .place(let place):
                    FreeRideView(location: location, voice: voice, traffic: LiveTraffic.client(settings), directions: settings.voiceEnabled, destination: place, onFinished: record)
                case .trip(let trip, let day):
                    NavigationView(trip: trip, day: day, location: location, voice: voice, pace: settings.pace,
                                   traffic: LiveTraffic.client(settings), directions: settings.voiceEnabled,
                                   onFinished: record) { settings.pace = $0 }
                }
            }
            .sheet(item: $shownRide) { RideSummaryView(ride: $0) }
        }
    }

    // MARK: Header and bike

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("Logo")
                .resizable()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Theme.wordmark(size: 28)
                Text(greeting).font(.subheadline.weight(.medium)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { tab = .settings } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 18, weight: .bold))
                    .frame(width: 46, height: 46)
                    .glass(radius: 23)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Réglages")
        }
        .padding(.top, 8)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 5 || hour >= 22 ? "Bonne nuit, roule prudemment" : hour < 12 ? "Bonne route ce matin" : hour < 18 ? "Bonne route" : "Belle balade du soir"
    }

    @ViewBuilder private var bikeCard: some View {
        Button { tab = .garage } label: {
            HStack(spacing: 14) {
                MotoGlyphView(size: 24)
                    .frame(width: 54, height: 54)
                    .background(Theme.rideGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                if let bike = settings.primaryBike {
                    let book = maintenance.books[bike.id]
                    let urgent = book?.attention().first
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bike.model).font(.headline).lineLimit(1)
                        HStack(spacing: 8) {
                            if let km = book?.odometerKm {
                                Text("\(Int(km).formatted(.number.locale(Locale(identifier: "fr_FR")))) km")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(Theme.muted)
                            }
                            statusPill(urgent.map { "\($0.item.label)" } ?? "Entretien à jour",
                                       color: urgent.map { MaintenanceView.color($0.status.level) } ?? Theme.ok)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ajoute ta moto").font(.headline)
                        Text("Autonomie, entretien, km comptés").font(.subheadline).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
            }
            .padding(14)
            .glass(radius: 22)
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Several bikes: switch from here too (appui long).
            ForEach(settings.garage) { bike in
                Button { settings.primaryBikeId = bike.id } label: {
                    Label(bike.model, systemImage: settings.primaryBike?.id == bike.id ? "checkmark.circle.fill" : "circle")
                }
            }
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Session in progress (only that one)

    /// The trip stage left before its end, if its trip still exists.
    private var resumeTarget: (trip: Trip, day: TripDay)? {
        guard let s = activeRide.resumable, let trip = store.trips.first(where: { $0.id == s.tripId }),
              let day = trip.days.first(where: { $0.index == s.day && $0.track != nil }) else { return nil }
        return (trip, day)
    }

    private func sessionChip(_ trip: Trip, _ day: TripDay) -> some View {
        HStack(spacing: 10) {
            Button { go(.trip(trip, day)) } label: {
                HStack(spacing: 10) {
                    Circle().fill(Theme.accent).frame(width: 10, height: 10)
                        .shadow(color: Theme.accent, radius: 6)
                    Text("EN COURS").font(.caption.weight(.black)).foregroundStyle(Theme.accent)
                    Text("\(trip.name) · Étape \(day.index)").font(.subheadline.bold()).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("Reprendre").font(.subheadline.bold()).foregroundStyle(Theme.accent)
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(Theme.accent)
                }
                .padding(.leading, 14)
                .frame(minHeight: 50)
            }
            .buttonStyle(.plain)
            Button { activeRide.finish() } label: {
                Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(Theme.muted)
                    .frame(width: 40, height: 50)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Oublier cette session")
        }
        .glass(radius: 25)
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5))
    }

    // MARK: Ride

    private var rideButton: some View {
        Button { go(.free) } label: {
            ZStack(alignment: .leading) {
                MotoGlyphView(size: 96, color: .white.opacity(0.16))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(x: 14, y: 10)
                VStack(alignment: .leading, spacing: 6) {
                    Text("ROULER").font(.system(size: 44, weight: .black, design: .rounded).italic())
                    Label(alertPack.guide == nil ? "Radars : il faut du réseau une fois" : "Radars · dangers · trafic en direct",
                          systemImage: alertPack.guide == nil ? "exclamationmark.triangle.fill" : "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold)).opacity(0.92)
                }
                .padding(22)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .background(Theme.rideGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.45), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Balade libre : radars et dangers annoncés, km comptés pour l'entretien")
    }

    private var whereButton: some View {
        Button { go(.address) } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.title3.bold()).foregroundStyle(Theme.accent)
                Text("Où tu vas ?").font(.title3.weight(.semibold))
                Spacer()
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 60)
            .glass(radius: 30)
        }
        .buttonStyle(.plain)
    }

    private var favoritesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(saved.favorites.prefix(8)) { place in
                    Button { go(.place(place)) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill").foregroundStyle(Theme.accent)
                            Text(place.name).lineLimit(1)
                        }
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .frame(minHeight: 46)
                        .glass(radius: 23)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func go(_ r: Ride) {
        if case .trip(var trip, _) = r {
            trip.status = .active
            store.save(trip)
        }
        ride = r
    }

    private func record(_ log: RideLog?) {
        guard let log else { return }
        pendingRide = RideFinish.record(log, settings: settings, rides: rides, maintenance: maintenance)
    }

    private func finishRide() {
        guard let log = pendingRide else { return }
        shownRide = log
        pendingRide = nil
        Task { await sync.sync(store: store, rides: rides, settings: settings) }
    }

    // MARK: Warnings (only when something needs doing)

    @ViewBuilder private var warnings: some View {
        if let expiry = SigningInfo.expirationDate, expiry.timeIntervalSinceNow < 2 * 86_400 {
            warning("App à rafraîchir \(expiry.formatted(.relative(presentation: .named)))",
                    detail: "SideStore › Rafraîchir (LocalDevVPN connecté).", icon: "exclamationmark.shield.fill", color: Theme.hazard)
        }
        if !settings.garage.isEmpty, settings.garage.contains(where: { $0.category == nil }) {
            warning("Complète ton garage", detail: "Type de moto et autonomie réelle : routes et pleins en dépendent.",
                    icon: "wrench.and.screwdriver.fill", color: Theme.info) { tab = .garage }
        }
    }

    private func warning(_ title: String, detail: String, icon: String, color: Color, action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
                Image(systemName: icon).font(.title3).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.bold())
                    Text(detail).font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .padding(12)
            .glass(radius: 16)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    // MARK: Shortcuts

    private var bottomRow: some View {
        HStack(spacing: 10) {
            tile("Mes sorties", "point.bottomleft.forward.to.point.topright.scurvepath", Theme.accent) { showRides = true }
            tile("Mes trips", "map.fill", Theme.info) { tab = .trips }
        }
    }

    /// Same SOS as on the riding screens: hold SOS 1.5 s = call, message = SMS with the exact position,
    /// thumb = « petit point » (all is well + town). Without a contact, one tap to set it.
    @ViewBuilder private var sosRow: some View {
        if settings.sosPhone.isEmpty {
            Button { tab = .settings } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sos.circle.fill").font(.title).foregroundStyle(Theme.camera)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ajoute ton contact SOS").font(.subheadline.bold())
                        Text("Appel en un geste, SMS avec ta position exacte").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                }
                .padding(14)
                .glass(radius: 20)
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SOSButton(name: settings.sosName, phone: settings.sosPhone, location: location)
                Text("Maintiens SOS pour appeler · ✉︎ position par SMS · 👍 petit point")
                    .font(.caption2).foregroundStyle(Theme.muted)
                    .padding(.leading, 4)
            }
        }
    }

    private func tile(_ title: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2).foregroundStyle(color)
                Text(title).font(.caption.bold())
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .glass(radius: 20)
        }
        .buttonStyle(.plain)
    }
}
