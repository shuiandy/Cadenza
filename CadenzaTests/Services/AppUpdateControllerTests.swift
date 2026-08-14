import Foundation
import Testing
@testable import Cadenza

@MainActor
@Suite("App Update Controller", .serialized)
struct AppUpdateControllerTests {
    private let now = Date(timeIntervalSince1970: 1_786_406_400)

    @Test func versionComparisonSupportsCommonReleaseFormats() {
        #expect(AppUpdateController.isVersion("v1.3.0", newerThan: "1.2.9"))
        #expect(AppUpdateController.isVersion("1.3", newerThan: "1.2.9"))
        #expect(AppUpdateController.isVersion("1.2.4", newerThan: "1.2.3"))
        #expect(!AppUpdateController.isVersion("1.2", newerThan: "1.2.0"))
        #expect(!AppUpdateController.isVersion("1.2.2", newerThan: "1.2.3"))
    }

    @Test func prereleaseSortsBelowReleaseAndBuildMetadataIsIgnored() {
        #expect(!AppUpdateController.isVersion("1.2.3-beta.2", newerThan: "1.2.3"))
        #expect(AppUpdateController.isVersion("1.2.3", newerThan: "1.2.3-rc.1"))
        #expect(AppUpdateController.isVersion("1.2.3-beta.11", newerThan: "1.2.3-beta.2"))
        #expect(!AppUpdateController.isVersion("1.2.3+99", newerThan: "1.2.3+1"))
    }

    @Test func githubCheckerBuildsRequestAndDecodesSuccessfulPayload() async throws {
        var receivedRequest: URLRequest?
        let data = githubPayload(tag: "v1.4.0", pageURL: "https://github.com/releases/v1.4.0")
        let response = try httpResponse(statusCode: 200)
        let checker = AppUpdateController.githubReleaseChecker { request in
            receivedRequest = request
            return (data, response)
        }

        let release = try await checker(AppUpdateController.latestReleaseAPIURL)

        #expect(release.version == "v1.4.0")
        #expect(release.name == "Cadenza v1.4.0")
        #expect(release.pageURL.absoluteString == "https://github.com/releases/v1.4.0")
        #expect(receivedRequest?.url == AppUpdateController.latestReleaseAPIURL)
        #expect(receivedRequest?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(receivedRequest?.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(receivedRequest?.value(forHTTPHeaderField: "User-Agent") == "Cadenza")
    }

    @Test func githubDecoderRejectsNonSuccessHTTPStatus() throws {
        let response = try httpResponse(statusCode: 503)
        let data = githubPayload(tag: "v1.4.0", pageURL: "https://github.com/releases/v1.4.0")

        #expect(throws: (any Error).self) {
            try AppUpdateController.decodeLatestRelease(data: data, response: response)
        }
    }

    @Test func githubDecoderRejectsMalformedJSON() throws {
        let response = try httpResponse(statusCode: 200)

        #expect(throws: (any Error).self) {
            try AppUpdateController.decodeLatestRelease(
                data: Data("{".utf8),
                response: response
            )
        }
    }

    @Test func githubDecoderRejectsEmptyTag() throws {
        let response = try httpResponse(statusCode: 200)
        let data = githubPayload(tag: "   ", pageURL: "https://github.com/releases/empty")

        #expect(throws: (any Error).self) {
            try AppUpdateController.decodeLatestRelease(data: data, response: response)
        }
    }

    @Test func githubDecoderRejectsNonHTTPSReleaseURL() throws {
        let response = try httpResponse(statusCode: 200)
        let data = githubPayload(tag: "v1.4.0", pageURL: "http://github.com/releases/v1.4.0")

        #expect(throws: (any Error).self) {
            try AppUpdateController.decodeLatestRelease(data: data, response: response)
        }
    }

    @Test func automaticCheckIsThrottledForTwentyFourHours() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(
            now.addingTimeInterval(-AppUpdateController.automaticCheckInterval + 1),
            forKey: AppUpdateController.lastCheckDateKey
        )
        let checker = CheckerSpy(result: .success(release(version: "2.0.0")))
        let controller = makeController(defaults: fixture.defaults, checker: checker)

        await controller.checkAutomaticallyIfNeeded()

        #expect(checker.callCount == 0)
        #expect(controller.state == .idle)
    }

    @Test func automaticCheckRunsAtThrottleBoundary() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(
            now.addingTimeInterval(-AppUpdateController.automaticCheckInterval),
            forKey: AppUpdateController.lastCheckDateKey
        )
        let checker = CheckerSpy(result: .success(release(version: "2.0.0")))
        let controller = makeController(defaults: fixture.defaults, checker: checker)

        await controller.checkAutomaticallyIfNeeded()

        #expect(checker.callCount == 1)
        #expect(controller.state == .updateAvailable)
    }

    @Test func automaticMonitorChecksImmediatelyAndStopsWhenCancelled() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let checker = CheckerGate(release: release(version: "2.0.0"))
        let controller = AppUpdateController(
            checker: checker.check,
            defaults: fixture.defaults,
            currentVersion: "1.2.3",
            now: { now }
        )

        let monitor = Task { @MainActor in
            await controller.monitorAutomaticChecks()
        }
        await checker.waitUntilStarted()
        #expect(checker.callCount == 1)

        checker.resume()
        monitor.cancel()
        await monitor.value

        #expect(controller.state == .updateAvailable)
    }

    @Test func disabledAutomaticModeNeverCallsChecker() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: AppUpdateController.automaticChecksEnabledKey)
        let checker = CheckerSpy(result: .success(release(version: "2.0.0")))
        let controller = makeController(defaults: fixture.defaults, checker: checker)

        await controller.checkAutomaticallyIfNeeded()

        #expect(!controller.automaticallyChecksForUpdates)
        #expect(checker.callCount == 0)
        #expect(controller.state == .idle)
    }

    @Test func automaticPreferenceDefaultsToEnabled() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let checker = CheckerSpy(result: .success(release(version: "1.2.3")))

        let controller = makeController(defaults: fixture.defaults, checker: checker)

        #expect(controller.automaticallyChecksForUpdates)
        #expect(checker.callCount == 0)
    }

    @Test func manualCheckBypassesDisabledPreferenceAndThrottle() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: AppUpdateController.automaticChecksEnabledKey)
        fixture.defaults.set(now, forKey: AppUpdateController.lastCheckDateKey)
        let checker = CheckerSpy(result: .success(release(version: "2.0.0")))
        let controller = makeController(defaults: fixture.defaults, checker: checker)

        await controller.checkManually()

        #expect(checker.callCount == 1)
        #expect(controller.state == .updateAvailable)
    }

    @Test func newerReleasePublishesItsPageAndSuccessfulCheckDate() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let latest = release(version: "v1.3.0")
        let checker = CheckerSpy(result: .success(latest))
        let controller = makeController(defaults: fixture.defaults, checker: checker)

        await controller.checkManually()

        #expect(controller.state == .updateAvailable)
        #expect(controller.availableRelease == latest)
        #expect(controller.availableReleaseURL == latest.pageURL)
        #expect(fixture.defaults.object(forKey: AppUpdateController.lastCheckDateKey) as? Date == now)
        #expect(checker.requestedURLs == [AppUpdateController.latestReleaseAPIURL])
    }

    @Test func currentOrOlderReleaseIsUpToDateAndHasNoAvailableURL() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let checker = CheckerSpy(result: .success(release(version: "1.2.3+45")))
        let controller = makeController(defaults: fixture.defaults, checker: checker)

        await controller.checkManually()

        #expect(controller.state == .upToDate)
        #expect(controller.availableRelease == nil)
        #expect(controller.availableReleaseURL == nil)
    }

    @Test func failureDoesNotAdvanceLastSuccessfulCheck() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let previousCheck = now.addingTimeInterval(-100_000)
        fixture.defaults.set(previousCheck, forKey: AppUpdateController.lastCheckDateKey)
        let checker = CheckerSpy(result: .failure(TestError.offline))
        let controller = makeController(defaults: fixture.defaults, checker: checker)

        await controller.checkManually()

        guard case .failed(let message) = controller.state else {
            Issue.record("Expected a failed update state")
            return
        }
        #expect(!message.isEmpty)
        #expect(
            fixture.defaults.object(forKey: AppUpdateController.lastCheckDateKey) as? Date
                == previousCheck
        )
        #expect(controller.availableReleaseURL == nil)
    }

    @Test func invalidReleaseVersionFailsWithoutAdvancingLastCheck() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let checker = CheckerSpy(result: .success(release(version: "latest")))
        let controller = makeController(defaults: fixture.defaults, checker: checker)

        await controller.checkManually()

        guard case .failed = controller.state else {
            Issue.record("Expected an invalid release version to fail")
            return
        }
        #expect(fixture.defaults.object(forKey: AppUpdateController.lastCheckDateKey) == nil)
    }

    @Test func invalidInstalledVersionFailsWithoutAdvancingLastCheck() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let checker = CheckerSpy(result: .success(release(version: "1.2.3")))
        let controller = makeController(
            defaults: fixture.defaults,
            checker: checker,
            currentVersion: "development"
        )

        await controller.checkManually()

        guard case .failed = controller.state else {
            Issue.record("Expected an invalid installed version to fail")
            return
        }
        #expect(fixture.defaults.object(forKey: AppUpdateController.lastCheckDateKey) == nil)
    }

    @Test func concurrentChecksShareOneInFlightRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let checker = CheckerGate(release: release(version: "2.0.0"))
        let controller = AppUpdateController(
            checker: checker.check,
            defaults: fixture.defaults,
            currentVersion: "1.2.3",
            now: { now }
        )
        let completion = CheckCompletionProbe()
        let secondStarted = MainActorSignal()

        let first = Task { @MainActor in
            await controller.checkManually()
            completion.firstReturned = true
        }
        await checker.waitUntilStarted()

        let second = Task { @MainActor in
            secondStarted.signal()
            await controller.checkManually()
            completion.secondReturned = true
        }
        await secondStarted.wait()

        #expect(checker.callCount == 1)
        #expect(controller.state == .checking)
        #expect(!completion.firstReturned)
        #expect(!completion.secondReturned)

        checker.resume()
        await first.value
        await second.value

        #expect(checker.callCount == 1)
        #expect(completion.firstReturned)
        #expect(completion.secondReturned)
        #expect(controller.state == .updateAvailable)
    }

    @Test func enablingAutomaticChecksPersistsAndStartsAThrottledCheck() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(false, forKey: AppUpdateController.automaticChecksEnabledKey)
        let checker = CheckerSpy(result: .success(release(version: "1.2.3")))
        let controller = makeController(defaults: fixture.defaults, checker: checker)

        let checkTask = controller.setAutomaticallyChecksForUpdates(true)
        await checkTask?.value

        #expect(controller.automaticallyChecksForUpdates)
        #expect(fixture.defaults.bool(forKey: AppUpdateController.automaticChecksEnabledKey))
        #expect(checker.callCount == 1)
        #expect(controller.state == .upToDate)
    }

    @Test func confirmingDefaultEnabledPreferenceStartsAThrottledCheck() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let checker = CheckerSpy(result: .success(release(version: "1.2.3")))
        let controller = makeController(defaults: fixture.defaults, checker: checker)

        let checkTask = controller.setAutomaticallyChecksForUpdates(true)
        await checkTask?.value

        #expect(checker.callCount == 1)
        #expect(controller.state == .upToDate)
    }

    private func makeController(
        defaults: UserDefaults,
        checker: CheckerSpy,
        currentVersion: String = "1.2.3"
    ) -> AppUpdateController {
        AppUpdateController(
            checker: checker.check,
            defaults: defaults,
            currentVersion: currentVersion,
            now: { now }
        )
    }

    private func release(version: String) -> AppUpdateController.Release {
        AppUpdateController.Release(
            version: version,
            name: "Cadenza \(version)",
            pageURL: URL(string: "https://github.com/shuiandy/Cadenza/releases/tag/\(version)")!
        )
    }

    private func githubPayload(tag: String, pageURL: String) -> Data {
        Data(
            """
            {
              "tag_name": "\(tag)",
              "name": "Cadenza \(tag)",
              "html_url": "\(pageURL)"
            }
            """.utf8
        )
    }

    private func httpResponse(statusCode: Int) throws -> HTTPURLResponse {
        try #require(
            HTTPURLResponse(
                url: AppUpdateController.latestReleaseAPIURL,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )
        )
    }

    private func makeFixture() throws -> DefaultsFixture {
        let suiteName = "AppUpdateControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return DefaultsFixture(defaults: defaults, suiteName: suiteName)
    }
}

@MainActor
private final class CheckerGate {
    private let result: AppUpdateController.Release
    private let started = MainActorSignal()
    private var continuation: CheckedContinuation<AppUpdateController.Release, Never>?

    private(set) var callCount = 0

    init(release: AppUpdateController.Release) {
        result = release
    }

    func check(_ url: URL) async -> AppUpdateController.Release {
        callCount += 1
        started.signal()
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func resume() {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class MainActorSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
private final class CheckCompletionProbe {
    var firstReturned = false
    var secondReturned = false
}

@MainActor
private final class CheckerSpy {
    private let delay: Duration
    private let result: Result<AppUpdateController.Release, Error>

    private(set) var callCount = 0
    private(set) var requestedURLs: [URL] = []

    init(
        delay: Duration = .zero,
        result: Result<AppUpdateController.Release, Error>
    ) {
        self.delay = delay
        self.result = result
    }

    func check(_ url: URL) async throws -> AppUpdateController.Release {
        callCount += 1
        requestedURLs.append(url)
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try result.get()
    }
}

private struct DefaultsFixture {
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private enum TestError: LocalizedError {
    case offline

    var errorDescription: String? { "Offline" }
}
