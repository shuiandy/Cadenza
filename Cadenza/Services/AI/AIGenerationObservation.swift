import Foundation
import Synchronization

/// Opt-in diagnostics. Never stores prompts, response text, URLs or credentials.
enum AIGenerationObservation {
    @TaskLocal static var trace: AIGenerationTrace?
}

final class AIGenerationTrace: Sendable {
    struct Request: Codable, Sendable {
        var provider: String
        var model: String?
        var outputLimit: Int?
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var cacheWriteTokens: Int?
        var stopReason: String?
        var elapsedSeconds: Double = 0
    }
    struct Snapshot: Codable, Sendable {
        let requests: [Request]
        let gateWaitSeconds: Double
    }
    private struct State {
        var requests: [UUID: Request] = [:]
        var order: [UUID] = []
        var starts: [UUID: ContinuousClock.Instant] = [:]
        var wait: Double = 0
    }
    private let state = Mutex(State())

    func begin(request: URLRequest, provider: AIProvider?) -> UUID {
        let id = UUID()
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        state.withLock {
            $0.requests[id] = Request(provider: provider?.rawValue ?? "unknown", model: body?["model"] as? String,
                                      outputLimit: body?["max_tokens"] as? Int)
            $0.order.append(id)
            $0.starts[id] = .now
        }
        return id
    }

    func observe(data: Data, requestID: UUID) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let message = json["message"] as? [String: Any]
        let usage = (json["usage"] ?? message?["usage"] ?? json["usageMetadata"]) as? [String: Any]
        let choice = (json["choices"] as? [[String: Any]])?.first
        let delta = json["delta"] as? [String: Any]
        let candidate = (json["candidates"] as? [[String: Any]])?.first
        state.withLock { state in
            guard var item = state.requests[requestID] else { return }
            if let usage {
                if let value = (usage["input_tokens"] ?? usage["prompt_tokens"] ?? usage["promptTokenCount"]) as? Int { item.inputTokens = value }
                if let value = (usage["output_tokens"] ?? usage["completion_tokens"] ?? usage["candidatesTokenCount"]) as? Int { item.outputTokens = value }
                if let value = usage["cache_read_input_tokens"] as? Int { item.cacheReadTokens = value }
                if let value = usage["cache_creation_input_tokens"] as? Int { item.cacheWriteTokens = value }
            }
            if let reason = (json["stop_reason"] ?? delta?["stop_reason"] ?? choice?["finish_reason"] ?? candidate?["finishReason"]) as? String { item.stopReason = reason }
            state.requests[requestID] = item
        }
    }

    func finish(_ id: UUID) {
        state.withLock { state in
            guard let start = state.starts.removeValue(forKey: id) else { return }
            state.requests[id]?.elapsedSeconds = Self.seconds(start.duration(to: .now))
        }
    }

    func recordWait(_ duration: Duration) {
        state.withLock { $0.wait += Self.seconds(duration) }
    }

    func snapshot() -> Snapshot {
        state.withLock { state in
            Snapshot(requests: state.order.compactMap { id in
                guard var item = state.requests[id] else { return nil }
                if let start = state.starts[id] { item.elapsedSeconds = Self.seconds(start.duration(to: .now)) }
                return item
            }, gateWaitSeconds: state.wait)
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
