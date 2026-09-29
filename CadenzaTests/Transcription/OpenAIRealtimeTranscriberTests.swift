import Foundation
import Testing
@testable import Cadenza

private actor OpenAIWebSocketProbe {
    enum Handshake: Sendable {
        case accept, manual, reject, disconnect
    }

    private let handshake: Handshake
    private var incoming: [String] = []
    private var receiver: CheckedContinuation<String, Error>?
    private var closed = false
    private(set) var sent: [String] = []
    private(set) var receiveCount = 0
    private(set) var cancelCount = 0

    init(_ handshake: Handshake = .accept) { self.handshake = handshake }

    func transport() -> OpenAIRealtimeTransport {
        OpenAIRealtimeTransport(
            send: { try await self.send($0) },
            receive: { try await self.receive() },
            cancel: { Task { await self.cancel() } }
        )
    }

    func emit(_ text: String) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: text)
        } else {
            incoming.append(text)
        }
    }

    func sentTypes() throws -> [String] {
        try sent.map { text in
            let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            return json?["type"] as? String ?? ""
        }
    }

    private func send(_ text: String) throws {
        sent.append(text)
        let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        switch json["type"] as? String {
        case "session.update":
            emit(#"{"type":"session.created"}"#)
            switch handshake {
            case .accept:
                let session = try #require(json["session"] as? [String: Any])
                let audio = try #require(session["audio"] as? [String: Any])
                let input = try #require(audio["input"] as? [String: Any])
                let transcription = try #require(input["transcription"] as? [String: Any])
                if transcription["model"] as? String == "gpt-live-transcribe",
                   !(input["turn_detection"] is NSNull)
                    || transcription["language"] != nil || session["include"] != nil {
                    emit(Self.rejection)
                } else {
                    emit(#"{"type":"session.updated"}"#)
                }
            case .reject: emit(Self.rejection)
            case .manual, .disconnect: break
            }
        case "input_audio_buffer.append":
            emit(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"Test "}"#)
        case "input_audio_buffer.commit":
            emit(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Test caption."}"#)
        default: break
        }
    }

    private static let rejection = #"{"type":"error","error":{"code":"invalid_value","message":"Rejected transcription configuration"}}"#

    private func receive() async throws -> String {
        receiveCount += 1
        if !incoming.isEmpty { return incoming.removeFirst() }
        if handshake == .disconnect { throw URLError(.networkConnectionLost) }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    private func cancel() {
        closed = true
        cancelCount += 1
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
}

private actor OpenAIStartupProbe {
    private(set) var complete = false
    func finish() { complete = true }
}

@Suite("OpenAI realtime protocol")
struct OpenAIRealtimeTranscriberTests {
    @Test("Live model configuration is accepted and commits produce final captions", arguments: ["auto", "en", "zh"])
    func liveProtocol(language: String) async throws {
        let socket = OpenAIWebSocketProbe()
        let service = await service(socket)
        let stream = try await service.startRealtimeSession(language: language)
        let reader = Task { () throws -> [TranscriptDelta] in
            var values: [TranscriptDelta] = []
            for try await delta in stream {
                values.append(delta)
                if delta.isFinal { break }
            }
            return values
        }
        try await service.sendAudio(Data(repeating: 0, count: 20_000))
        #expect(try await socket.sentTypes() == ["session.update", "input_audio_buffer.append"])
        try await service.sendAudio(Data(repeating: 0, count: 124_000))
        #expect(try await socket.sentTypes().last == "input_audio_buffer.commit")
        let values = try await HardAsyncDeadline.run(for: .seconds(2)) { try await reader.value }
        #expect(values.last?.text == "Test caption.")
        #expect(values.last?.isFinal == true)

        let first = try #require(await socket.sent.first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        let session = try #require(json["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["languages"] as? [String] == (language == "auto" ? nil : [language]))
        try await service.stopRealtimeSession()
        try await waitUntil { await socket.cancelCount == 1 }
    }

    @Test("session.created does not prove configuration acceptance")
    func waitsForUpdate() async throws {
        let socket = OpenAIWebSocketProbe(.manual)
        let service = await service(socket)
        let completion = OpenAIStartupProbe()
        let task = Task {
            let stream = try await service.startRealtimeSession(language: nil)
            await completion.finish()
            return stream
        }
        try await waitUntil { await socket.receiveCount >= 2 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(await completion.complete == false)
        await socket.emit(#"{"type":"session.updated"}"#)
        _ = try await task.value
        #expect(await completion.complete)
        try await service.stopRealtimeSession()
    }

    @Test("Rejected configuration fails startup with its original error")
    func rejectedConfiguration() async throws {
        let socket = OpenAIWebSocketProbe(.reject)
        let service = await service(socket)
        do {
            _ = try await service.startRealtimeSession(language: nil)
            Issue.record("Rejected session must not become ready")
        } catch TranscriptionError.apiError(let message) {
            #expect(message == "Rejected transcription configuration")
        }
        try await waitUntil { await socket.cancelCount == 1 }
    }

    @Test("Disconnected handshake does not degrade to a misleading timeout")
    func disconnectedHandshake() async throws {
        let socket = OpenAIWebSocketProbe(.disconnect)
        let service = await service(socket)
        await #expect(throws: URLError.self) {
            _ = try await service.startRealtimeSession(language: nil)
        }
        try await waitUntil { await socket.cancelCount == 1 }
    }

    @Test("Missing configuration acknowledgement times out and closes the socket")
    func timeout() async throws {
        let socket = OpenAIWebSocketProbe(.manual)
        let service = RealtimeTranscriber(
            apiKey: "fictional", model: "gpt-live-transcribe",
            transportForTesting: await socket.transport(), startupTimeout: .milliseconds(50)
        )
        do {
            _ = try await service.startRealtimeSession(language: nil)
            Issue.record("Unacknowledged configuration must time out")
        } catch TranscriptionError.apiError(let message) {
            #expect(message.contains("session.updated"))
        }
        try await waitUntil { await socket.cancelCount == 1 }
    }

    @Test("Cancelling startup closes its socket")
    func cancelledStartup() async throws {
        let socket = OpenAIWebSocketProbe(.manual)
        let service = await service(socket)
        let task = Task { try await service.startRealtimeSession(language: nil) }
        try await waitUntil { await socket.receiveCount >= 2 }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await waitUntil { await socket.cancelCount == 1 }
    }

    @Test("Legacy model retains VAD and singular language configuration")
    func legacyModel() async throws {
        let socket = OpenAIWebSocketProbe()
        let service = RealtimeTranscriber(
            apiKey: "fictional", model: "gpt-4o-transcribe", transportForTesting: await socket.transport()
        )
        _ = try await service.startRealtimeSession(language: "en")
        let first = try #require(await socket.sent.first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        let session = try #require(json["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let vad = try #require(input["turn_detection"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(vad["type"] as? String == "server_vad")
        #expect(transcription["language"] as? String == "en")
        #expect(transcription["languages"] == nil)
        try await service.sendAudio(Data(repeating: 0, count: 144_000))
        #expect(try await socket.sentTypes() == ["session.update", "input_audio_buffer.append"])
        try await service.stopRealtimeSession()
    }

    @Test("Stopping an unacknowledged session unblocks startup without marking it ready")
    func stopDuringStartup() async throws {
        let socket = OpenAIWebSocketProbe(.manual)
        let service = await service(socket)
        let task = Task { try await service.startRealtimeSession(language: nil) }
        try await waitUntil { await socket.receiveCount >= 2 }
        try await service.stopRealtimeSession()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await waitUntil { await socket.cancelCount == 1 }
    }

    @Test("Commit interval finalizes small continuous audio batches")
    func timedCommit() async throws {
        let socket = OpenAIWebSocketProbe()
        let service = await service(socket)
        _ = try await service.startRealtimeSession(language: nil)
        try await service.sendAudio(Data(repeating: 0, count: 10_000))
        try await Task.sleep(for: .milliseconds(2_850))
        try await service.sendAudio(Data(repeating: 0, count: 10_000))
        #expect(try await socket.sentTypes().last == "input_audio_buffer.commit")
        try await service.stopRealtimeSession()
    }

    @Test("Stopping flushes a valid tail but never an undersized buffer", arguments: [100, 20_000])
    func stopTail(bytes: Int) async throws {
        let socket = OpenAIWebSocketProbe()
        let service = await service(socket)
        _ = try await service.startRealtimeSession(language: nil)
        try await service.sendAudio(Data(repeating: 0, count: bytes))
        try await service.stopRealtimeSession()
        #expect(try await socket.sentTypes().contains("input_audio_buffer.commit") == (bytes >= 20_000))
        try await waitUntil { await socket.cancelCount == 1 }
    }

    private func service(_ socket: OpenAIWebSocketProbe) async -> RealtimeTranscriber {
        RealtimeTranscriber(apiKey: "fictional", model: "gpt-live-transcribe", transportForTesting: await socket.transport())
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                throw TranscriptionError.apiError("Test event did not arrive")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
