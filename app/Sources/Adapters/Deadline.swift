import Foundation

/// Waits for `work` at most `seconds`, then gives up (nil), even when the work cannot be interrupted: MapKit
/// directions, searches and geocoding ignore task cancellation, so a task-group timeout used to wait for them to
/// finish and a « 5 s » wait could last a minute on a poor network. The work keeps running unseen and is dropped.
enum Deadline {
    static func run<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let worker = Task {
                let value = try? await work()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() {
                    worker.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The first caller wins, from any thread.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
