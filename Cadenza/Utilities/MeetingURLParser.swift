import EventKit
import Foundation

/// Extracts meeting URLs from calendar events and identifies the meeting app.
enum MeetingURLParser {

    private static let patterns: [String] = [
        #"https://[\w.-]*zoom\.us/[jm]y?/\S+"#,
        #"https://teams\.microsoft\.com/l/meetup-join/\S+"#,
        #"https://meet\.google\.com/[a-z]+-[a-z]+-[a-z]+"#,
        #"https://[\w.-]*webex\.com/\S+"#,
        #"https://facetime\.apple\.com/\S+"#,
        #"https://app\.slack\.com/huddle/\S+"#,
    ]

    /// Extract a meeting URL from an EKEvent by checking url, location, and notes fields.
    static func extractURL(from event: EKEvent) -> URL? {
        // Check the event's URL property first
        if let url = event.url, isMeetingURL(url) {
            return url
        }

        // Search in location and notes
        let searchFields = [event.location, event.notes].compactMap { $0 }
        let combined = searchFields.joined(separator: " ")

        return findMeetingURL(in: combined)
    }

    /// Find a meeting URL in a string.
    static func findMeetingURL(in text: String) -> URL? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(text.startIndex..., in: text)

            for match in regex.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let urlString = String(text[matchRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'>)"))
                guard let url = URL(string: urlString), detectApp(from: url) != nil else {
                    continue
                }
                return url
            }
        }
        return nil
    }

    /// Detect which meeting app a URL corresponds to.
    static func detectApp(from url: URL) -> MeetingApp? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let rawHost = url.host?.lowercased() else {
            return nil
        }

        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        guard let path = validatedPath(for: url) else { return nil }

        if matchesHost(host, domain: "zoom.us", allowsSubdomains: true),
           path.segments.count == 2,
           path.segments[0] == "j" || path.segments[0] == "my" {
            return .zoom
        }
        if matchesHost(host, domain: "teams.microsoft.com"),
           path.segments.count >= 3,
           path.segments[0] == "l",
           path.segments[1] == "meetup-join" {
            return .teams
        }
        if matchesHost(host, domain: "meet.google.com"),
           path.segments.count == 1,
           isGoogleMeetCode(path.segments[0]) {
            return .googleMeet
        }
        if matchesHost(host, domain: "webex.com", allowsSubdomains: true),
           isWebexMeetingPath(path) {
            return .webex
        }
        if matchesHost(host, domain: "facetime.apple.com"),
           path.segments.first == "join",
           path.segments.count >= 2 || !path.fragment.isEmpty {
            return .facetime
        }
        if matchesHost(host, domain: "app.slack.com"),
           path.segments.count >= 3,
           path.segments[0] == "huddle" {
            return .slack
        }
        return nil
    }

    /// Check if a URL is a known meeting URL.
    static func isMeetingURL(_ url: URL) -> Bool {
        detectApp(from: url) != nil
    }

    /// Re-checks the complete URL at the last responsible moment before it is
    /// handed to Launch Services. Persisted calendar data is not trusted just
    /// because it was classified earlier.
    @discardableResult
    static func openIfTrusted(
        _ url: URL,
        using opener: (URL) -> Bool
    ) -> Bool {
        guard isMeetingURL(url) else { return false }
        return opener(url)
    }

    private static func matchesHost(
        _ host: String,
        domain: String,
        allowsSubdomains: Bool = false
    ) -> Bool {
        host == domain || (allowsSubdomains && host.hasSuffix(".\(domain)"))
    }

    private struct ValidatedPath {
        let segments: [String]
        let queryItems: [URLQueryItem]
        let fragment: String
    }

    /// Validates both encoded and decoded forms before route matching. This
    /// prevents a provider-looking prefix from being normalized into a
    /// different destination by Launch Services or the remote server.
    private static func validatedPath(for url: URL) -> ValidatedPath? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else { return nil }

        let encodedPath = components.percentEncodedPath
        let lowercasedEncodedPath = encodedPath.lowercased()
        guard encodedPath.hasPrefix("/"),
              !lowercasedEncodedPath.contains("%2f"),
              !lowercasedEncodedPath.contains("%5c"),
              let decodedPath = encodedPath.removingPercentEncoding,
              !decodedPath.contains("%"),
              !decodedPath.contains("\\") else {
            return nil
        }

        let pathParts = decodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard pathParts.first?.isEmpty == true else { return nil }
        let routeParts = pathParts.dropFirst()
        guard !routeParts.isEmpty,
              routeParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        return ValidatedPath(
            segments: routeParts.map { $0.lowercased() },
            queryItems: components.queryItems ?? [],
            fragment: components.fragment ?? ""
        )
    }

    private static func isGoogleMeetCode(_ code: String) -> Bool {
        let groups = code.split(separator: "-", omittingEmptySubsequences: false)
        return groups.count == 3
            && groups.allSatisfy { group in
                !group.isEmpty && group.allSatisfy { $0.isASCII && $0.isLetter }
            }
    }

    private static func isWebexMeetingPath(_ path: ValidatedPath) -> Bool {
        guard let first = path.segments.first else { return false }
        if (first == "meet" || first == "join"), path.segments.count >= 2 {
            return true
        }
        if path.segments.contains("meeting"),
           first == "webappng" || path.segments.contains("joinservice") {
            return true
        }

        guard let endpoint = path.segments.last,
              endpoint == "j.php" || endpoint == "e.php" else {
            return false
        }
        return path.queryItems.contains { item in
            item.name.caseInsensitiveCompare("MTID") == .orderedSame
                && !(item.value ?? "").isEmpty
        }
    }
}
