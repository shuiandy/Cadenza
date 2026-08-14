import Foundation
import Observation

/// Checks GitHub Releases and owns the app's update-check state.
@MainActor @Observable
final class AppUpdateController {
    enum State: Equatable {
        case idle
        case checking
        case updateAvailable
        case upToDate
        case failed(String)
    }

    struct Release: Equatable, Sendable {
        let version: String
        let name: String?
        let pageURL: URL
    }

    typealias ReleaseChecker = @MainActor (URL) async throws -> Release
    typealias ReleaseDataLoader = @MainActor (URLRequest) async throws -> (Data, URLResponse)

    static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/shuiandy/Cadenza/releases/latest"
    )!
    static let automaticChecksEnabledKey = "automaticallyChecksForUpdates"
    static let lastCheckDateKey = "lastAppUpdateCheckDate"
    static let defaultAutomaticallyChecksForUpdates = true
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    static let automaticMonitorInterval: Duration = .seconds(60 * 60)

    private(set) var state: State = .idle
    private(set) var availableRelease: Release?
    private(set) var automaticallyChecksForUpdates: Bool

    var availableReleaseURL: URL? {
        availableRelease?.pageURL
    }

    @ObservationIgnored private let checker: ReleaseChecker
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var inFlightCheck: InFlightCheck?

    init(
        checker: @escaping ReleaseChecker = AppUpdateController.fetchLatestRelease,
        defaults: UserDefaults = .standard,
        currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0",
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.checker = checker
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.now = now
        automaticallyChecksForUpdates = defaults.object(
            forKey: Self.automaticChecksEnabledKey
        ) as? Bool ?? Self.defaultAutomaticallyChecksForUpdates
    }

    /// Persists the preference and checks once when automatic checks are enabled.
    @discardableResult
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) -> Task<Void, Never>? {
        automaticallyChecksForUpdates = enabled
        defaults.set(enabled, forKey: Self.automaticChecksEnabledKey)

        guard enabled else { return nil }
        return Task { @MainActor [weak self] in
            guard let self else { return }
            await self.checkAutomaticallyIfNeeded()
        }
    }

    /// Runs only when enabled and the previous successful check is at least 24 hours old.
    func checkAutomaticallyIfNeeded() async {
        guard automaticallyChecksForUpdates, automaticCheckIsDue else { return }
        await check()
    }

    /// Keeps long-running app sessions eligible for their next daily check.
    func monitorAutomaticChecks() async {
        while !Task.isCancelled {
            await checkAutomaticallyIfNeeded()
            do {
                try await Task.sleep(for: Self.automaticMonitorInterval)
            } catch {
                return
            }
        }
    }

    /// User-initiated checks bypass both the automatic preference and throttle.
    func checkManually() async {
        await check()
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let candidate = SemanticVersion(candidate),
              let current = SemanticVersion(current) else {
            return false
        }
        return candidate > current
    }

    private var automaticCheckIsDue: Bool {
        guard let lastCheck = defaults.object(forKey: Self.lastCheckDateKey) as? Date else {
            return true
        }
        return now().timeIntervalSince(lastCheck) >= Self.automaticCheckInterval
    }

    private func check() async {
        let claim: InFlightCheck
        if let inFlightCheck {
            claim = inFlightCheck
        } else {
            state = .checking
            availableRelease = nil

            let checker = checker
            let task = Task { @MainActor in
                do {
                    return CheckOutcome.release(
                        try await checker(Self.latestReleaseAPIURL)
                    )
                } catch {
                    return CheckOutcome.failure(error.localizedDescription)
                }
            }
            claim = InFlightCheck(id: UUID(), task: task)
            inFlightCheck = claim
        }

        let outcome = await claim.task.value
        guard inFlightCheck?.id == claim.id else { return }
        inFlightCheck = nil

        switch outcome {
        case .release(let release):
            guard let releaseVersion = SemanticVersion(release.version),
                  let installedVersion = SemanticVersion(currentVersion) else {
                state = .failed(CheckError.invalidVersion.localizedDescription)
                return
            }
            defaults.set(now(), forKey: Self.lastCheckDateKey)

            if releaseVersion > installedVersion {
                availableRelease = release
                state = .updateAvailable
            } else {
                state = .upToDate
            }
        case .failure(let message):
            state = .failed(message)
        }
    }

    private static func fetchLatestRelease(from endpoint: URL) async throws -> Release {
        let checker = githubReleaseChecker { request in
            try await URLSession.shared.data(for: request)
        }
        return try await checker(endpoint)
    }

    static func githubReleaseChecker(
        dataLoader: @escaping ReleaseDataLoader
    ) -> ReleaseChecker {
        { endpoint in
            var request = URLRequest(url: endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Cadenza", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await dataLoader(request)
            return try decodeLatestRelease(data: data, response: response)
        }
    }

    static func decodeLatestRelease(data: Data, response: URLResponse) throws -> Release {
        guard let response = response as? HTTPURLResponse else {
            throw CheckError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CheckError.httpStatus(response.statusCode)
        }

        let payload = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        let version = payload.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, payload.htmlURL.scheme?.lowercased() == "https" else {
            throw CheckError.invalidResponse
        }
        return Release(version: version, name: payload.name, pageURL: payload.htmlURL)
    }
}

private extension AppUpdateController {
    struct InFlightCheck {
        let id: UUID
        let task: Task<CheckOutcome, Never>
    }

    enum CheckOutcome: Sendable {
        case release(Release)
        case failure(String)
    }

    struct GitHubReleaseResponse: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
        }
    }

    enum CheckError: LocalizedError {
        case invalidResponse
        case invalidVersion
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "GitHub returned an invalid release response."
            case .invalidVersion:
                "The release version could not be compared with this app version."
            case .httpStatus(let status):
                "GitHub returned HTTP \(status)."
            }
        }
    }

    struct SemanticVersion: Comparable {
        let major: Int
        let minor: Int
        let patch: Int
        let prerelease: [String]?

        init?(_ rawValue: String) {
            var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.first == "v" || value.first == "V" {
                value.removeFirst()
            }

            let withoutMetadata = value.split(
                separator: "+",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0]
            let versionParts = withoutMetadata.split(
                separator: "-",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let coreParts = versionParts[0].split(
                separator: ".",
                omittingEmptySubsequences: false
            )

            guard (1...3).contains(coreParts.count),
                  coreParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
                return nil
            }

            let numericParts = coreParts.compactMap { Int($0) }
            guard numericParts.count == coreParts.count else { return nil }
            major = numericParts[0]
            minor = numericParts.count > 1 ? numericParts[1] : 0
            patch = numericParts.count > 2 ? numericParts[2] : 0

            if versionParts.count == 2 {
                let identifiers = versionParts[1].split(
                    separator: ".",
                    omittingEmptySubsequences: false
                ).map(String.init)
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
                guard !identifiers.isEmpty,
                      identifiers.allSatisfy({ identifier in
                          !identifier.isEmpty
                              && identifier.unicodeScalars.allSatisfy(allowed.contains)
                      }) else {
                    return nil
                }
                prerelease = identifiers
            } else {
                prerelease = nil
            }
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil):
                return false
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (.some(let lhsIdentifiers), .some(let rhsIdentifiers)):
                for (lhsIdentifier, rhsIdentifier) in zip(lhsIdentifiers, rhsIdentifiers) {
                    if lhsIdentifier == rhsIdentifier { continue }

                    let lhsNumber = Int(lhsIdentifier)
                    let rhsNumber = Int(rhsIdentifier)
                    switch (lhsNumber, rhsNumber) {
                    case (.some(let lhsNumber), .some(let rhsNumber)):
                        return lhsNumber < rhsNumber
                    case (.some, nil):
                        return true
                    case (nil, .some):
                        return false
                    case (nil, nil):
                        return lhsIdentifier < rhsIdentifier
                    }
                }
                return lhsIdentifiers.count < rhsIdentifiers.count
            }
        }
    }
}
