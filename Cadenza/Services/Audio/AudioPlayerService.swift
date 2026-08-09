import AVFoundation

typealias AudioDurationLoader = @MainActor @Sendable (AVAsset) async -> TimeInterval?

/// Audio player using AVPlayer for multi-track .m4a playback.
/// AVPlayer automatically mixes all audio tracks (system + microphone).
@Observable @MainActor
final class AudioPlayerService {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var playbackRate: Float = 1.0

    static let availableRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private let durationLoader: AudioDurationLoader
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var durationLoadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0

    init(
        durationLoader: @escaping AudioDurationLoader = { asset in
            let duration = try? await asset.load(.duration)
            return duration?.seconds
        }
    ) {
        self.durationLoader = durationLoader
    }

    func load(url: URL) {
        stop()

        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        self.player = avPlayer

        // Bind duration completion to this exact load. Cancellation is only an
        // optimization; the generation check also protects against loaders
        // that cannot stop an in-flight metadata request.
        loadGeneration &+= 1
        let generation = loadGeneration
        let durationLoader = durationLoader
        let asset = item.asset
        durationLoadTask = Task { [weak self] in
            let loadedDuration = await durationLoader(asset)
            guard let self,
                  !Task.isCancelled,
                  self.loadGeneration == generation else { return }

            self.duration = Self.sanitizedDuration(loadedDuration)
            self.durationLoadTask = nil
        }

        currentTime = 0
    }

    func play() {
        guard let player, !isPlaying else { return }
        player.rate = playbackRate
        isPlaying = true
        startTimeObserver()
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    func cycleRate() {
        let rates = Self.availableRates
        if let idx = rates.firstIndex(of: playbackRate) {
            let next = rates[(idx + 1) % rates.count]
            setRate(next)
        } else {
            setRate(1.0)
        }
    }

    func pause() {
        guard let player, isPlaying else { return }
        player.pause()
        isPlaying = false
        removeTimeObserver()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    func stop() {
        durationLoadTask?.cancel()
        durationLoadTask = nil
        loadGeneration &+= 1
        player?.pause()
        removeTimeObserver()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    static func sanitizedDuration(_ duration: TimeInterval?) -> TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else { return 0 }
        return duration
    }

    // MARK: - Time Observer

    private func startTimeObserver() {
        guard let player else { return }
        removeTimeObserver()

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                self.currentTime = seconds.isFinite ? seconds : 0

                // Detect end of playback
                if let item = self.player?.currentItem,
                   item.status == .readyToPlay,
                   self.duration > 0,
                   seconds >= self.duration - 0.1 {
                    self.isPlaying = false
                    self.currentTime = 0
                    self.player?.seek(to: .zero)
                    self.removeTimeObserver()
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
}
