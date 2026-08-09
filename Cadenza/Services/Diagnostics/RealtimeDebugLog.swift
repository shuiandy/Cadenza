import Foundation
import os

/// Thread-safe shared log for realtime transcription protocol events.
/// Used by diagnostic tests to capture what the transcribers see without console parsing.
final class RealtimeDebugLog: Sendable {
    static let shared = RealtimeDebugLog()

    private let maximumEntries: Int
    private let maximumEntryBytes: Int
    private let lock = OSAllocatedUnfairLock(initialState: [String]())

    init(maximumEntries: Int = 500, maximumEntryBytes: Int = 1_000) {
        precondition(maximumEntries > 0)
        precondition(maximumEntryBytes > 0)
        self.maximumEntries = maximumEntries
        self.maximumEntryBytes = maximumEntryBytes
    }

    var entries: [String] {
        lock.withLock { $0 }
    }

    func append(_ message: String) {
        var bytes = Array(message.utf8.prefix(maximumEntryBytes))
        var bounded = String(bytes: bytes, encoding: .utf8)
        while bounded == nil, !bytes.isEmpty {
            bytes.removeLast()
            bounded = String(bytes: bytes, encoding: .utf8)
        }
        let entry = bounded ?? ""
        lock.withLock { entries in
            entries.append(entry)
            if entries.count > maximumEntries {
                entries.removeFirst(entries.count - maximumEntries)
            }
        }
    }

    func clear() {
        lock.withLock { $0.removeAll(keepingCapacity: true) }
    }
}
