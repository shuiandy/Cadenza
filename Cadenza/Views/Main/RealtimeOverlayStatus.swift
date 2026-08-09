enum RealtimeOverlayStatus: Equatable, Sendable {
    case hidden
    case failure(String)
    case active(segmentCount: Int)
    case listening

    static func resolve(
        hint: String?,
        segmentCount: Int,
        isEnabled: Bool
    ) -> RealtimeOverlayStatus {
        if let hint {
            let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .failure(trimmed)
            }
        }
        if segmentCount > 0 {
            return .active(segmentCount: segmentCount)
        }
        return isEnabled ? .listening : .hidden
    }
}
