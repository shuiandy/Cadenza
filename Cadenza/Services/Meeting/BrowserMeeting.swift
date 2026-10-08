import Foundation

// MARK: - Browser Families

/// A browser that can host a Google Meet call, plus the processes that carry
/// its audio.
///
/// Browsers run WebRTC audio outside the main process, so the Process Audio
/// Object API reports a call's microphone input under a helper bundle ID while
/// the call's windows belong to the main process. Measured 2026-10-02: Chrome
/// captures through `com.google.Chrome.helper` and the main process never
/// reports input; Meet keeps that input open while muted and releases it within
/// about two seconds of leaving the call.
struct BrowserMeetingFamily: Sendable, Equatable {
    /// Main application bundle ID. Owns the windows and identifies the session.
    let bundleID: String
    /// Processes whose `isRunningInput` reflects this browser's microphone use.
    let audioBundleIDs: [String]
    /// The audio process also serves apps other than this browser, so its input
    /// can only be attributed to the browser through a Meet window.
    let audioProcessIsShared: Bool

    static let all: [BrowserMeetingFamily] = [
        // Measured.
        .init(bundleID: "com.google.Chrome", audioBundleIDs: ["com.google.Chrome.helper"], audioProcessIsShared: false),
        // Chromium's helper naming; not measured.
        .init(bundleID: "com.microsoft.edgemac", audioBundleIDs: ["com.microsoft.edgemac.helper"], audioProcessIsShared: false),
        .init(bundleID: "com.brave.Browser", audioBundleIDs: ["com.brave.Browser.helper"], audioProcessIsShared: false),
        // Arc and Dia share one helper bundle ID (measured on Dia).
        .init(bundleID: "company.thebrowser.Browser", audioBundleIDs: ["company.thebrowser.browser.helper"], audioProcessIsShared: false),
        .init(bundleID: "company.thebrowser.dia", audioBundleIDs: ["company.thebrowser.browser.helper"], audioProcessIsShared: false),
        // Every WebKit client shares the GPU process (measured).
        .init(bundleID: "com.apple.Safari", audioBundleIDs: ["com.apple.WebKit.GPU"], audioProcessIsShared: true),
    ]

    static let allAudioBundleIDs: [String] = Array(Set(all.flatMap(\.audioBundleIDs))).sorted()

    static func family(forBundleID bundleID: String) -> BrowserMeetingFamily? {
        all.first { $0.bundleID == bundleID }
    }

    func isMicrophoneInputActive(in usage: [String: AudioProcessUsage]) -> Bool {
        audioBundleIDs.contains { usage[$0]?.isRunningInput == true }
    }
}

// MARK: - Window Titles

enum GoogleMeetWindowTitle {
    /// Whether a browser window shows a Meet call page.
    ///
    /// Meet titles the preview page, the call itself and the page shown after
    /// leaving `Meet - abc-defg-hij`, sometimes with a trailing marker such as
    /// ` 🔊`. The home page is `Google Meet` and a loading call page is `Meet`.
    /// A match therefore identifies a call page, not whether the user is in
    /// the call; only the microphone answers that.
    static func isCallPage(_ title: String?) -> Bool {
        guard let title else { return false }
        for separator in [" - ", " – ", " — "] {
            let prefix = "Meet" + separator
            guard title.hasPrefix(prefix) else { continue }
            let code = title.dropFirst(prefix.count).prefix { !$0.isWhitespace }
            return MeetingURLParser.isGoogleMeetCode(String(code))
        }
        return false
    }
}

// MARK: - Evaluation

/// One browser's evidence for a Google Meet call during a single evaluation.
struct BrowserMeetingObservation: Sendable, Equatable {
    let browser: BrowserMeetingFamily
    /// The browser's audio process is using the microphone.
    let microphoneInputActive: Bool
    /// An on-screen window owned by the browser is a Meet call page.
    let hasMeetCallWindow: Bool
}

/// Decides when browser evidence starts a Google Meet session.
/// Pure function, no side effects, like `ConfidenceScorer`.
///
/// A browser holding the microphone is not a meeting by itself (dictation,
/// voice notes and other web calls look the same), so a start needs the
/// microphone plus a Meet call window or a Google Meet event happening now.
/// Once started, the session lasts while the browser keeps the microphone open:
/// the title cannot sustain it because switching tabs replaces it.
enum BrowserMeetingEvaluator {
    static func startingBrowser(
        _ observations: [BrowserMeetingObservation],
        calendarIsGoogleMeet: Bool
    ) -> BrowserMeetingFamily? {
        let withInput = observations.filter(\.microphoneInputActive)
        if let titled = withInput.first(where: \.hasMeetCallWindow) {
            return titled.browser
        }
        guard calendarIsGoogleMeet else { return nil }
        return withInput.first { !$0.browser.audioProcessIsShared }?.browser
    }
}
