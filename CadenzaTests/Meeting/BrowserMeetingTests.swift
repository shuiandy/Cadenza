import Testing
@testable import Cadenza

@Suite("BrowserMeeting")
struct BrowserMeetingTests {

    private let chrome = BrowserMeetingFamily.family(forBundleID: "com.google.Chrome")!
    private let safari = BrowserMeetingFamily.family(forBundleID: "com.apple.Safari")!

    // MARK: - Window titles

    @Test(arguments: [
        "Meet - abc-defg-hij",
        "Meet - abc-defg-hij 🔊",
        "Meet – abc-defg-hij",
        "Meet — abc-defg-hij",
    ])
    func meetCallPageTitlesMatch(_ title: String) {
        #expect(GoogleMeetWindowTitle.isCallPage(title))
    }

    @Test(arguments: [
        "Google Meet",
        "Meet",
        "meet.google.com/new",
        "Meet - Design review",
        "Meeting notes - abc-defg-hij",
        "Meet - abc-defg",
        "",
    ])
    func otherTitlesDoNotMatch(_ title: String) {
        #expect(!GoogleMeetWindowTitle.isCallPage(title))
    }

    @Test func missingTitleDoesNotMatch() {
        #expect(!GoogleMeetWindowTitle.isCallPage(nil))
    }

    // MARK: - Browser families

    @Test func chromeMicrophoneInputIsReadFromItsHelper() {
        let helperInput = ["com.google.Chrome.helper": AudioProcessUsage(isRunningInput: true, isRunningOutput: false)]
        let mainInput = ["com.google.Chrome": AudioProcessUsage(isRunningInput: true, isRunningOutput: false)]

        #expect(chrome.isMicrophoneInputActive(in: helperInput))
        #expect(!chrome.isMicrophoneInputActive(in: mainInput))
    }

    @Test func processTapCapturesBrowserHelpers() {
        #expect(ProcessTapSystemAudioCapture.captureBundleIDs(for: "com.google.Chrome")
            == ["com.google.Chrome", "com.google.Chrome.helper"])
        #expect(ProcessTapSystemAudioCapture.captureBundleIDs(for: "com.apple.Safari")
            == ["com.apple.Safari", "com.apple.WebKit.GPU"])
        #expect(ProcessTapSystemAudioCapture.captureBundleIDs(for: "us.zoom.xos") == ["us.zoom.xos"])
        #expect(ProcessTapSystemAudioCapture.captureBundleIDs(for: "com.microsoft.teams2")
            == ["com.microsoft.teams2", "com.microsoft.teams2.modulehost"])
    }

    // MARK: - Start evaluation

    @Test func microphoneAndMeetWindowStart() {
        let observations = [observation(chrome, input: true, window: true)]
        #expect(BrowserMeetingEvaluator.startingBrowser(observations, calendarIsGoogleMeet: false) == chrome)
    }

    @Test func microphoneAndMeetEventStart() {
        let observations = [observation(chrome, input: true, window: false)]
        #expect(BrowserMeetingEvaluator.startingBrowser(observations, calendarIsGoogleMeet: true) == chrome)
    }

    @Test func microphoneAloneDoesNotStart() {
        let observations = [observation(chrome, input: true, window: false)]
        #expect(BrowserMeetingEvaluator.startingBrowser(observations, calendarIsGoogleMeet: false) == nil)
    }

    @Test func meetWindowAndEventWithoutMicrophoneDoNotStart() {
        let observations = [observation(chrome, input: false, window: true)]
        #expect(BrowserMeetingEvaluator.startingBrowser(observations, calendarIsGoogleMeet: true) == nil)
    }

    @Test func sharedAudioProcessNeedsMeetWindow() {
        let withoutWindow = [observation(safari, input: true, window: false)]
        let withWindow = [observation(safari, input: true, window: true)]

        #expect(BrowserMeetingEvaluator.startingBrowser(withoutWindow, calendarIsGoogleMeet: true) == nil)
        #expect(BrowserMeetingEvaluator.startingBrowser(withWindow, calendarIsGoogleMeet: false) == safari)
    }

    @Test func browserShowingMeetWindowIsPreferred() {
        let observations = [
            observation(chrome, input: true, window: false),
            observation(safari, input: true, window: true),
        ]
        #expect(BrowserMeetingEvaluator.startingBrowser(observations, calendarIsGoogleMeet: true) == safari)
    }

    private func observation(
        _ browser: BrowserMeetingFamily,
        input: Bool,
        window: Bool
    ) -> BrowserMeetingObservation {
        BrowserMeetingObservation(browser: browser, microphoneInputActive: input, hasMeetCallWindow: window)
    }
}
