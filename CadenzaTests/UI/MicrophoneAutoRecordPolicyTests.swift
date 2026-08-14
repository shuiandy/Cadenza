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

    @Test func deniedPermissionSuspendsWithoutClearingIntent() {
        #expect(MicrophoneAutoRecordPolicy.action(for: .denied) == .suspend)
    }

    @Test func permissionMessageShowsWhileEnabledIntentIsSuspended() {
        #expect(MicrophoneAutoRecordPolicy.showsPermissionMessage(
            autoRecordEnabled: true, status: .denied))
        #expect(MicrophoneAutoRecordPolicy.showsPermissionMessage(
            autoRecordEnabled: true, status: .notDetermined))
    }

    @Test func permissionMessageHidesOnceAccessReturns() {
        #expect(!MicrophoneAutoRecordPolicy.showsPermissionMessage(
            autoRecordEnabled: true, status: .granted))
    }

    @Test func permissionMessageNeverShowsWhileAutoRecordIsOff() {
        for status in [PermissionStatus.granted, .notDetermined, .denied] {
            #expect(!MicrophoneAutoRecordPolicy.showsPermissionMessage(
                autoRecordEnabled: false, status: status))
        }
    }
}
