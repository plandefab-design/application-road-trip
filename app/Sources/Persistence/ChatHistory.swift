import Foundation

/// Planner conversation kept on the iPhone, one file per trip (Documents/chats/<tripId>.json),
/// so reopening a trip shows the previous exchange with Claude.
enum ChatHistory {
    struct Message: Codable, Identifiable, Equatable {
        var id = UUID()
        let fromUser: Bool
        let text: String
    }

    private static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ tripId: String) -> URL { folder.appendingPathComponent("\(tripId).json") }

    static func load(_ tripId: String) -> [Message] {
        guard let data = try? Data(contentsOf: file(tripId)) else { return [] }
        return (try? JSONDecoder().decode([Message].self, from: data)) ?? []
    }

    static func save(_ messages: [Message], for tripId: String) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: file(tripId), options: .atomic)
    }

    static func delete(_ tripId: String) {
        try? FileManager.default.removeItem(at: file(tripId))
    }
}
