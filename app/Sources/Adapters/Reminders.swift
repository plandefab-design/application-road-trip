import Foundation
import TripCore
import UserNotifications

/// Local notifications only (A9, no push): checklist items at 9:00 on their due day, and the SideStore
/// signature expiry. Permission is requested from the trip screen, never while riding (CLAUDE.md rule 9).
enum Reminders {
    private static var center: UNUserNotificationCenter { .current() }

    static func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func isAuthorized() async -> Bool {
        await center.notificationSettings().authorizationStatus == .authorized
    }

    /// Replaces the trip's reminders with one per unchecked item due in the future. Returns how many were set.
    @discardableResult
    static func schedule(trip: Trip, items: [ChecklistItem], now: Date = Date()) async -> Int {
        let prefix = "trip-\(trip.id)-"
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var count = 0
        for item in items where !item.done {
            guard let day = TripChecklist.dueDate(item, tripStart: trip.params.dateStart) else { continue }
            let d = utc.dateComponents([.year, .month, .day], from: day)
            let fire = DateComponents(year: d.year, month: d.month, day: d.day, hour: 9)
            guard let date = Calendar.current.date(from: fire), date > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(trip.name) — \(item.due)"
            content.body = item.label
            content.sound = .default
            let request = UNNotificationRequest(identifier: prefix + item.id, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: fire, repeats: false))
            if (try? await center.add(request)) != nil { count += 1 }
        }
        return count
    }

    /// Reminder the day before the app signature expires (free Apple account: 7 days).
    static func scheduleSignatureReminder(expiry: Date, now: Date = Date()) async {
        guard await isAuthorized() else { return }
        center.removePendingNotificationRequests(withIdentifiers: ["sidestore-expiry"])
        let fire = max(expiry.addingTimeInterval(-24 * 3_600), now.addingTimeInterval(60))
        guard fire < expiry else { return }
        let content = UNMutableNotificationContent()
        content.title = "MotoTrip expire bientôt"
        content.body = "Ouvre SideStore (LocalDevVPN connecté, Tailscale coupé) et rafraîchis MotoTrip avant \(expiry.formatted(date: .abbreviated, time: .shortened))."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSince(now), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: "sidestore-expiry", content: content, trigger: trigger))
    }
}

/// Signing information of the installed app, read from its embedded provisioning profile.
enum SigningInfo {
    /// Expiry of the signature (SideStore re-signs the app every 7 days with a free Apple account).
    static let expirationDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        return dict?["ExpirationDate"] as? Date
    }()
}

extension Reminders {
    /// Immediate local notification when a ride makes maintenance items due (only if notifications are allowed).
    static func notifyMaintenance(bike: String, items: [(item: MaintenanceItem, status: MaintenanceBook.Status)]) async {
        guard !items.isEmpty, await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Entretien — \(bike)"
        content.body = items.prefix(3).map { "\($0.item.label) : \($0.status.text)" }.joined(separator: "\n")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "maintenance-\(UUID().uuidString)", content: content, trigger: trigger))
    }
}
