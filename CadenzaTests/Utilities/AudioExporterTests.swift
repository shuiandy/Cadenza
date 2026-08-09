import AVFoundation
import Foundation
import os
import Testing

@testable import Cadenza

@MainActor
@Suite("Audio exporter", .serialized)
struct AudioExporterTests {
    @Test func exporterUsesRealSynchronizationInsteadOfConcurrencySuppressions() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent("Cadenza/Utilities/AudioExporter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains("@preconcurrency"))
        #expect(!source.contains("nonisolated(unsafe)"))
        #expect(source.contains("Mutex<"))
        #expect(source.contains("[weak self]"))
    }

    @Test func alreadyCancelledExportStopsBeforeCreatingOutput() async throws {
        let urls = makeURLs()
        defer { remove(urls.input); remove(urls.output) }

        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.sine(count: 16_000, amplitude: 0.25)],
            to: urls.input
        )
        let asset = AVURLAsset(url: urls.input)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let gate = AudioExporterCancellationGate()

        let task = Task {
            await gate.wait()
            try await AudioExporter.exportToM4A(
                asset: asset,
                track: track,
                outputURL: urls.output,
                settings: .compressed
            )
        }

        #expect(await gate.waitUntilBlocked())
        task.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!FileManager.default.fileExists(atPath: urls.output.path))
    }

    @Test func roundTripExportPreservesCompleteAudioDuration() async throws {
        let urls = makeURLs()
        defer { remove(urls.input); remove(urls.output) }

        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.sine(count: 32_000, amplitude: 0.25)],
            to: urls.input
        )
        let asset = AVURLAsset(url: urls.input)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)

        try await AudioExporter.exportToM4A(
            asset: asset,
            track: track,
            outputURL: urls.output,
            settings: .compressed
        )

        let exported = AVURLAsset(url: urls.output)
        let duration = try await exported.load(.duration).seconds
        #expect(FileManager.default.fileExists(atPath: urls.output.path))
        #expect(duration > 1.9)
        #expect(duration < 2.1)
    }

    @Test func midFlightCancellationCancelsAVObjectsOnceAndRemovesPartialOutput() async throws {
        let urls = makeURLs()
        defer { remove(urls.input); remove(urls.output) }

        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.sine(count: 32_000, amplitude: 0.25)],
            to: urls.input
        )
        let asset = AVURLAsset(url: urls.input)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let probe = AudioExporterCancellationProbe()

        let task = Task {
            try await AudioExporter.exportToM4A(
                asset: asset,
                track: track,
                outputURL: urls.output,
                settings: .compressed,
                testHooks: .init(
                    beforeFirstDrain: { probe.blockFirstDrain() },
                    onPumpTerminal: { probe.recordPumpTerminal() },
                    onCancel: { probe.recordCancellation($0) },
                    onDeinit: { probe.recordDeinit() }
                )
            )
        }

        #expect(await probe.waitUntilFirstDrainBlocked())
        #expect(FileManager.default.fileExists(atPath: urls.output.path))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(probe.cancellationSnapshots.count == 1)
        #expect(probe.cancellationSnapshots.first?.readerStatus == AVAssetReader.Status.cancelled.rawValue)
        #expect(probe.cancellationSnapshots.first?.writerStatus == AVAssetWriter.Status.cancelled.rawValue)
        #expect(!FileManager.default.fileExists(atPath: urls.output.path))

        probe.releaseFirstDrain()
        #expect(await probe.waitUntilDeinitialized())
        #expect(probe.pumpTerminalCount == 0)
    }

    @Test func existingDestinationSurvivesWriterOwnershipFailure() async throws {
        let urls = makeURLs()
        defer { remove(urls.input); remove(urls.output) }

        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.sine(count: 16_000, amplitude: 0.25)],
            to: urls.input
        )
        let sentinel = Data("pre-existing-user-file".utf8)
        try sentinel.write(to: urls.output)
        let asset = AVURLAsset(url: urls.input)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)

        await #expect(throws: (any Error).self) {
            try await AudioExporter.exportToM4A(
                asset: asset,
                track: track,
                outputURL: urls.output,
                settings: .compressed
            )
        }

        #expect(try Data(contentsOf: urls.output) == sentinel)
    }

    @Test func setupFailuresAfterWriterCreationRemoveOwnedOutput() async throws {
        for failure in AudioExporter.WriterSetupFailure.allCases {
            let urls = makeURLs()
            defer { remove(urls.input); remove(urls.output) }

            try await AudioTestFixtures.writeM4A(
                tracks: [AudioTestFixtures.sine(count: 16_000, amplitude: 0.25)],
                to: urls.input
            )
            let asset = AVURLAsset(url: urls.input)
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let probe = AudioExporterWriterSetupProbe()

            await #expect(throws: (any Error).self) {
                try await AudioExporter.exportToM4A(
                    asset: asset,
                    track: track,
                    outputURL: urls.output,
                    settings: .compressed,
                    testHooks: .init(
                        writerSetupFailure: failure,
                        onWriterCreated: { probe.recordWriterCreated(at: $0) }
                    )
                )
            }

            #expect(probe.ownedPlaceholderCreated)
            #expect(!FileManager.default.fileExists(atPath: urls.output.path))
        }
    }

    private func makeURLs() -> (input: URL, output: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            directory.appendingPathComponent("input.m4a"),
            directory.appendingPathComponent("output.m4a")
        )
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

private final class AudioExporterWriterSetupProbe: Sendable {
    private let ownedPlaceholderCreatedState = OSAllocatedUnfairLock(initialState: false)

    var ownedPlaceholderCreated: Bool {
        ownedPlaceholderCreatedState.withLock { $0 }
    }

    func recordWriterCreated(at outputURL: URL) {
        let marker = Data("writer-owned-placeholder".utf8)
        let created = (try? marker.write(to: outputURL)) != nil
        ownedPlaceholderCreatedState.withLock {
            $0 = created
        }
    }
}

private actor AudioExporterCancellationGate {
    private var isOpen = false
    private var isBlocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        isBlocked = true
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilBlocked() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while !isBlocked, clock.now < deadline {
            await Task.yield()
        }
        return isBlocked
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class AudioExporterCancellationProbe: Sendable {
    private struct State {
        var firstDrainBlocked = false
        var firstDrainReleased = false
        var cancellationSnapshots: [AudioExporter.CancellationSnapshot] = []
        var pumpTerminalCount = 0
        var deinitCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var cancellationSnapshots: [AudioExporter.CancellationSnapshot] {
        state.withLock { $0.cancellationSnapshots }
    }

    var pumpTerminalCount: Int {
        state.withLock { $0.pumpTerminalCount }
    }

    func blockFirstDrain() {
        state.withLock { $0.firstDrainBlocked = true }
        while !state.withLock({ $0.firstDrainReleased }) {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    func releaseFirstDrain() {
        state.withLock { $0.firstDrainReleased = true }
    }

    func recordCancellation(_ snapshot: AudioExporter.CancellationSnapshot) {
        state.withLock { $0.cancellationSnapshots.append(snapshot) }
    }

    func recordPumpTerminal() {
        state.withLock { $0.pumpTerminalCount += 1 }
    }

    func recordDeinit() {
        state.withLock { $0.deinitCount += 1 }
    }

    func waitUntilFirstDrainBlocked() async -> Bool {
        await waitUntil { $0.firstDrainBlocked }
    }

    func waitUntilDeinitialized() async -> Bool {
        await waitUntil { $0.deinitCount == 1 }
    }

    private func waitUntil(
        _ condition: @escaping @Sendable (State) -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while clock.now < deadline {
            if state.withLock({ condition($0) }) { return true }
            await Task.yield()
        }
        return state.withLock { condition($0) }
    }
}
