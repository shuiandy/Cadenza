import Testing
import CoreMedia
@testable import Cadenza

@Suite("AudioLevelMeter", .serialized)
struct AudioLevelMeterTests {

    @Test func float32ToneProducesLevel() throws {
        let buffer = try AudioTestFixtures.makeFloat32Buffer(
            samples: AudioTestFixtures.sine(count: 1024, amplitude: 0.5, sampleRate: 48000))
        let level = try #require(AudioLevelMeter.normalizedLevel(from: buffer))
        // RMS of 0.5-amplitude sine ≈ 0.35 → normalized min(0.35*5, 1) = 1.0
        #expect(level > 0.9)
    }

    @Test func float32SilenceIsZero() throws {
        let buffer = try AudioTestFixtures.makeFloat32Buffer(
            samples: AudioTestFixtures.silence(count: 1024))
        let level = try #require(AudioLevelMeter.normalizedLevel(from: buffer))
        #expect(level == 0)
    }

    @Test func int16ToneProducesLevel() throws {
        let samples = AudioTestFixtures.sine(count: 1024, amplitude: 0.5, sampleRate: 48000)
            .map { Int16(max(-32768, min(32767, $0 * 32767))) }
        let buffer = try AudioTestFixtures.makeInt16Buffer(samples: samples)
        let level = try #require(AudioLevelMeter.normalizedLevel(from: buffer))
        #expect(level > 0.9)
    }

    @Test func int16SilenceIsZero() throws {
        let buffer = try AudioTestFixtures.makeInt16Buffer(
            samples: [Int16](repeating: 0, count: 1024))
        let level = try #require(AudioLevelMeter.normalizedLevel(from: buffer))
        #expect(level == 0)
    }

    @Test func unsupportedFormatReturnsNil() throws {
        // Int32 PCM — not supported → nil (caller fail-opens to "audible").
        let buffer = try AudioTestFixtures.makeSampleBuffer(
            asbd: AudioTestFixtures.int32ASBD(),
            data: Data(count: 1024 * 4),
            sampleCount: 1024)
        #expect(AudioLevelMeter.normalizedLevel(from: buffer) == nil)
    }
}
