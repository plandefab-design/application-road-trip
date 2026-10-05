import Foundation
import MetricKit

/// Real-world figures of this app on this iPhone (battery, GPS and screen use, launch time, hangs, crashes), measured
/// by iOS itself (MetricKit) and delivered about once a day. Kept as JSON in Documents/metrics, visible in the Files app;
/// nothing leaves the iPhone. Read-only: it never changes how the app behaves.
final class MetricsRecorder: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsRecorder()
    private static let keep = 30
    private var started = false
    private let folder: URL

    private override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("metrics", isDirectory: true)
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        // iOS keeps the last reports: written right away at launch instead of waiting for the next daily delivery.
        let manager = MXMetricManager.shared
        didReceive(manager.pastPayloads)
        didReceive(manager.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), kind: "metrics", date: payload.timeStampEnd) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), kind: "diagnostics", date: payload.timeStampEnd) }
    }

    private func save(_ json: Data, kind: String, date: Date) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        try? json.write(to: folder.appendingPathComponent("\(kind)-\(stamp).json"), options: .atomic)
        // Only the most recent files are kept (a few KB each).
        let files = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(Self.keep * 2) { try? manager.removeItem(at: old) }
    }
}
