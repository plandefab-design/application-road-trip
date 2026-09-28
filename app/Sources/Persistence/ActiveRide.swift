import Foundation

/// The trip stage being ridden: set when « Rouler » starts, cleared at the end of the stage. If the rider left
/// the riding screen before arriving (tap on Quitter, app closed), the home screen offers to rejoin it for 12 h.
@MainActor
final class ActiveRide: ObservableObject {
    static let shared = ActiveRide()
    static let resumeWindow: TimeInterval = 12 * 3600

    struct Session: Codable, Equatable {
        let tripId: String
        let day: Int
        let startedAt: Date
    }

    @Published private(set) var session: Session?
    private let key = "activeRide"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(Session.self, from: data) {
            session = saved
        }
    }

    /// The session to rejoin, if recent enough.
    var resumable: Session? {
        guard let s = session, Date().timeIntervalSince(s.startedAt) < Self.resumeWindow else { return nil }
        return s
    }

    func start(tripId: String, day: Int) {
        session = Session(tripId: tripId, day: day, startedAt: session?.tripId == tripId && session?.day == day
                          ? (session?.startedAt ?? Date()) : Date())
        save()
    }

    func finish() {
        session = nil
        save()
    }

    private func save() {
        if let session, let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
