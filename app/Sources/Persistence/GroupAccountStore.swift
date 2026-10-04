import Foundation

/// `GroupStorage` on the iPhone: the account (tokens) and the server in the Keychain, preferences in UserDefaults.
final class DeviceGroupStorage: GroupStorage {
    private let defaults = UserDefaults.standard

    var config: GroupServerConfig? {
        get { readJSON("groupServer") }
        set { writeJSON(newValue, "groupServer") }
    }

    var tokens: GroupTokens? {
        get { readJSON("groupTokens") }
        set { writeJSON(newValue, "groupTokens") }
    }

    var displayName: String {
        get { defaults.string(forKey: "groupDisplayName") ?? "" }
        set { defaults.set(newValue, forKey: "groupDisplayName") }
    }

    var currentGroupId: String? {
        get { defaults.string(forKey: "groupCurrentId") }
        set { defaults.set(newValue, forKey: "groupCurrentId") }
    }

    var sharePosition: Bool {
        get { defaults.bool(forKey: "groupSharePosition") }
        set { defaults.set(newValue, forKey: "groupSharePosition") }
    }

    var pushToTalk: Bool {
        get { defaults.bool(forKey: "groupPushToTalk") }
        set { defaults.set(newValue, forKey: "groupPushToTalk") }
    }

    var lastSeenMessageId: Int {
        get { defaults.integer(forKey: "groupLastSeenMessage") }
        set { defaults.set(newValue, forKey: "groupLastSeenMessage") }
    }

    var importedShareIds: Set<String> {
        get { Set(defaults.stringArray(forKey: "groupImportedShares") ?? []) }
        set { defaults.set(Array(newValue), forKey: "groupImportedShares") }
    }

    private func readJSON<T: Decodable>(_ key: String) -> T? {
        guard let text = Keychain.read(key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else {
            Keychain.write(key, "")         // an empty value deletes the item
            return
        }
        Keychain.write(key, text)
    }
}
