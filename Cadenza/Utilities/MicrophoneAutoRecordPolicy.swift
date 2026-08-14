enum MicrophoneAutoRecordAction: Equatable, Sendable {
    case enable
    case request
    case suspend
}

/// Settings-side policy for the auto-record toggle. The stored toggle is user
/// intent and is never cleared by permission state: while microphone access is
/// missing the intent suspends (hint shown here, RecordingEngine fails closed
/// at auto-start time) and resumes on its own once access returns.
enum MicrophoneAutoRecordPolicy {
    static func action(for status: PermissionStatus) -> MicrophoneAutoRecordAction {
        switch status {
        case .granted:
            .enable
        case .notDetermined:
            .request
        case .denied:
            .suspend
        }
    }

    static func showsPermissionMessage(
        autoRecordEnabled: Bool,
        status: PermissionStatus
    ) -> Bool {
        autoRecordEnabled && status != .granted
    }
}
