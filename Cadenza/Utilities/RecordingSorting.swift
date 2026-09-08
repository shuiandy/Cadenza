import Foundation

/// The library's sort keys, shared by the store, the library page and folder
/// pages so every surface orders identically for the same key.
enum RecordingSorting {
    static func sort(_ recordings: [RecordingDTO], by key: String) -> [RecordingDTO] {
        switch key {
        case "dateOldest":
            return recordings.sorted { $0.startDate < $1.startDate }
        case "recentlyAccessed":
            return recordings.sorted { ($0.lastAccessedDate ?? .distantPast) > ($1.lastAccessedDate ?? .distantPast) }
        case "nameAZ":
            return recordings.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "nameZA":
            return recordings.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        default:
            return recordings.sorted { $0.startDate > $1.startDate }
        }
    }
}

/// One value per (token, key), recomputed only when the token moves. Library
/// derivations (sorting, tag and speaker histograms) used to run inside view
/// bodies on every invalidation: each search keystroke, each selection change,
/// each timer tick paid an O(n log n) pass over the whole library.
struct TokenKeyedMemo {
    private var slots: [String: (token: Int, value: Any)] = [:]
    private(set) var computeCount = 0

    mutating func value<T>(token: Int, key: String, compute: () -> T) -> T {
        if let slot = slots[key], slot.token == token, let value = slot.value as? T {
            return value
        }
        let value = compute()
        slots[key] = (token, value)
        computeCount += 1
        return value
    }
}
