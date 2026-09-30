import Foundation
import Testing
@testable import Cadenza

private actor OpenAIWebSocketProbe {
    enum Handshake: Sendable {
        case accept, manual, reject, disconnect
    }

    private let handshake: Handshake
    private let transcribesCommits: Bool
    private var incoming: [String] = []
    private var receiver: CheckedContinuation<String, Error>?
    private var closed = false
    private(set) var sent: [String] = []
    private(set) var receiveCount = 0
    private(set) var cancelCount = 0
    /// Audio bytes appended so far, and that count at each commit.
    private(set) var appendedBytes = 0
    private(set) var commitOffsets: [Int] = []

    /// - Parameter transcribesCommits: Acknowledge and transcribe each commit
    ///   at once, as the live service does. When false the test emits them.
    init(_ handshake: Handshake = .accept, transcribesCommits: Bool = true) {
        self.handshake = handshake
        self.transcribesCommits = transcribesCommits
    }

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
            let audio = try #require(json["audio"] as? String)
            appendedBytes += try #require(Data(base64Encoded: audio)).count
            emit(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"Test "}"#)
        case "input_audio_buffer.commit":
            commitOffsets.append(appendedBytes)
            guard transcribesCommits else { break }
            let item = "item_\(commitOffsets.count)"
            emit(#"{"type":"input_audio_buffer.committed","item_id":"\#(item)"}"#)
            emit(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"\#(item)","transcript":"Test caption."}"#)
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
        try await service.sendAudio(PCMFixture.speech(seconds: 0.5))
        // A block larger than a capture buffer goes out 20 ms at a time.
        #expect(try await socket.sentTypes() == ["session.update"] + Array(repeating: "input_audio_buffer.append", count: 25))
        // The pause after speech ends the turn, 500 ms into the silence.
        try await service.sendAudio(PCMFixture.silence(seconds: 0.8))
        #expect(try await socket.sentTypes().contains("input_audio_buffer.commit"))
        #expect(await socket.commitOffsets == [48_000])
        let values = try await HardAsyncDeadline.run(for: .seconds(2)) { try await reader.value }
        #expect(values.last?.text == "Test caption.")
        #expect(values.last?.isFinal == true)
        let commitOffset = await socket.commitOffsets.first
        #expect(values.last?.finalizedAudioBytes == commitOffset)

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

    @Test("Continuous speech without a pause commits at the byte fallback")
    func byteFallbackCommit() async throws {
        let socket = OpenAIWebSocketProbe()
        let service = await service(socket)
        _ = try await service.startRealtimeSession(language: nil)
        let speech = PCMFixture.speech(seconds: 6)
        var offset = 0
        while offset < speech.count - 4_800 {
            try await service.sendAudio(speech.subdata(in: offset..<(offset + 4_800)))
            offset += 4_800
        }
        #expect(try await socket.sentTypes().filter { $0 == "input_audio_buffer.commit" }.isEmpty)
        try await service.sendAudio(speech.subdata(in: offset..<speech.count))
        #expect(try await socket.sentTypes().filter { $0 == "input_audio_buffer.commit" }.count == 1)
        try await service.stopRealtimeSession()
    }

    @Test("Sparse audio still commits at the time fallback")
    func timeFallbackCommit() async throws {
        let socket = OpenAIWebSocketProbe()
        let service = RealtimeTranscriber(
            apiKey: "fictional", model: "gpt-live-transcribe",
            transportForTesting: await socket.transport(),
            commitPolicy: LiveCommitPolicy(fallbackInterval: 0.3)
        )
        _ = try await service.startRealtimeSession(language: nil)
        try await service.sendAudio(PCMFixture.speech(seconds: 0.4))
        try await Task.sleep(for: .milliseconds(350))
        try await service.sendAudio(PCMFixture.speech(seconds: 0.1))
        // The first 20 ms of the late audio already meets the time fallback.
        #expect(await socket.commitOffsets == [19_200 + 960])
        try await service.stopRealtimeSession()
    }

    @Test("Silence alone never ends a turn")
    func silenceOnlyNeverCommits() async throws {
        let socket = OpenAIWebSocketProbe()
        let service = await service(socket)
        _ = try await service.startRealtimeSession(language: nil)
        for _ in 0..<20 { try await service.sendAudio(PCMFixture.silence(seconds: 0.1)) }
        #expect(!(try await socket.sentTypes().contains("input_audio_buffer.commit")))
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

    @Test("A block of audio is committed at the pause inside it, not at its end")
    func pauseInsideBlock() async throws {
        let socket = OpenAIWebSocketProbe()
        let service = await service(socket)
        _ = try await service.startRealtimeSession(language: nil)
        // Audio replayed after a reconnect arrives as one large block.
        let block = PCMFixture.speech(seconds: 1) + PCMFixture.silence(seconds: 0.6) + PCMFixture.speech(seconds: 1)
        try await service.sendAudio(block)
        // 1 s of speech, then the fifth 100 ms frame of silence ends the turn.
        #expect(await socket.commitOffsets == [72_000])
        #expect(await socket.appendedBytes == block.count)
        try await service.stopRealtimeSession()
    }

    @Test("A long turn ends at a 200 ms gap instead of waiting for the fallback", arguments: [false, true])
    func longTurnEndsAtShortGap(asOneBlock: Bool) async throws {
        let socket = OpenAIWebSocketProbe()
        let service = await service(socket)
        _ = try await service.startRealtimeSession(language: nil)
        let audio = PCMFixture.speech(seconds: 3.5) + PCMFixture.silence(seconds: 0.25) + PCMFixture.speech(seconds: 2)
        if asOneBlock {
            try await service.sendAudio(audio)
        } else {
            // Capture-sized buffers go out whole.
            for start in stride(from: 0, to: audio.count, by: 1_024) {
                try await service.sendAudio(audio.subdata(in: start..<min(audio.count, start + 1_024)))
            }
        }
        // 3.5 s of speech, then the tenth quiet 20 ms sub-frame ends the turn.
        let gapEnd = 177_600
        let offsets = await socket.commitOffsets
        #expect(offsets.count == 1)
        if let first = offsets.first {
            #expect(first >= gapEnd && first < gapEnd + 1_024)
        }
        try await service.stopRealtimeSession()
    }

    @Test("A short gap early in a turn, or with the rule off, does not end it")
    func shortGapNeedsLongTurn() async throws {
        let early = OpenAIWebSocketProbe()
        let earlyService = await service(early)
        _ = try await earlyService.startRealtimeSession(language: nil)
        try await earlyService.sendAudio(
            PCMFixture.speech(seconds: 1.5) + PCMFixture.silence(seconds: 0.25) + PCMFixture.speech(seconds: 1)
        )
        #expect(await early.commitOffsets.isEmpty)
        try await earlyService.stopRealtimeSession()

        let disabled = OpenAIWebSocketProbe()
        let disabledService = RealtimeTranscriber(
            apiKey: "fictional", model: "gpt-live-transcribe",
            transportForTesting: await disabled.transport(),
            commitPolicy: LiveCommitPolicy(shortPauseAfterBytes: nil)
        )
        _ = try await disabledService.startRealtimeSession(language: nil)
        try await disabledService.sendAudio(
            PCMFixture.speech(seconds: 3.5) + PCMFixture.silence(seconds: 0.25) + PCMFixture.speech(seconds: 2.5)
        )
        #expect(await disabled.commitOffsets == [288_000])
        try await disabledService.stopRealtimeSession()
    }

    @Test("Finals report finalized audio only once every earlier turn is settled")
    func finalizedAudioFollowsOldestTurn() async throws {
        let socket = OpenAIWebSocketProbe(transcribesCommits: false)
        let service = await service(socket)
        let stream = try await service.startRealtimeSession(language: nil)
        let collector = DeltaCollector(stream)
        let turn = PCMFixture.speech(seconds: 0.5) + PCMFixture.silence(seconds: 0.6)
        try await service.sendAudio(turn)
        try await service.sendAudio(turn)
        try await service.sendAudio(turn)
        let offsets = await socket.commitOffsets
        try #require(offsets.count == 3)

        // An empty commit is refused and creates no turn; later turns keep
        // their own offsets.
        await socket.emit(#"{"type":"error","error":{"code":"input_audio_buffer_commit_empty"}}"#)
        await socket.emit(#"{"type":"input_audio_buffer.committed","item_id":"b"}"#)
        await socket.emit(#"{"type":"input_audio_buffer.committed","item_id":"c"}"#)
        // Out of order: c's text arrives first but b's audio is not final yet.
        await socket.emit(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"c","transcript":"Third."}"#)
        // b fails: no text, but its audio is settled, which settles c's too.
        await socket.emit(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"b"}"#)
        try await waitUntil { await collector.finals.count == 2 }
        let finals = await collector.finals
        #expect(finals[0].text == "Third.")
        #expect(finals[0].finalizedAudioBytes == nil)
        #expect(finals[1].text == "")
        #expect(finals[1].finalizedAudioBytes == offsets[2])
        try await service.stopRealtimeSession()
    }

    @Test("A turn without speech still reports its audio as final")
    func silentTurnReportsFinalizedAudio() async throws {
        let socket = OpenAIWebSocketProbe(transcribesCommits: false)
        let service = await service(socket)
        let stream = try await service.startRealtimeSession(language: nil)
        let collector = DeltaCollector(stream)
        try await service.sendAudio(PCMFixture.speech(seconds: 0.5) + PCMFixture.silence(seconds: 0.6))
        let offset = try #require(await socket.commitOffsets.first)
        await socket.emit(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#)
        await socket.emit(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":""}"#)
        try await waitUntil { await collector.finals.count == 1 }
        #expect(await collector.finals.first?.text == "")
        #expect(await collector.finals.first?.finalizedAudioBytes == offset)
        try await service.stopRealtimeSession()
    }

    @Test("Only the live model reports finalized audio")
    func finalizedAudioCapability() {
        #expect(RealtimeTranscriber(apiKey: "fictional", model: "gpt-live-transcribe").reportsFinalizedAudio)
        #expect(!RealtimeTranscriber(apiKey: "fictional", model: "gpt-4o-transcribe").reportsFinalizedAudio)
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

private actor DeltaCollector {
    private(set) var finals: [TranscriptDelta] = []

    init(_ stream: AsyncThrowingStream<TranscriptDelta, Error>) {
        Task { await self.collect(stream) }
    }

    private func collect(_ stream: AsyncThrowingStream<TranscriptDelta, Error>) async {
        do {
            for try await delta in stream where delta.isFinal {
                finals.append(delta)
            }
        } catch {}
    }
}

/// Fictional 24 kHz mono PCM16 signals. "Speech" is a tone whose loudness rises and
/// falls four times a second, so it has the syllable dips that let an adaptive
/// noise floor sit below it; a constant tone would become its own floor.
enum PCMFixture {
    static func speech(seconds: Double, amplitude: Double = 4_000) -> Data {
        samples(seconds) { t in amplitude * abs(sin(2 * .pi * 4 * t)) * sin(2 * .pi * 220 * t) }
    }

    static func silence(seconds: Double) -> Data {
        samples(seconds) { _ in 0 }
    }

    /// Uniform noise with the given RMS from a fixed seed, so runs are repeatable.
    static func noise(seconds: Double, rms: Double, seed: UInt64 = 7) -> Data {
        var state = seed
        let peak = rms * 3.0.squareRoot()
        return samples(seconds) { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53)
            return (unit * 2 - 1) * peak
        }
    }

    static func mix(_ a: Data, _ b: Data) -> Data {
        let x = int16s(a), y = int16s(b)
        let mixed = zip(x, y).map { Int16(clamping: Int($0) + Int($1)) }
        return mixed.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func samples(_ seconds: Double, _ value: (Double) -> Double) -> Data {
        let count = Int(seconds * 24_000)
        let values = (0..<count).map { Int16(clamping: Int(value(Double($0) / 24_000).rounded())) }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func int16s(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}

@Suite("Live caption pause detection")
struct PauseDetectorTests {
    private func chunks(_ data: Data, size: Int = 4_800) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min(data.count, $0 + size)) }
    }

    @Test("A pause is reported only after 500 ms of silence that follows speech")
    func pauseFollowsSpeech() {
        var detector = PauseDetector(pauseDuration: 0.5)
        let afterSpeech = detector.ingest(PCMFixture.speech(seconds: 0.5))
        #expect(!afterSpeech)
        let silence = chunks(PCMFixture.silence(seconds: 0.5))
        let results = silence.map { detector.ingest($0) }
        #expect(results.dropLast().allSatisfy { !$0 })
        #expect(results.last == true)
    }

    @Test("Silence alone is never a pause")
    func silenceOnly() {
        var detector = PauseDetector(pauseDuration: 0.5)
        let results = chunks(PCMFixture.silence(seconds: 3)).map { detector.ingest($0) }
        #expect(results.allSatisfy { !$0 })
    }

    @Test("A short dip inside speech does not end the turn")
    func shortDip() {
        var detector = PauseDetector(pauseDuration: 0.5)
        let signal = PCMFixture.speech(seconds: 1) + PCMFixture.silence(seconds: 0.2) + PCMFixture.speech(seconds: 1)
        let results = chunks(signal).map { detector.ingest($0) }
        #expect(results.allSatisfy { !$0 })
    }

    @Test("Steady background noise still leaves pauses detectable")
    func steadyNoise() {
        // Noise at RMS 300 is above the absolute minimum of 150, so a fixed
        // threshold would read it as endless speech and never find a pause.
        var detector = PauseDetector(pauseDuration: 0.5)
        let noise = PCMFixture.noise(seconds: 4, rms: 300)
        let speech = PCMFixture.speech(seconds: 1) + PCMFixture.silence(seconds: 3)
        let signal = PCMFixture.mix(noise, PCMFixture.silence(seconds: 1) + speech)
        let results = chunks(signal).map { detector.ingest($0) }
        #expect(results.prefix(20).allSatisfy { !$0 })
        #expect(results.dropFirst(20).contains(true))
    }

    @Test("Chunk size does not change where the pause is found")
    func chunkSizeIndependent() {
        let signal = PCMFixture.speech(seconds: 1) + PCMFixture.silence(seconds: 1)
        func firstPauseOffset(chunkSize: Int) -> Int? {
            var detector = PauseDetector(pauseDuration: 0.5)
            var offset = 0
            for chunk in chunks(signal, size: chunkSize) {
                offset += chunk.count
                if detector.ingest(chunk) { return offset }
            }
            return nil
        }
        let even = firstPauseOffset(chunkSize: 4_800)
        let odd = firstPauseOffset(chunkSize: 1_234)
        #expect(even != nil && odd != nil)
        if let even, let odd { #expect(abs(even - odd) < 4_800) }
    }

    @Test("A 200 ms gap after speech is a short pause; a stop-consonant gap is not")
    func shortPauseBoundary() {
        var detector = PauseDetector(pauseDuration: 0.5)
        detector.ingest(PCMFixture.silence(seconds: 1))
        #expect(!detector.hasShortPause)
        detector.ingest(PCMFixture.speech(seconds: 1))
        detector.ingest(PCMFixture.silence(seconds: 0.12))
        #expect(!detector.hasShortPause)
        detector.ingest(PCMFixture.silence(seconds: 0.08))
        #expect(detector.hasShortPause)
        #expect(!detector.hasPause)
        detector.ingest(PCMFixture.speech(seconds: 0.1))
        #expect(!detector.hasShortPause)
    }

    @Test("After a commit, a gap needs new speech before it is a short pause")
    func shortPauseAfterCommit() {
        var detector = PauseDetector(pauseDuration: 0.5)
        detector.ingest(PCMFixture.speech(seconds: 1) + PCMFixture.silence(seconds: 0.2))
        #expect(detector.hasShortPause)
        detector.didCommit()
        detector.ingest(PCMFixture.silence(seconds: 0.3))
        #expect(!detector.hasShortPause)
    }

    @Test("After a commit, continued silence does not end another turn")
    func commitStartsNewTurn() {
        var detector = PauseDetector(pauseDuration: 0.5)
        _ = detector.ingest(PCMFixture.speech(seconds: 1))
        let paused = detector.ingest(PCMFixture.silence(seconds: 0.6))
        #expect(paused)
        detector.didCommit()
        let later = chunks(PCMFixture.silence(seconds: 1)).map { detector.ingest($0) }
        #expect(later.allSatisfy { !$0 })
    }
}
