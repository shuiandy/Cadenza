import Testing

@testable import Cadenza

@Suite("Auto-record microphone permission")
struct MicrophoneAutoRecordPolicyTests {
    @Test func grantedPermissionEnablesImmediately() {
        #expect(MicrophoneAutoRecordPolicy.action(for: .granted) == .enable)
    }

    @Test func undeterminedPermissionRequiresUserInitiatedRequest() {
        #expect(MicrophoneAutoRecordPolicy.action(for: .notDetermined) == .request)
    }

    @Test func deniedPermissionFailsClosed() {
        #expect(MicrophoneAutoRecordPolicy.action(for: .denied) == .reject)
    }
}
