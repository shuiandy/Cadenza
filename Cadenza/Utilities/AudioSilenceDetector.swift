import AVFoundation

/// Detects whether an audio file is effectively silent by computing its RMS energy.
enum AudioSilenceDetector {

    /// RMS threshold in linear scale. -45 dB ≈ 0.0056.
    /// Audio below this level is considered silence/noise floor.
    private static let silenceThreshold: Float = 0.006

    /// Returns `true` if the audio file at `url` is effectively silent.
    /// Scans the entire file using AVAssetReader with PCM output.
    /// Typically completes in <100ms for a 10-minute 16kHz mono file.
    static func isSilent(at url: URL) async -> Bool {
        // For iCloud files: check both the actual path and the .icloud placeholder.
        // If the file is evicted (only .icloud stub exists), it is NOT silent — caller should
        // attempt to access it (which triggers iCloud download) rather than skip transcription.
        // If file doesn't exist, return false — let the caller handle the missing file error.
        // Returning true here would silently skip transcription with no error message.
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        do {
            let asset = AVURLAsset(url: url)
            let reader = try AVAssetReader(asset: asset)

            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                return true
            }

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            guard reader.canAdd(output) else { return true }
            reader.add(output)
            reader.startReading()

            var sumSquares: Double = 0
            var sampleCount: Int64 = 0

            while let buffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                let count = length / 2 // Int16 = 2 bytes

                var rawBuffer = [Int16](repeating: 0, count: count)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &rawBuffer)

                for sample in rawBuffer {
                    let f = Double(sample) / 32768.0
                    sumSquares += f * f
                }
                sampleCount += Int64(count)
            }

            guard sampleCount > 0 else { return true }

            let rms = Float(sqrt(sumSquares / Double(sampleCount)))
            let isSilent = rms < silenceThreshold
            if isSilent {
                NSLog("[AudioSilenceDetector] file is silent: RMS=%.6f (threshold=%.6f), samples=%lld", rms, silenceThreshold, sampleCount)
            }
            return isSilent
        } catch {
            NSLog("[AudioSilenceDetector] error analyzing audio: %@", error.localizedDescription)
            return false // Don't skip on error — let transcription try
        }
    }

    /// 500ms @ 16kHz mono.
    private static let audibilityWindowSampleCount = 8000

    /// Window-level, per-track audibility check used by trailing-silence trim.
    ///
    /// Differs from `isSilent(at:)` on purpose:
    /// - `isSilent` averages RMS over the WHOLE file — right for "skip
    ///   transcription of a dead file", but 1-2s of quiet speech inside a 30s
    ///   segment dilutes below threshold and would be wrongly trimmed.
    /// - This check decodes EVERY audio track separately (segments carry
    ///   system audio and microphone as two tracks) and slides a 500ms
    ///   window: any window on any track at/above threshold ⇒ audible.
    ///
    /// FAIL-OPEN: every error path (missing/unreadable file, reader failure,
    /// decode error) returns `true` so trim never drops a segment it could
    /// not positively prove silent.
    static func hasAudibleContent(at url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            NSLog("[AudioSilenceDetector] hasAudibleContent: loadTracks failed (%@) — fail-open", error.localizedDescription)
            return true
        }
        guard !tracks.isEmpty else { return true }
        for track in tracks where trackHasAudibleWindow(asset: asset, track: track) {
            return true
        }
        return false
    }

    private static func trackHasAudibleWindow(asset: AVURLAsset, track: AVAssetTrack) -> Bool {
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            guard reader.canAdd(output) else { return true }
            reader.add(output)
            guard reader.startReading() else { return true }

            var windowSumSquares: Double = 0
            var windowSampleCount = 0

            while let buffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                let count = length / 2
                var rawBuffer = [Int16](repeating: 0, count: count)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &rawBuffer)

                for sample in rawBuffer {
                    let f = Double(sample) / 32768.0
                    windowSumSquares += f * f
                    windowSampleCount += 1
                    if windowSampleCount == audibilityWindowSampleCount {
                        if Float(sqrt(windowSumSquares / Double(windowSampleCount))) >= silenceThreshold {
                            reader.cancelReading()
                            return true
                        }
                        windowSumSquares = 0
                        windowSampleCount = 0
                    }
                }
            }

            if reader.status == .failed {
                NSLog("[AudioSilenceDetector] hasAudibleContent: reader failed — fail-open")
                return true
            }
            if windowSampleCount > 0,
               Float(sqrt(windowSumSquares / Double(windowSampleCount))) >= silenceThreshold {
                return true
            }
            return false
        } catch {
            NSLog("[AudioSilenceDetector] hasAudibleContent: %@ — fail-open", error.localizedDescription)
            return true
        }
    }
}
