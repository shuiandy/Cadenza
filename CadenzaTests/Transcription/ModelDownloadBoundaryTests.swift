import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Cadenza

@Suite("Local model download boundaries", .serialized)
@MainActor
struct ModelDownloadBoundaryTests {
    @Test func isolatedFixtureNeverInvokesWhisperDownloader() async {
        let spy = WhisperDownloadSpy()
        let manager = makeWhisperManager(
            processAccessAllowed: true,
            spy: spy
        )
        let policy = AppState.StartupPolicy.isolatedFixture

        manager.download(
            model: "tiny",
            externalAccessEnabled: policy.externalAccessEnabled
        )
        await Task.yield()

        #expect(await spy.invocationCount == 0)
        #expect(!manager.isDownloadInProgress)
        #expect(manager.downloadProgress.isEmpty)
    }

    @Test func closedProcessBoundaryNeverInvokesWhisperDownloader() async {
        let spy = WhisperDownloadSpy()
        let manager = makeWhisperManager(
            processAccessAllowed: false,
            spy: spy
        )

        manager.download(model: "tiny", externalAccessEnabled: true)
        await Task.yield()

        #expect(await spy.invocationCount == 0)
        #expect(!manager.isDownloadInProgress)
    }

    @Test func differentWhisperModelsCannotDownloadConcurrently() async {
        let spy = WhisperDownloadSpy()
        let manager = makeWhisperManager(
            processAccessAllowed: true,
            spy: spy
        )

        manager.download(model: "tiny", externalAccessEnabled: true)
        #expect(await waitUntil { await spy.invocationCount == 1 })

        manager.download(model: "small", externalAccessEnabled: true)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(await spy.requestedModels == ["tiny"])
        #expect(manager.isDownloading("tiny"))
        #expect(!manager.isDownloading("small"))
        #expect(manager.downloadProgress["small"] == nil)

        manager.cancelDownload()
        #expect(await waitUntil { !manager.isDownloadInProgress })
        #expect(manager.downloadProgress["tiny"] == nil)
    }

    @Test func immediateCancellationNeverCrossesWhisperDownloaderBoundary() async {
        let spy = WhisperDownloadSpy()
        let manager = makeWhisperManager(
            processAccessAllowed: true,
            spy: spy
        )

        manager.download(model: "tiny", externalAccessEnabled: true)
        manager.cancelDownload()

        #expect(await waitUntil { !manager.isDownloadInProgress })
        #expect(await spy.invocationCount == 0)
        #expect(manager.downloadProgress["tiny"] == nil)
    }

    @Test func isolatedFixtureNeverInvokesSpeakerModelProvider() async {
        let provider = SpeakerModelProviderSpy()
        let diarizer = SpeakerDiarizer(
            modelProvider: provider,
            externalModelAccessAllowed: { true },
            automaticallyProbe: false
        )
        let policy = AppState.StartupPolicy.isolatedFixture

        await diarizer.probeModelAvailability(
            externalAccessEnabled: policy.externalAccessEnabled
        )
        do {
            try await diarizer.prepare(
                externalAccessEnabled: policy.externalAccessEnabled
            )
            Issue.record("Isolated fixture unexpectedly prepared SpeakerKit models")
        } catch is CancellationError {
            // Expected: rejected before the provider boundary.
        } catch {
            Issue.record("Unexpected isolated fixture error: \(error)")
        }

        #expect(provider.probeInvocationCount == 0)
        #expect(provider.prepareInvocationCount == 0)
        #expect(!diarizer.isReady)
        #expect(diarizer.downloadProgress == 0)
    }

    @Test func closedProcessBoundaryNeverInvokesSpeakerModelProvider() async {
        let provider = SpeakerModelProviderSpy()
        let diarizer = SpeakerDiarizer(
            modelProvider: provider,
            externalModelAccessAllowed: { false },
            automaticallyProbe: false
        )

        await diarizer.probeModelAvailability(externalAccessEnabled: true)
        do {
            try await diarizer.prepare(externalAccessEnabled: true)
            Issue.record("Closed process boundary unexpectedly prepared SpeakerKit models")
        } catch is CancellationError {
            // Expected: rejected before the provider boundary.
        } catch {
            Issue.record("Unexpected closed-boundary error: \(error)")
        }

        #expect(provider.probeInvocationCount == 0)
        #expect(provider.prepareInvocationCount == 0)
    }

    @Test func whisperSelectionIsAScaledButtonAtMaximumScale() throws {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        #expect(scale == 3.105)

        let model = WhisperModel(
            name: "medium",
            displayName: "Modèle multilingue moyen",
            sizeDescription: "~800 MB",
            description: "Précision maximale dans de nombreuses langues.",
            isDefault: false
        )
        let scaledName = NSHostingView(
            rootView: Text(model.displayName)
                .font(.cadenza(.body, weight: .semibold, scale: scale))
        )
        scaledName.sizingOptions = [.intrinsicContentSize]
        scaledName.layoutSubtreeIfNeeded()

        let row = NSHostingView(
            rootView: WhisperModelRowLayout(stacked: true) {
                WhisperModelSelectionButton(model: model, isSelected: true) {}
                    .environment(\.uiScale, scale)
            } actions: {
                Text("Downloaded")
                    .font(.cadenza(.caption, scale: scale))
            }
            .frame(width: 530)
        )
        row.sizingOptions = [.intrinsicContentSize]
        row.layoutSubtreeIfNeeded()
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        row.layoutSubtreeIfNeeded()

        #expect(row.fittingSize.width == 530)
        #expect(row.fittingSize.height >= scaledName.fittingSize.height)
        #expect(row.fittingSize.height >= 44)

        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Cadenza/Views/Settings/WhisperModelPicker.swift"),
            encoding: .utf8
        )
        #expect(source.contains("Button(action: action)"))
        #expect(source.contains(".accessibilityLabel(Text(verbatim: accessibilityPresentation.label))"))
        #expect(source.contains(".accessibilityValue(Text(verbatim: accessibilityPresentation.value))"))
        #expect(source.contains(".accessibilityHint(Text(verbatim: accessibilityPresentation.hint))"))
        #expect(!source.contains(".onTapGesture"))
    }

    @Test func whisperSelectionVoiceOverSemanticsPreserveEveryVisibleDetail() {
        let defaultModel = WhisperModel(
            name: "base",
            displayName: "Localized model name",
            sizeDescription: "~80 MB",
            description: "Localized model description",
            isDefault: true
        )
        let selected = WhisperModelAccessibilityPresentation.make(
            model: defaultModel,
            isSelected: true
        )

        #expect(selected.label.contains(defaultModel.displayName))
        #expect(selected.label.contains(defaultModel.sizeDescription))
        #expect(selected.label.contains(defaultModel.description))
        #expect(selected.label.contains(String(localized: "Recommended")))
        #expect(selected.value == String(localized: "Selected"))
        #expect(selected.hint == String(localized: "Select"))

        let optionalModel = WhisperModel(
            name: "small",
            displayName: "Another model",
            sizeDescription: "~250 MB",
            description: "Another localized description",
            isDefault: false
        )
        let downloaded = WhisperModelAccessibilityPresentation.make(
            model: optionalModel,
            isSelected: false
        )

        #expect(!downloaded.label.contains(String(localized: "Recommended")))
        #expect(downloaded.value == String(localized: "Downloaded"))
        #expect(downloaded.hint == String(localized: "Select"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeWhisperManager(
        processAccessAllowed: Bool,
        spy: WhisperDownloadSpy
    ) -> WhisperModelManager {
        let defaults = UserDefaults(
            suiteName: "WhisperModelManagerTests.\(UUID().uuidString)"
        )!
        return WhisperModelManager(
            defaults: defaults,
            externalModelAccessAllowed: { processAccessAllowed },
            downloadOperation: { name, progressCallback in
                try await spy.download(
                    model: name,
                    progressCallback: progressCallback
                )
            }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private actor WhisperDownloadSpy {
    private(set) var requestedModels: [String] = []

    var invocationCount: Int { requestedModels.count }

    func download(
        model: String,
        progressCallback: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        requestedModels.append(model)
        _ = progressCallback
        try await Task.sleep(for: .seconds(30))
        return URL(fileURLWithPath: "/private/tmp/unused-\(model)")
    }
}

@MainActor
private final class SpeakerModelProviderSpy: SpeakerModelProviding {
    private(set) var probeInvocationCount = 0
    private(set) var prepareInvocationCount = 0

    func probeAvailability() async throws -> Bool {
        probeInvocationCount += 1
        return false
    }

    func prepareModels(
        progressCallback: @escaping @Sendable (Progress) -> Void
    ) async throws -> PreparedSpeakerModels {
        prepareInvocationCount += 1
        _ = progressCallback
        throw SpeakerModelProviderSpyError.unexpectedInvocation
    }
}

private enum SpeakerModelProviderSpyError: Error {
    case unexpectedInvocation
}
