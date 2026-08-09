import Foundation
@preconcurrency import AVFoundation
import CoreMedia

/// Converts audio between formats.
/// Primary use: convert 48kHz PCM capture buffers to 24kHz mono PCM16 for transcription APIs.
struct AudioConverter {

    /// Target format for OpenAI Realtime API: 24kHz, mono, PCM16 (Int16 little-endian)
    static let transcriptionFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
        channels: 1,
        interleaved: true
    )!

    // Single lock serializing the entire convert() call: converter cache, buffer pool,
    // data copy, and format conversion. Eliminates data races on shared cached buffers.
    private static let conversionLock = NSLock()
    private nonisolated(unsafe) static var converterCache: [String: AVAudioConverter] = [:]

    // Buffer pool: reuse AVAudioPCMBuffer instances to avoid per-callback heap allocations.
    // In steady state (stable format + frame count), convert() performs zero buffer allocations.
    // Protected by conversionLock (same lock as converter cache).
    private nonisolated(unsafe) static var cachedInputBuffer: AVAudioPCMBuffer?
    private nonisolated(unsafe) static var cachedOutputBuffer: AVAudioPCMBuffer?

    private static func formatKey(_ format: AVAudioFormat) -> String {
        "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)"
    }

    /// Convert a CMSampleBuffer from the capture pipeline to an AVAudioPCMBuffer in the target format.
    static func convert(sampleBuffer: CMSampleBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        // Serialize entire convert: buffer reuse + data copy + format conversion
        conversionLock.lock()
        defer { conversionLock.unlock() }

        // Reuse or allocate input buffer
        let inputBuffer: AVAudioPCMBuffer
        if let cached = cachedInputBuffer,
           cached.format == inputFormat,
           cached.frameCapacity >= AVAudioFrameCount(frameCount) {
            inputBuffer = cached
        } else if let newBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) {
            cachedInputBuffer = newBuf
            inputBuffer = newBuf
        } else {
            return nil
        }
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy data from CMSampleBuffer to AVAudioPCMBuffer
        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let srcData = dataPointer else {
            return nil
        }

        let bytesToCopy = min(dataLength, Int(inputBuffer.frameCapacity) * Int(inputFormat.streamDescription.pointee.mBytesPerFrame))
        if let int16Ptr = inputBuffer.int16ChannelData?[0] {
            memcpy(int16Ptr, srcData, bytesToCopy)
        } else if let floatPtr = inputBuffer.floatChannelData?[0] {
            memcpy(floatPtr, srcData, bytesToCopy)
        } else {
            return nil
        }

        // If formats match, return directly
        if inputFormat.sampleRate == outputFormat.sampleRate &&
           inputFormat.channelCount == outputFormat.channelCount &&
           inputFormat.commonFormat == outputFormat.commonFormat {
            return inputBuffer
        }

        // Convert (reuse cached AVAudioConverter for the same format pair)
        let cacheKey = "\(formatKey(inputFormat))->\(formatKey(outputFormat))"

        let converter: AVAudioConverter
        if let cached = converterCache[cacheKey] {
            converter = cached
        } else if let created = AVAudioConverter(from: inputFormat, to: outputFormat) {
            converterCache[cacheKey] = created
            converter = created
        } else {
            return nil
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)

        // Reuse or allocate output buffer
        let outputBuffer: AVAudioPCMBuffer
        if let cached = cachedOutputBuffer,
           cached.format == outputFormat,
           cached.frameCapacity >= outputFrameCount {
            outputBuffer = cached
        } else if let newBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) {
            cachedOutputBuffer = newBuf
            outputBuffer = newBuf
        } else {
            return nil
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error {
            NSLog("[AudioConverter] conversion error: %@", error.localizedDescription)
            return nil
        }

        return outputBuffer
    }

    /// Convert AVAudioPCMBuffer to PCM16 Data (for sending to transcription APIs).
    static func pcmBufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let int16Data = buffer.int16ChannelData else {
            // If float format, convert to Int16
            guard let floatData = buffer.floatChannelData else { return nil }
            let frameCount = Int(buffer.frameLength)
            var data = Data(count: frameCount * MemoryLayout<Int16>.size)
            data.withUnsafeMutableBytes { rawBuffer in
                guard let ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
                for i in 0..<frameCount {
                    let sample = max(-1.0, min(1.0, floatData[0][i]))
                    ptr[i] = Int16(sample * Float(Int16.max))
                }
            }
            return data
        }

        let frameCount = Int(buffer.frameLength)
        return Data(bytes: int16Data[0], count: frameCount * MemoryLayout<Int16>.size)
    }

    /// Convert PCM16 Data to base64 (for OpenAI Realtime API).
    static func pcmDataToBase64(_ data: Data) -> String {
        data.base64EncodedString()
    }
}
