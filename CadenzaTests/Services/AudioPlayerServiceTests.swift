import AVFoundation
import Foundation
import Testing

@testable import Cadenza

@Suite("Audio player load ownership", .serialized)
@MainActor
struct AudioPlayerServiceTests {
    @Test func staleDurationCannotOverwriteNewerLoad() async {
        let loader = ControlledAudioDurationLoader()
        let player = AudioPlayerService(durationLoader: loader.load)
        let first = URL(fileURLWithPath: "/tmp/first.m4a")
        let second = URL(fileURLWithPath: "/tmp/second.m4a")

        player.load(url: first)
        #expect(await waitUntil { loader.hasRequest(for: first) })
        player.load(url: second)
        #expect(await waitUntil { loader.hasRequest(for: second) })

        loader.resolve(second, duration: 22)
        #expect(await waitUntil { player.duration == 22 })

        loader.resolve(first, duration: 99)
        await Task.yield()

        #expect(player.duration == 22)
    }

    @Test func stopInvalidatesInFlightDurationLoad() async {
        let loader = ControlledAudioDurationLoader()
        let player = AudioPlayerService(durationLoader: loader.load)
        let url = URL(fileURLWithPath: "/tmp/stopped.m4a")

        player.load(url: url)
        #expect(await waitUntil { loader.hasRequest(for: url) })
        player.stop()
        loader.resolve(url, duration: 45)
        await Task.yield()

        #expect(player.duration == 0)
        #expect(player.currentTime == 0)
        #expect(!player.isPlaying)
    }

    @Test func invalidDurationsFailClosedToZero() {
        #expect(AudioPlayerService.sanitizedDuration(nil) == 0)
        #expect(AudioPlayerService.sanitizedDuration(0) == 0)
        #expect(AudioPlayerService.sanitizedDuration(-1) == 0)
        #expect(AudioPlayerService.sanitizedDuration(.infinity) == 0)
        #expect(AudioPlayerService.sanitizedDuration(.nan) == 0)
        #expect(AudioPlayerService.sanitizedDuration(12.5) == 12.5)
    }
}

@MainActor
private final class ControlledAudioDurationLoader {
    private var requests = Set<URL>()
    private var continuations: [URL: CheckedContinuation<TimeInterval?, Never>] = [:]

    func load(_ asset: AVAsset) async -> TimeInterval? {
        guard let url = (asset as? AVURLAsset)?.url else { return nil }
        requests.insert(url)
        return await withCheckedContinuation { continuation in
            continuations[url] = continuation
        }
    }

    func hasRequest(for url: URL) -> Bool {
        requests.contains(url)
    }

    func resolve(_ url: URL, duration: TimeInterval?) {
        continuations.removeValue(forKey: url)?.resume(returning: duration)
    }
}

@MainActor
private func waitUntil(
    attempts: Int = 200,
    condition: @escaping @MainActor @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
