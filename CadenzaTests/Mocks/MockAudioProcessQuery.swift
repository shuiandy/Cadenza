import Foundation
@testable import Cadenza

/// Mock implementation of `AudioProcessQuerying` for unit tests.
/// Configure `activeInputBundleIDs` to simulate which processes are using mic input.
final class MockAudioProcessQuery: AudioProcessQuerying {
    var activeInputBundleIDs: Set<String> = []
    /// Processes simulated as playing audio output (used by the Teams call-end probe).
    var activeOutputBundleIDs: Set<String> = []

    func audioUsage(bundleIDs: [String]) -> [String: AudioProcessUsage] {
        var result: [String: AudioProcessUsage] = [:]
        for id in bundleIDs {
            let input = activeInputBundleIDs.contains(id)
            let output = activeOutputBundleIDs.contains(id)
            if input || output {
                result[id] = AudioProcessUsage(isRunningInput: input, isRunningOutput: output)
            }
        }
        return result
    }
}

final class MockAudioStateListener: AudioStateListening {
    var onAudioStateChanged: (() -> Void)?
    private(set) var isListening = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startListening() {
        startCount += 1
        isListening = true
    }

    func stopListening() {
        stopCount += 1
        isListening = false
        onAudioStateChanged = nil
    }

    func simulateAudioChange() {
        onAudioStateChanged?()
    }
}
