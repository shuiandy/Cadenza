import Foundation

enum TimePeriod: Hashable, Comparable {
    case last7Days
    case last30Days
    case year(Int)

    var title: String {
        switch self {
        case .last7Days: String(localized: "Last 7 Days")
        case .last30Days: String(localized: "Last 30 Days")
        case .year(let y): String(y)
        }
    }

    // Sort order: most recent first
    private var sortKey: Int {
        switch self {
        case .last7Days: return Int.max
        case .last30Days: return Int.max - 1
        case .year(let y): return y
        }
    }

    static func < (lhs: TimePeriod, rhs: TimePeriod) -> Bool {
        lhs.sortKey > rhs.sortKey // descending: most recent first
    }
}

enum TimePeriodGrouper {
    static func group(_ recordings: [Recording]) -> [(period: TimePeriod, recordings: [Recording])] {
        let calendar = Calendar.current
        let now = Date()
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!

        var buckets: [TimePeriod: [Recording]] = [:]

        for recording in recordings {
            let period: TimePeriod
            if recording.startDate >= sevenDaysAgo {
                period = .last7Days
            } else if recording.startDate >= thirtyDaysAgo {
                period = .last30Days
            } else {
                period = .year(calendar.component(.year, from: recording.startDate))
            }
            buckets[period, default: []].append(recording)
        }

        // Sort recordings within each bucket by date descending
        return buckets
            .map { (period: $0.key, recordings: $0.value.sorted { $0.startDate > $1.startDate }) }
            .sorted { $0.period < $1.period }
    }

    static func group(_ recordings: [RecordingDTO]) -> [(period: TimePeriod, recordings: [RecordingDTO])] {
        let calendar = Calendar.current
        let now = Date()
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!

        var buckets: [TimePeriod: [RecordingDTO]] = [:]

        for recording in recordings {
            let period: TimePeriod
            if recording.startDate >= sevenDaysAgo {
                period = .last7Days
            } else if recording.startDate >= thirtyDaysAgo {
                period = .last30Days
            } else {
                period = .year(calendar.component(.year, from: recording.startDate))
            }
            buckets[period, default: []].append(recording)
        }

        return buckets
            .map { (period: $0.key, recordings: $0.value.sorted { $0.startDate > $1.startDate }) }
            .sorted { $0.period < $1.period }
    }
}
