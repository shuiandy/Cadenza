import CoreMedia
import AudioToolbox

/// Format-aware audio level from CMSampleBuffers.
///
/// The system-audio process tap always delivers Float32, but the microphone
/// HAL path packs the device's NATIVE stream format — reading it as Float32
/// would score real speech as silence. Supports interleaved Float32 and
/// Int16 linear PCM; returns nil for anything else. Callers MUST treat nil
/// as "audible" (fail-open) so an unparseable format never reads as silence.
enum AudioLevelMeter {

    /// Normalized level `min(rms * 5, 1)` — same scale as the legacy
    /// Float32-only implementation so the UI waveform is unchanged.
    /// Returns nil when the buffer's format is unsupported.
    static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let data = dataPointer, length > 0 else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var sum: Float = 0
        let count: Int

        if isFloat && asbd.mBitsPerChannel == 32 {
            let ptr = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
            count = min(length / MemoryLayout<Float>.size, 1024)
            guard count > 0 else { return nil }
            for i in 0..<count {
                let s = ptr[i]
                sum += s * s
            }
        } else if !isFloat && asbd.mBitsPerChannel == 16 {
            let ptr = UnsafeRawPointer(data).assumingMemoryBound(to: Int16.self)
            count = min(length / MemoryLayout<Int16>.size, 1024)
            guard count > 0 else { return nil }
            for i in 0..<count {
                let s = Float(ptr[i]) / 32768.0
                sum += s * s
            }
        } else {
            return nil
        }

        let rms = sqrt(sum / Float(count))
        return min(rms * 5.0, 1.0)
    }
}
