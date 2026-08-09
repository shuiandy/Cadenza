import Foundation
import Testing
@testable import Cadenza

@Suite("MeetingURLParser")
struct MeetingURLParserTests {

    // MARK: - Zoom

    @Test func detectZoomURL() {
        let url = URL(string: "https://zoom.us/j/1234567890")!
        #expect(MeetingURLParser.detectApp(from: url) == .zoom)
    }

    @Test func detectZoomMyURL() {
        let url = URL(string: "https://zoom.us/my/username")!
        #expect(MeetingURLParser.detectApp(from: url) == .zoom)
    }

    @Test func findZoomURLInText() {
        let text = "Join us at https://zoom.us/j/123456 for the meeting"
        let url = MeetingURLParser.findMeetingURL(in: text)
        #expect(url != nil)
        #expect(url!.absoluteString.contains("zoom.us"))
    }

    // MARK: - Teams

    @Test func detectTeamsURL() {
        let url = URL(string: "https://teams.microsoft.com/l/meetup-join/abc123")!
        #expect(MeetingURLParser.detectApp(from: url) == .teams)
    }

    @Test func findTeamsURLInText() {
        let text = "Meeting link: https://teams.microsoft.com/l/meetup-join/something"
        let url = MeetingURLParser.findMeetingURL(in: text)
        #expect(url != nil)
        #expect(MeetingURLParser.detectApp(from: url!) == .teams)
    }

    // MARK: - Google Meet

    @Test func detectGoogleMeetURL() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        #expect(MeetingURLParser.detectApp(from: url) == .googleMeet)
    }

    @Test func findGoogleMeetInText() {
        let text = "Join at https://meet.google.com/abc-defg-hij"
        let url = MeetingURLParser.findMeetingURL(in: text)
        #expect(url != nil)
        #expect(MeetingURLParser.detectApp(from: url!) == .googleMeet)
    }

    // MARK: - Webex

    @Test func detectWebexURL() {
        let url = URL(string: "https://company.webex.com/meet/username")!
        #expect(MeetingURLParser.detectApp(from: url) == .webex)
    }

    @Test func findWebexInText() {
        let text = "Webex meeting: https://company.webex.com/meet/john"
        let url = MeetingURLParser.findMeetingURL(in: text)
        #expect(url != nil)
    }

    // MARK: - FaceTime

    @Test func detectFaceTimeURL() {
        let url = URL(string: "https://facetime.apple.com/join/abc123")!
        #expect(MeetingURLParser.detectApp(from: url) == .facetime)
    }

    // MARK: - Slack

    @Test func detectSlackHuddleURL() {
        let url = URL(string: "https://app.slack.com/huddle/T123/C456")!
        #expect(MeetingURLParser.detectApp(from: url) == .slack)
    }

    // MARK: - Non-meeting URLs

    @Test func nonMeetingURLReturnsNil() {
        let url = URL(string: "https://example.com")!
        #expect(MeetingURLParser.detectApp(from: url) == nil)
    }

    @Test func nonMeetingURLIsNotMeetingURL() {
        let url = URL(string: "https://google.com")!
        #expect(MeetingURLParser.isMeetingURL(url) == false)
    }

    @Test func meetingURLIsMeetingURL() {
        let url = URL(string: "https://zoom.us/j/123")!
        #expect(MeetingURLParser.isMeetingURL(url) == true)
    }

    // MARK: - findMeetingURL Edge Cases

    @Test func findMeetingURLInEmptyString() {
        let url = MeetingURLParser.findMeetingURL(in: "")
        #expect(url == nil)
    }

    @Test func findMeetingURLInNonMeetingText() {
        let url = MeetingURLParser.findMeetingURL(in: "No meeting link here, just regular text")
        #expect(url == nil)
    }

    @Test func findMeetingURLTrimsTrailingCharacters() {
        let text = """
        Meeting: "https://zoom.us/j/123456"
        """
        let url = MeetingURLParser.findMeetingURL(in: text)
        #expect(url != nil)
        // URL should not end with quote
        #expect(!url!.absoluteString.hasSuffix("\""))
    }

    @Test func findMeetingURLCaseInsensitive() {
        let text = "Join at HTTPS://ZOOM.US/j/123456"
        let url = MeetingURLParser.findMeetingURL(in: text)
        #expect(url != nil)
    }

    @Test func findMeetingURLMultipleURLsReturnsFirst() {
        let text = "Zoom: https://zoom.us/j/111 or Teams: https://teams.microsoft.com/l/meetup-join/abc"
        let url = MeetingURLParser.findMeetingURL(in: text)
        #expect(url != nil)
        // Patterns are ordered, Zoom is first
        #expect(MeetingURLParser.detectApp(from: url!) == .zoom)
    }

    // MARK: - URL with Query Parameters

    @Test func findZoomURLWithPassword() {
        let text = "Join: https://zoom.us/j/123456?pwd=abc123XYZ"
        let url = MeetingURLParser.findMeetingURL(in: text)
        #expect(url != nil)
        #expect(MeetingURLParser.detectApp(from: url!) == .zoom)
    }

    @Test func findGoogleMeetWithFragment() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        #expect(MeetingURLParser.detectApp(from: url) == .googleMeet)
        #expect(MeetingURLParser.isMeetingURL(url))
    }

    // MARK: - Trust Boundary

    @Test func rejectsHTTPMeetingURL() {
        let url = URL(string: "http://zoom.us/j/1234567890")!
        #expect(MeetingURLParser.detectApp(from: url) == nil)
        #expect(!MeetingURLParser.isMeetingURL(url))
    }

    @Test func rejectsProviderNameOutsideCanonicalHost() {
        let urls = [
            "https://zoom.us.attacker.example/j/123",
            "https://evilzoom.us/j/123",
            "https://webex.com.attacker.example/meet/alice",
            "https://attacker.example/?next=zoom.us/j/123",
            "https://zoom.us@attacker.example/j/123",
        ].compactMap(URL.init(string:))

        #expect(urls.count == 5)
        for url in urls {
            #expect(MeetingURLParser.detectApp(from: url) == nil)
            #expect(!MeetingURLParser.isMeetingURL(url))
        }
    }

    @Test func rejectsWrongPathAndNonstandardPort() {
        let urls = [
            "https://zoom.us/pricing",
            "https://teams.microsoft.com/attacker/l/meetup-join/123",
            "https://app.slack.com/not-a-huddle/T123/C456",
            "https://company.webex.com/pricing",
            "https://zoom.us:8443/j/123",
        ].compactMap(URL.init(string:))

        #expect(urls.count == 5)
        for url in urls {
            #expect(MeetingURLParser.detectApp(from: url) == nil)
        }
    }

    @Test func rejectsDotSegmentsEncodedSeparatorsAndTrustedHostCredentials() {
        let urls = [
            "https://zoom.us/j/../pricing",
            "https://zoom.us/j/%2e%2e/pricing",
            "https://teams.microsoft.com/l/meetup-join/%2E%2E/evil",
            "https://facetime.apple.com/join/./not-a-call",
            "https://zoom.us/j%2F123",
            "https://app.slack.com/huddle%2fT123/C456",
            "https://user:password@zoom.us/j/123",
        ].compactMap(URL.init(string:))

        #expect(urls.count == 7)
        for url in urls {
            #expect(MeetingURLParser.detectApp(from: url) == nil)
            #expect(!MeetingURLParser.isMeetingURL(url))
        }
    }

    @Test func acceptsCanonicalHostsAndProviderSubdomains() {
        #expect(MeetingURLParser.detectApp(
            from: URL(string: "https://us06web.zoom.us/j/123")!
        ) == .zoom)
        #expect(MeetingURLParser.detectApp(
            from: URL(string: "https://company.webex.com/meet/alice")!
        ) == .webex)
        #expect(MeetingURLParser.detectApp(
            from: URL(string: "https://zoom.us:443/my/alice")!
        ) == .zoom)
        #expect(MeetingURLParser.detectApp(
            from: URL(string: "https://teams.microsoft.com/l/meetup-join/19%3Ameeting_abc%40thread.v2/0")!
        ) == .teams)
        #expect(MeetingURLParser.detectApp(
            from: URL(string: "https://company.webex.com/company/j.php?MTID=abc123")!
        ) == .webex)
        #expect(MeetingURLParser.detectApp(
            from: URL(string: "https://company.webex.com/company/e.php?MTID=event123")!
        ) == .webex)
        #expect(MeetingURLParser.detectApp(
            from: URL(string: "https://company.webex.com/webappng/sites/company/meeting/info/abc")!
        ) == .webex)
        #expect(MeetingURLParser.detectApp(
            from: URL(string: "https://company.webex.com/wbxmjs/joinservice/sites/company/meeting/download/abc")!
        ) == .webex)
        #expect(MeetingURLParser.detectApp(
            from: URL(string: "https://facetime.apple.com/join#v=1&p=alice&k=secret")!
        ) == .facetime)
    }

    @Test func launchRevalidatesImmediatelyBeforeOpening() {
        var openedURLs: [URL] = []
        let hostile = URL(string: "https://attacker.example/?next=zoom.us/j/123")!
        let canonicalHostTraversal = URL(string: "https://zoom.us/j/../pricing")!
        let trusted = URL(string: "https://zoom.us/j/123")!

        #expect(!MeetingURLParser.openIfTrusted(hostile) { url in
            openedURLs.append(url)
            return true
        })
        #expect(openedURLs.isEmpty)

        #expect(!MeetingURLParser.openIfTrusted(canonicalHostTraversal) { url in
            openedURLs.append(url)
            return true
        })
        #expect(openedURLs.isEmpty)

        #expect(MeetingURLParser.openIfTrusted(trusted) { url in
            openedURLs.append(url)
            return true
        })
        #expect(openedURLs == [trusted])
    }

    // MARK: - Non-meeting URL on meeting domain

    @Test func nonMeetingZoomPageReturnsNil() {
        let text = "Check out https://zoom.us/pricing for plans"
        let url = MeetingURLParser.findMeetingURL(in: text)
        // /pricing doesn't match /j/ or /my/ patterns
        #expect(url == nil)
    }
}
