import Testing
import Foundation
@testable import Cadenza

@Suite("AudioSilenceDetector", .serialized)
struct AudioSilenceDetectorTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
    }

    @Test func silentFileHasNoAudibleContent() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.silence(count: 16000 * 5)], to: url)
        #expect(await AudioSilenceDetector.hasAudibleContent(at: url) == false)
        // Existing whole-file API agrees on true silence — behavior unchanged.
        #expect(await AudioSilenceDetector.isSilent(at: url) == true)
    }

    @Test func toneIsAudible() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await AudioTestFixtures.writeM4A(
            tracks: [AudioTestFixtures.sine(count: 16000 * 3, amplitude: 0.1)], to: url)
        #expect(await AudioSilenceDetector.hasAudibleContent(at: url) == true)
    }

    @Test func shortQuietSpeechInLongSilenceIsAudible() async throws {
        // 29s silence + 1s tone at -30dB. Whole-file average RMS ≈ 0.004
        // (below the 0.006 threshold — the averaging approach dilutes it away),
        // but any 500ms window inside the tone is ≈ 0.022. This is THE
        // regression test for the trim-safety blocker from Codex review.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var samples = AudioTestFixtures.silence(count: 16000 * 29)
        samples += AudioTestFixtures.sine(count: 16000, amplitude: 0.0316)
        try await AudioTestFixtures.writeM4A(tracks: [samples], to: url)
        #expect(await AudioSilenceDetector.hasAudibleContent(at: url) == true)
    }

    @Test func micOnlyTrackIsAudible() async throws {
        // Track 0 (system) silent, track 1 (mic) speaking — the mic track
        // MUST count, else "system quiet but user talking" gets trimmed.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await AudioTestFixtures.writeM4A(
            tracks: [
                AudioTestFixtures.silence(count: 16000 * 3),
                AudioTestFixtures.sine(count: 16000 * 3, amplitude: 0.1),
            ], to: url)
        #expect(await AudioSilenceDetector.hasAudibleContent(at: url) == true)
    }

    @Test func missingFileFailsOpen() async {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m4a")
        #expect(await AudioSilenceDetector.hasAudibleContent(at: url) == true)
    }

    @Test func corruptFileFailsOpen() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        #expect(await AudioSilenceDetector.hasAudibleContent(at: url) == true)
    }
}
