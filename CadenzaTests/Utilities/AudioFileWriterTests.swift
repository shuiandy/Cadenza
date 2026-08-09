import Testing
import Foundation
@testable import Cadenza

@Suite("AudioFileWriter", .serialized)
struct AudioFileWriterTests {

    // MARK: - Initial State

    @Test func initialStateNotWriting() {
        let writer = AudioFileWriter()
        #expect(writer.isWriting == false)
        #expect(writer.outputURL == nil)
    }

    // MARK: - Error Types

    @Test func audioFileWriterErrorCannotAddInput() {
        let error = AudioFileWriterError.cannotAddInput
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("Cannot add"))
    }

    @Test func audioFileWriterErrorStartWritingFailed() {
        let error = AudioFileWriterError.startWritingFailed("test reason")
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("test reason"))
    }

    @Test func audioFileWriterErrorLocalizedDescription() {
        let error1 = AudioFileWriterError.cannotAddInput
        let error2 = AudioFileWriterError.startWritingFailed("unknown")
        // Both should provide meaningful descriptions
        #expect(!error1.localizedDescription.isEmpty)
        #expect(!error2.localizedDescription.isEmpty)
    }

    @Test func audioFileWriterErrorIsError() {
        let error: Error = AudioFileWriterError.cannotAddInput
        #expect(error is AudioFileWriterError)
    }

    // MARK: - Stop Without Start

    @Test func stopWritingWithoutStartReturnsNil() async {
        let writer = AudioFileWriter()
        let url = await writer.stopWriting()
        #expect(url == nil)
    }

    // MARK: - Force Reset Without Start

    @Test func forceResetWithoutStartIsNoOp() {
        let writer = AudioFileWriter()
        #expect(writer.isWriting == false)
        #expect(writer.outputURL == nil)
        writer.forceReset()
        Thread.sleep(forTimeInterval: 0.05)
        // State should still be false/nil — forceReset on a non-writing writer is safe
        #expect(writer.isWriting == false)
        #expect(writer.outputURL == nil)
    }

    // MARK: - Start Writing

    // Note: Tests that call startWriting() create an AVAssetWriter which
    // uses CoreMedia/AVFoundation and can crash in certain test environments
    // (headless CI, sandboxed runner). These tests are serialized to avoid
    // concurrent AVAssetWriter access which causes System trap crashes.

    @Test func startWritingSetsState() throws {
        let writer = AudioFileWriter()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try writer.startWriting(to: url)
        #expect(writer.isWriting == true)
        #expect(writer.outputURL == url)
        // Cleanup
        writer.forceReset()
        Thread.sleep(forTimeInterval: 0.05)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func startWritingIdempotent() throws {
        let writer = AudioFileWriter()
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try writer.startWriting(to: url1)
        #expect(writer.outputURL == url1)
        // Second call should be no-op — outputURL must NOT change
        try writer.startWriting(to: url2)
        #expect(writer.isWriting == true)
        #expect(writer.outputURL == url1) // Still points to first URL
        #expect(!FileManager.default.fileExists(atPath: url2.path)) // Second file not created
        writer.forceReset()
        Thread.sleep(forTimeInterval: 0.05)
        try? FileManager.default.removeItem(at: url1)
    }

    @Test func startWritingCreatesFile() throws {
        let writer = AudioFileWriter()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try writer.startWriting(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        writer.forceReset()
        Thread.sleep(forTimeInterval: 0.05)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func forceResetClearsState() throws {
        let writer = AudioFileWriter()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try writer.startWriting(to: url)
        #expect(writer.isWriting == true)

        writer.forceReset()
        Thread.sleep(forTimeInterval: 0.1)

        #expect(writer.isWriting == false)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func startThenStopReturnsURL() async throws {
        let writer = AudioFileWriter()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try writer.startWriting(to: url)
        #expect(writer.isWriting == true)

        let resultURL = await writer.stopWriting()
        #expect(resultURL != nil)
        #expect(resultURL == url)
        #expect(writer.isWriting == false)

        try? FileManager.default.removeItem(at: url)
    }
}
