import Foundation

/// When to commit buffered audio for `gpt-live-transcribe`, which rejects server
/// turn detection. The model streams deltas while audio arrives but holds the end
/// of an utterance until a commit, so committing on a fixed interval left each
/// finished sentence waiting for the next tick. Committing right after a pause
/// finalizes it at once; the fallback bounds turns during continuous speech.
///
/// Measured on 2026-09-29 against fictional bilingual clips: the time from the
/// end of speech to a complete caption fell from about 1.7 s (p90 2.8 s) with a
/// 2.8 s interval to about 0.6–0.9 s, and stayed near 1 s with pink noise or
/// office babble 20 dB below speech, with no loss of accuracy.
///
/// Fluent speech often runs past 6 s without a 500 ms pause, and the fallback
/// then cuts wherever it lands, often inside a word, which the model transcribes
/// on both sides of the cut ("end of October. October and"). Once a turn is 3 s
/// long, a 200 ms gap ends it instead. In the same clips, quiet runs within
/// fluent speech (stop consonants, dips between words) stayed at or under
/// 120 ms, and gaps between phrases ran 200–300 ms. On 88 s of speech joined
/// with 250 ms gaps, the fallback cut inside a word 8 times; with the shorter
/// gap it did so 0 times in clean audio and 4 times with pink noise 20 dB below
/// speech. Against the live service, the share of turns ending at punctuation
/// rose from about 61% to 92% (clean) and 63% to 89% (pink noise), with no loss
/// of accuracy. Babble masks many gaps, so more of those turns still reach the
/// fallback (33% to 47% at punctuation).
struct LiveCommitPolicy: Sendable {
    /// Silence after speech that ends a turn.
    var pauseDuration: TimeInterval = 0.5
    /// Turn length after which `shortPauseDuration` also ends it: 3 s. nil
    /// leaves long turns to the fallback.
    var shortPauseAfterBytes: Int? = 144_000
    /// Quiet this long falls between phrases, not inside a word.
    var shortPauseDuration: TimeInterval = 0.2
    /// Longest turn without a pause: 6 s of 24 kHz mono PCM16.
    var fallbackBytes = 288_000
    /// Same bound in wall-clock time, for sparse audio delivery.
    var fallbackInterval: TimeInterval = 6
    /// Smallest buffer the service accepts as a turn (~420 ms).
    var minCommitBytes = 20_000
}

/// Classifies 24 kHz mono PCM16 audio as speech or silence against an adaptive
/// noise floor and reports when a pause, or a shorter gap, follows speech.
///
/// The floor is the quietest 20 ms sub-frame of the last 5 s (minimum
/// statistics), so steady room or line noise does not read as speech. A 100 ms
/// frame is speech when its RMS exceeds twice the floor and an absolute minimum.
/// A fixed threshold found no pauses at all once steady noise reached 20 dB below
/// speech; a higher multiple mistook quiet syllables for silence and cut turns
/// mid-word. When the detector cannot find a pause, as under dense background
/// talk, the policy's fallback takes over, which is the old fixed behavior.
///
/// Short gaps are counted in 20 ms sub-frames against the same threshold, since
/// a 200 ms gap rarely covers two whole 100 ms frames.
struct PauseDetector: Sendable {
    static let sampleRate = 24_000
    static let frameSamples = 2_400        // 100 ms
    static let subFrameSamples = 480       // 20 ms
    static let subFramesPerFrame = 5
    static let floorWindowSubFrames = 250  // 5 s
    static let floorMultiple = 2.0
    static let absoluteMinimumRMS = 150.0

    private let pauseFrames: Int
    private let shortPauseSubFrames: Int
    private var pending: [Int16] = []
    private var subFrameRMS: [Double] = []
    /// Mean squares of the current frame's sub-frames.
    private var frameMeanSquares: [Double] = []
    private var silentFrames = 0
    private var quietSubFrames = 0
    private var heardSpeech = false

    init(pauseDuration: TimeInterval, shortPauseDuration: TimeInterval = 0.2) {
        pauseFrames = max(1, Int((pauseDuration * Double(Self.sampleRate) / Double(Self.frameSamples)).rounded()))
        shortPauseSubFrames = max(1, Int((shortPauseDuration * Double(Self.sampleRate) / Double(Self.subFrameSamples)).rounded()))
    }

    /// Consumes PCM16 bytes of any length. Returns `hasPause`.
    @discardableResult
    mutating func ingest(_ pcm: Data) -> Bool {
        pcm.withUnsafeBytes { raw in
            pending.append(contentsOf: raw.bindMemory(to: Int16.self))
        }
        var start = 0
        while pending.count - start >= Self.subFrameSamples {
            classifySubFrame(pending[start..<(start + Self.subFrameSamples)])
            start += Self.subFrameSamples
        }
        pending.removeFirst(start)
        return hasPause
    }

    /// A pause long enough to end a turn has followed speech since the last commit.
    var hasPause: Bool {
        heardSpeech && silentFrames >= pauseFrames
    }

    /// A shorter gap has followed speech since the last commit.
    var hasShortPause: Bool {
        heardSpeech && quietSubFrames >= shortPauseSubFrames
    }

    /// A commit starts a new turn: later silence alone must not end another one.
    mutating func didCommit() {
        heardSpeech = false
    }

    private mutating func classifySubFrame(_ samples: ArraySlice<Int16>) {
        let rms = Self.rms(samples)
        subFrameRMS.append(rms)
        if subFrameRMS.count > Self.floorWindowSubFrames {
            subFrameRMS.removeFirst(subFrameRMS.count - Self.floorWindowSubFrames)
        }
        let floor = subFrameRMS.min() ?? 0
        let threshold = max(Self.absoluteMinimumRMS, floor * Self.floorMultiple)
        quietSubFrames = rms > threshold ? 0 : quietSubFrames + 1

        frameMeanSquares.append(rms * rms)
        guard frameMeanSquares.count == Self.subFramesPerFrame else { return }
        let frameRMS = (frameMeanSquares.reduce(0, +) / Double(Self.subFramesPerFrame)).squareRoot()
        frameMeanSquares.removeAll(keepingCapacity: true)
        if frameRMS > threshold {
            silentFrames = 0
            heardSpeech = true
        } else {
            silentFrames += 1
        }
    }

    static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        return (sum / Double(samples.count)).squareRoot()
    }
}
