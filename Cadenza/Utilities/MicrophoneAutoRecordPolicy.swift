enum MicrophoneAutoRecordAction: Equatable, Sendable {
    case enable
    case request
    case reject
}

enum MicrophoneAutoRecordPolicy {
    static func action(for status: PermissionStatus) -> MicrophoneAutoRecordAction {
        switch status {
        case .granted:
            .enable
        case .notDetermined:
            .request
        case .denied:
            .reject
        }
    }
}
