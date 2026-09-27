import Foundation
import Security
import TripCore

/// Non-secret preferences (UserDefaults) + secrets (Keychain).
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var garage: [Bike] { didSet { persist(garage, "garage") } }
    @Published var sosName: String { didSet { defaults.set(sosName, forKey: "sosName") } }
    @Published var sosPhone: String { didSet { defaults.set(sosPhone, forKey: "sosPhone") } }
    @Published var defaultKmPerDay: Double { didSet { defaults.set(defaultKmPerDay, forKey: "defaultKmPerDay") } }
    @Published var companionURL: String { didSet { defaults.set(companionURL, forKey: "companionURL") } }
    @Published var voiceEnabled: Bool { didSet { defaults.set(voiceEnabled, forKey: "voiceEnabled") } }
    @Published var radarAnnouncements: Bool { didSet { defaults.set(radarAnnouncements, forKey: "radarAnnouncements") } }
    @Published var forceDark: Bool { didSet { defaults.set(forceDark, forKey: "forceDark") } }
    @Published var pace: PaceEstimator { didSet { persist(pace, "pace") } }

    init() {
        let d = UserDefaults.standard   // not self.defaults: self is not fully initialized yet
        garage = Self.load([Bike].self, "garage") ?? []
        sosName = d.string(forKey: "sosName") ?? ""
        sosPhone = d.string(forKey: "sosPhone") ?? ""
        defaultKmPerDay = (d.object(forKey: "defaultKmPerDay") as? Double) ?? 300
        companionURL = d.string(forKey: "companionURL") ?? ""
        voiceEnabled = (d.object(forKey: "voiceEnabled") as? Bool) ?? true
        radarAnnouncements = d.bool(forKey: "radarAnnouncements")   // off by default
        forceDark = d.bool(forKey: "forceDark")
        pace = Self.load(PaceEstimator.self, "pace") ?? PaceEstimator()
    }

    var companionToken: String {
        get { Keychain.read("companionToken") ?? "" }
        set { Keychain.write("companionToken", newValue); objectWillChange.send() }
    }

    var tomtomKey: String {
        get { Keychain.read("tomtomKey") ?? "" }
        set { Keychain.write("tomtomKey", newValue); objectWillChange.send() }
    }

    private func persist<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

enum Keychain {
    static let service = "fr.plandefab.mototrip"

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
