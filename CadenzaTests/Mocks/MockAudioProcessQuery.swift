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

    func startListening() {
        isListening = true
    }

    func stopListening() {
        isListening = false
        onAudioStateChanged = nil
    }

    func simulateAudioChange() {
        onAudioStateChanged?()
    }
}
