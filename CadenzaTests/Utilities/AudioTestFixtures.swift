import Foundation
import CoreMedia
import AudioToolbox
import AVFoundation
@testable import Cadenza

/// Deterministic audio fixtures for AVFoundation-heavy tests.
/// Suites using these helpers must be `.serialized` — concurrent
/// AVAssetWriter/Reader access crashes in sandboxed test environments
/// (see the note in AudioFileWriterTests).
enum AudioTestFixtures {

    // MARK: - Waveforms

    /// `count` samples of a 440Hz sine at linear `amplitude` (0…1).
    static func sine(count: Int, amplitude: Float, sampleRate: Double = 16000) -> [Float] {
        (0..<count).map { i in
            amplitude * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
    }

    static func silence(count: Int) -> [Float] {
        [Float](repeating: 0, count: count)
    }

    // MARK: - ASBDs

    static func float32ASBD(sampleRate: Double = 48000, channels: UInt32 = 1) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
    }

    static func int16ASBD(sampleRate: Double = 48000, channels: UInt32 = 1) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0)
    }

    /// Unsupported-format case for fail-open tests (Int32 PCM).
    static func int32ASBD(sampleRate: Double = 48000, channels: UInt32 = 1) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
    }

    // MARK: - CMSampleBuffer builder

    enum FixtureError: Error { case osStatus(String, OSStatus) }

    static func makeSampleBuffer(
        asbd: AudioStreamBasicDescription,
        data: Data,
        sampleCount: Int
    ) throws -> CMSampleBuffer {
        var mutableASBD = asbd
        var formatDesc: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &mutableASBD,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDesc)
        guard status == noErr, let format = formatDesc else {
            throw FixtureError.osStatus("CMAudioFormatDescriptionCreate", status)
        }

        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
            throw FixtureError.osStatus("CMBlockBufferCreateWithMemoryBlock", status)
        }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == kCMBlockBufferNoErr else {
            throw FixtureError.osStatus("CMBlockBufferReplaceDataBytes", status)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let result = sampleBuffer else {
            throw FixtureError.osStatus("CMSampleBufferCreate", status)
        }
        return result
    }

    static func makeFloat32Buffer(samples: [Float], sampleRate: Double = 48000) throws -> CMSampleBuffer {
        var data = Data(count: samples.count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { raw in
            raw.bindMemory(to: Float.self).baseAddress!.update(from: samples, count: samples.count)
        }
        return try makeSampleBuffer(asbd: float32ASBD(sampleRate: sampleRate), data: data, sampleCount: samples.count)
    }

    static func makeInt16Buffer(samples: [Int16], sampleRate: Double = 48000) throws -> CMSampleBuffer {
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            raw.bindMemory(to: Int16.self).baseAddress!.update(from: samples, count: samples.count)
        }
        return try makeSampleBuffer(asbd: int16ASBD(sampleRate: sampleRate), data: data, sampleCount: samples.count)
    }

    // MARK: - .m4a fixture writer

    /// Writes an AAC .m4a with one audio track per element of `tracks` —
    /// mirrors real segments (system audio + optional mic = two tracks).
    /// Uses AAC codec (32 kbps @ 16kHz mono) for production-realistic compression.
    /// Note: 64 kbps @ 16kHz mono exceeds AAC-LC valid bitrate combinations (error -11861),
    /// so we use 32 kbps which is a legal combination for this sample rate.
    static func writeM4A(tracks: [[Float]], sampleRate: Double = 16000, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let inputs: [AVAssetWriterInput] = tracks.map { _ in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            return input
        }
        for input in inputs { writer.add(input) }
        guard writer.startWriting() else {
            throw writer.error ?? FixtureError.osStatus("startWriting", -1)
        }
        writer.startSession(atSourceTime: .zero)

        let chunk = Int(sampleRate) // 1s chunks
        for (trackIndex, floatSamples) in tracks.enumerated() {
            let input = inputs[trackIndex]
            var offset = 0
            while offset < floatSamples.count {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let end = min(offset + chunk, floatSamples.count)
                let slice = Array(floatSamples[offset..<end])
                // Convert Float samples to Int16 for AAC encoding
                let int16Samples = slice.map { f in
                    Int16(max(-32768, min(32767, Int32(f * 32767))))
                }
                let base = try makeInt16Buffer(samples: int16Samples, sampleRate: sampleRate)
                let timed = try AudioSegmentMerger.retimestamp(
                    sampleBuffer: base,
                    offset: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)))
                guard input.append(timed) else {
                    throw writer.error ?? FixtureError.osStatus("append", -2)
                }
                offset = end
            }
            input.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? FixtureError.osStatus("finishWriting", -3)
        }
    }
}
