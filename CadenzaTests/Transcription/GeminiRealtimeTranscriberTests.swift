import Foundation
import os
import Testing
@testable import Cadenza

private actor GeminiTransportProbe {
    private(set) var sentPayloads: [Data] = []
    private(set) var receiveRequestCount = 0
    private(set) var cancelCount = 0
    private var sendCompletions: [GeminiRealtimeTransport.SendCompletion] = []
    private var receiveCompletions: [GeminiRealtimeTransport.ReceiveCompletion] = []

    func makeTransport() -> GeminiRealtimeTransport {
        GeminiRealtimeTransport(
            send: { [weak self] data, completion in
                Task { await self?.recordSend(data, completion: completion) }
            },
            receive: { [weak self] maxLength, completion in
                Task { await self?.recordReceive(maxLength: maxLength, completion: completion) }
            },
            cancel: { [weak self] in
                Task { await self?.recordCancel() }
            }
        )
    }

    func completeSend(at index: Int, error: Error? = nil) {
        guard sendCompletions.indices.contains(index) else { return }
        sendCompletions[index](error)
    }

    func completeReceive(at index: Int, data: Data? = nil, error: Error? = nil) {
        guard receiveCompletions.indices.contains(index) else { return }
        receiveCompletions[index](data, error)
    }

    private func recordSend(_ data: Data, completion: @escaping GeminiRealtimeTransport.SendCompletion) {
        sentPayloads.append(data)
        sendCompletions.append(completion)
    }

    private func recordReceive(
        maxLength: Int,
        completion: @escaping GeminiRealtimeTransport.ReceiveCompletion
    ) {
        _ = maxLength
        receiveRequestCount += 1
        receiveCompletions.append(completion)
    }

    private func recordCancel() {
        cancelCount += 1
    }
}

private actor GeminiOperationProbe {
    private(set) var isComplete = false
    private(set) var error: Error?

    func complete(error: Error?) {
        guard !isComplete else { return }
        isComplete = true
        self.error = error
    }
}

private actor GeminiDeltaProbe {
    private(set) var delta: TranscriptDelta?
    private(set) var error: Error?

    var isComplete: Bool {
        delta != nil || error != nil
    }

    func complete(delta: TranscriptDelta) {
        guard !isComplete else { return }
        self.delta = delta
    }

    func complete(error: Error) {
        guard !isComplete else { return }
        self.error = error
    }
}

private enum GeminiLateStartupFailure: Error, Sendable {
    case failed
}

private actor GeminiStartupSequenceProbe {
    private var invocationCount = 0
    private var firstContinuation: CheckedContinuation<Void, Error>?

    var isFirstWaiting: Bool {
        firstContinuation != nil
    }

    func run() async throws {
        invocationCount += 1
        guard invocationCount == 1 else { return }
        try await withCheckedThrowingContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func failFirst() {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume(throwing: GeminiLateStartupFailure.failed)
    }

    func succeedFirst() {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume(returning: ())
    }
}

private actor GeminiTokenStartupProbe {
    private(set) var isWaiting = false

    func token() async throws -> String {
        isWaiting = true
        defer { isWaiting = false }
        try await Task.sleep(for: .seconds(3_600))
        return "auth_tokens/late"
    }
}

private final class GeminiTransportFactoryProbe: Sendable {
    private let transports: OSAllocatedUnfairLock<[GeminiRealtimeTransport]>

    init(_ transports: [GeminiRealtimeTransport]) {
        self.transports = OSAllocatedUnfairLock(initialState: transports)
    }

    func next() -> GeminiRealtimeTransport {
        transports.withLock { transports in
            precondition(!transports.isEmpty, "No Gemini test transport configured")
            return transports.removeFirst()
        }
    }
}

@Suite("Gemini realtime cancellation and teardown", .serialized)
struct GeminiRealtimeTranscriberTests {
    private func waitUntil(
        timeout: Duration = .milliseconds(300),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func serverFrame(
        opcode: UInt8,
        isFinal: Bool,
        payload: Data
    ) -> Data {
        precondition(payload.count < 126)
        return Data([
            (isFinal ? 0x80 : 0x00) | opcode,
            UInt8(payload.count),
        ]) + payload
    }

    private func serverFrameHeader(
        opcode: UInt8,
        isFinal: Bool,
        declaredPayloadLength: UInt64
    ) -> Data {
        var data = Data([
            (isFinal ? 0x80 : 0x00) | opcode,
            127,
        ])
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((declaredPayloadLength >> UInt64(shift)) & 0xFF))
        }
        return data
    }

    @Test func audioInputMimeTypeDeclaresTheCaptureSampleRate() throws {
        // Capture converts to AudioConverter.transcriptionFormat before handing
        // PCM to sendAudio. Gemini resamples from the declared rate, so a
        // declaration that drifts from the capture format changes playback
        // speed on the server side. Lock the two together.
        let message = GeminiRealtimeTranscriber.audioInputMessage(base64Audio: "AAAA")
        let realtimeInput = try #require(message["realtimeInput"] as? [String: Any])
        let audio = try #require(realtimeInput["audio"] as? [String: Any])
        let captureRate = Int(AudioConverter.transcriptionFormat.sampleRate)
        #expect(audio["mimeType"] as? String == "audio/pcm;rate=\(captureRate)")
        #expect(audio["mimeType"] as? String == "audio/pcm;rate=24000")
        #expect(audio["data"] as? String == "AAAA")
    }

    @Test func upgradeHeaderAccumulatorPreservesCoalescedFrameBytes() throws {
        var accumulator = GeminiRealtimeUpgradeHeaderAccumulator()
        #expect(
            try accumulator.append(Data("HTTP/1.1 101 Switching Protocols\r\nUpg".utf8)) == nil
        )

        let completedHeader = try accumulator.append(
            Data("rade: websocket\r\n\r\n".utf8) + Data([0x81, 0x00])
        )
        let result = try #require(completedHeader)

        #expect(String(data: result.header, encoding: .utf8)?.hasPrefix("HTTP/1.1 101") == true)
        #expect(result.remainder == Data([0x81, 0x00]))
    }

    @Test func upgradeHeaderAccumulatorRejectsMissingTerminatorAtLimit() {
        var accumulator = GeminiRealtimeUpgradeHeaderAccumulator()
        let oversized = Data(
            repeating: 0x41,
            count: GeminiRealtimeUpgradeHeaderAccumulator.maximumHeaderBytes
        )

        #expect(throws: GeminiWebSocketProtocolError.self) {
            _ = try accumulator.append(oversized)
        }
    }

    @Test(arguments: [
        UInt64(GeminiWebSocketFrameHeader.maximumPayloadBytes) + 1,
        UInt64.max,
    ])
    func frameHeaderRejectsOversizedLengthBeforeIntegerConversion(_ length: UInt64) {
        let header = serverFrameHeader(
            opcode: 0x01,
            isFinal: true,
            declaredPayloadLength: length
        )

        #expect(throws: GeminiWebSocketProtocolError.self) {
            _ = try GeminiWebSocketFrameHeader.parse(from: header)
        }
    }

    @Test func frameHeaderEnforcesControlFrameRules() {
        #expect(throws: GeminiWebSocketProtocolError.self) {
            _ = try GeminiWebSocketFrameHeader.parse(
                from: serverFrame(opcode: 0x09, isFinal: false, payload: Data())
            )
        }

        let oversizedPing = Data([0x89, 126, 0, 126])
        #expect(throws: GeminiWebSocketProtocolError.self) {
            _ = try GeminiWebSocketFrameHeader.parse(from: oversizedPing)
        }
    }

    @Test func oversizedDeclaredFrameTerminatesSessionBeforePayloadRead() async throws {
        let transport = GeminiTransportProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "fake",
            model: "test",
            transportForTesting: await transport.makeTransport()
        )
        let stream = try await service.startRealtimeSession(language: nil)
        let result = GeminiDeltaProbe()
        let consumer = Task {
            do {
                for try await delta in stream {
                    await result.complete(delta: delta)
                }
            } catch {
                await result.complete(error: error)
            }
        }

        let oversizedHeader = serverFrameHeader(
            opcode: 0x01,
            isFinal: true,
            declaredPayloadLength: UInt64(GeminiWebSocketFrameHeader.maximumPayloadBytes) + 1
        )
        #expect(await waitUntil { await transport.receiveRequestCount == 1 })
        await transport.completeReceive(at: 0, data: oversizedHeader)

        #expect(await waitUntil { await result.isComplete })
        #expect(await result.error is GeminiWebSocketProtocolError)
        #expect(await transport.receiveRequestCount == 1)
        #expect(await waitUntil { await transport.cancelCount == 1 })
        await consumer.value
    }

    @Test func fragmentedTextMessageSurvivesInterleavedPing() async throws {
        let transport = GeminiTransportProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "fake",
            model: "test",
            transportForTesting: await transport.makeTransport()
        )
        let stream = try await service.startRealtimeSession(language: "en")
        let result = GeminiDeltaProbe()
        let consumer = Task {
            do {
                for try await delta in stream {
                    await result.complete(delta: delta)
                    return
                }
            } catch {
                await result.complete(error: error)
            }
        }

        let message = Data(
            #"{"serverContent":{"inputTranscription":{"text":"fragmented hello"},"turnComplete":true}}"#.utf8
        )
        let splitIndex = message.count / 2
        let firstFragment = serverFrame(
            opcode: 0x01,
            isFinal: false,
            payload: Data(message[..<splitIndex])
        )
        let continuation = serverFrame(
            opcode: 0x00,
            isFinal: true,
            payload: Data(message[splitIndex...])
        )
        let ping = serverFrame(
            opcode: 0x09,
            isFinal: true,
            payload: Data("p".utf8)
        )

        #expect(await waitUntil { await transport.receiveRequestCount == 1 })
        await transport.completeReceive(at: 0, data: firstFragment)
        #expect(await waitUntil { await transport.receiveRequestCount == 2 })
        await transport.completeReceive(at: 1, data: ping)
        #expect(await waitUntil { await transport.sentPayloads.count == 1 })
        await transport.completeSend(at: 0)
        #expect(await waitUntil { await transport.receiveRequestCount == 3 })
        await transport.completeReceive(at: 2, data: continuation)

        #expect(await waitUntil { await result.isComplete })
        #expect(await result.error == nil)
        #expect(await result.delta?.text == "fragmented hello")
        #expect(await result.delta?.isFinal == true)

        try await service.stopRealtimeSession()
        await consumer.value
    }

    @Test func providerErrorCannotEchoEphemeralToken() async throws {
        RealtimeDebugLog.shared.clear()
        let secret = "auth_tokens/provider-echo-secret"
        let transport = GeminiTransportProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "long-lived-secret",
            model: "test",
            transportForTesting: await transport.makeTransport(),
            tokenOperationForTesting: { secret }
        )
        let stream = try await service.startRealtimeSession(language: nil)
        let result = GeminiDeltaProbe()
        let consumer = Task {
            do {
                for try await delta in stream {
                    await result.complete(delta: delta)
                }
            } catch {
                await result.complete(error: error)
            }
        }
        let errorMessage = Data(
            #"{"error":{"message":"authentication failed for auth_tokens/provider-echo-secret"}}"#.utf8
        )

        #expect(await waitUntil { await transport.receiveRequestCount == 1 })
        await transport.completeReceive(
            at: 0,
            data: serverFrame(opcode: 0x01, isFinal: true, payload: errorMessage)
        )

        #expect(await waitUntil { await result.isComplete })
        let description = await result.error?.localizedDescription ?? ""
        #expect(description.contains(secret) == false)
        #expect(RealtimeDebugLog.shared.entries.allSatisfy { !$0.contains(secret) })

        try await service.stopRealtimeSession()
        await consumer.value
    }

    @Test func transcriptContentIsNotCopiedIntoDebugLog() async throws {
        RealtimeDebugLog.shared.clear()
        let transcript = "auth_tokens/spoken-or-echoed-secret"
        let transport = GeminiTransportProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "fake",
            model: "test",
            transportForTesting: await transport.makeTransport()
        )
        let stream = try await service.startRealtimeSession(language: nil)
        let result = GeminiDeltaProbe()
        let consumer = Task {
            do {
                for try await delta in stream {
                    await result.complete(delta: delta)
                    return
                }
            } catch {
                await result.complete(error: error)
            }
        }
        let message = Data(
            #"{"serverContent":{"inputTranscription":{"text":"auth_tokens/spoken-or-echoed-secret"}}}"#.utf8
        )

        #expect(await waitUntil { await transport.receiveRequestCount == 1 })
        await transport.completeReceive(
            at: 0,
            data: serverFrame(opcode: 0x01, isFinal: true, payload: message)
        )

        #expect(await waitUntil { await result.isComplete })
        #expect(await result.delta?.text == transcript)
        #expect(RealtimeDebugLog.shared.entries.allSatisfy { !$0.contains(transcript) })

        try await service.stopRealtimeSession()
        await consumer.value
    }

    @Test func upgradeRequestUsesCredentialFreeConstrainedPathAndAuthorizationHeader() throws {
        let requestData = try GeminiRealtimeHandshake.makeUpgradeRequest(
            token: "auth_tokens/ephemeral-one",
            webSocketKey: "dGhlIHNhbXBsZSBub25jZQ=="
        )
        let request = try #require(String(data: requestData, encoding: .utf8))

        #expect(
            request.hasPrefix(
                "GET /ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained HTTP/1.1\r\n"
            )
        )
        #expect(request.contains("Authorization: Token auth_tokens/ephemeral-one\r\n"))
        #expect(request.contains("?key=") == false)
        #expect(request.contains("x-goog-api-key") == false)
        #expect(request.hasSuffix("\r\n\r\n"))
    }

    @Test func redirectUpgradeResponseIsRejectedWithoutRedirectTarget() {
        let response = Data(
            "HTTP/1.1 307 Temporary Redirect\r\nLocation: https://redirect.example/\r\n\r\n".utf8
        )

        #expect(throws: Error.self) {
            try GeminiRealtimeHandshake.validateUpgradeResponseHeader(
                response,
                webSocketKey: "dGhlIHNhbXBsZSBub25jZQ=="
            )
        }
    }

    @Test func upgradeResponseMustAuthenticateTheWebSocketKey() throws {
        let validResponse = Data(
            """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r
            \r

            """.utf8
        )

        try GeminiRealtimeHandshake.validateUpgradeResponseHeader(
            validResponse,
            webSocketKey: "dGhlIHNhbXBsZSBub25jZQ=="
        )

        let mismatchedResponse = Data(
            """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: attacker-controlled\r
            \r

            """.utf8
        )
        #expect(throws: GeminiRealtimeHandshakeError.self) {
            try GeminiRealtimeHandshake.validateUpgradeResponseHeader(
                mismatchedResponse,
                webSocketKey: "dGhlIHNhbXBsZSBub25jZQ=="
            )
        }
    }

    @Test func setupAcknowledgementMustBeExplicitAndContentFree() throws {
        try GeminiRealtimeHandshake.validateSetupAcknowledgement(
            #"{"setupComplete":{}}"#
        )

        #expect(throws: GeminiRealtimeHandshakeError.self) {
            try GeminiRealtimeHandshake.validateSetupAcknowledgement(
                #"{"serverContent":{"inputTranscription":{"text":"too early"}}}"#
            )
        }
        #expect(throws: GeminiRealtimeHandshakeError.self) {
            try GeminiRealtimeHandshake.validateSetupAcknowledgement(
                #"{"setupComplete":{},"serverContent":{"turnComplete":false}}"#
            )
        }

        let secret = "auth_tokens/setup-error-secret"
        do {
            try GeminiRealtimeHandshake.validateSetupAcknowledgement(
                #"{"error":{"message":"failed for auth_tokens/setup-error-secret"}}"#
            )
            Issue.record("expected setup acknowledgement failure")
        } catch {
            #expect(error.localizedDescription.contains(secret) == false)
        }
    }

    @Test(arguments: [
        "",
        "long-lived-key",
        "auth_tokens/",
        "auth_tokens/token\r\nInjected: yes",
    ])
    func unsafeEphemeralTokenCannotEnterUpgradeHeader(_ token: String) {
        #expect(throws: Error.self) {
            _ = try GeminiRealtimeHandshake.makeUpgradeRequest(
                token: token,
                webSocketKey: "dGhlIHNhbXBsZSBub25jZQ=="
            )
        }
    }

    @Test(arguments: [
        "",
        "models/gemini-3.1-flash-live-preview",
        "../gemini-3.1-flash-live-preview",
        "gemini-live?key=secret",
        "gemini-" + String(repeating: "x", count: 257),
    ])
    func invalidRealtimeModelFailsBeforeInjectedStartup(_ model: String) async throws {
        let transport = GeminiTransportProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "fake",
            model: model,
            transportForTesting: await transport.makeTransport()
        )

        await #expect(throws: Error.self) {
            _ = try await service.startRealtimeSession(language: "en")
        }
        #expect(await transport.receiveRequestCount == 0)
        #expect(await transport.cancelCount == 0)
    }

    @Test func aggregateStartupDeadlineCancelsExactAttemptAndAllowsReplacement() async throws {
        let transportA = GeminiTransportProbe()
        let transportB = GeminiTransportProbe()
        let factory = GeminiTransportFactoryProbe([
            await transportA.makeTransport(),
            await transportB.makeTransport(),
        ])
        let startup = GeminiStartupSequenceProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "fake",
            model: "gemini-3.1-flash-live-preview",
            transportFactoryForTesting: { factory.next() },
            startupOperationForTesting: { try await startup.run() },
            startupDeadline: .milliseconds(30)
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        await #expect(throws: HardAsyncDeadlineExceeded.self) {
            _ = try await HardAsyncDeadline.run(for: .milliseconds(180)) {
                try await service.startRealtimeSession(language: "en")
            }
        }
        let elapsed = startedAt.duration(to: clock.now)

        #expect(elapsed < .milliseconds(140))
        #expect(await waitUntil { await transportA.cancelCount == 1 })

        _ = try await service.startRealtimeSession(language: "en")
        #expect(await waitUntil { await transportB.receiveRequestCount == 1 })

        await startup.succeedFirst()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await transportB.cancelCount == 0)
        #expect(await service._testHasActiveTransport)

        try await service.stopRealtimeSession()
        #expect(await waitUntil { await transportB.cancelCount == 1 })
    }

    @Test func callerCancellationEndsNonCooperativeStartupAndCancelsTransport() async throws {
        let transport = GeminiTransportProbe()
        let startup = GeminiStartupSequenceProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "fake",
            model: "gemini-3.1-flash-live-preview",
            transportForTesting: await transport.makeTransport(),
            startupOperationForTesting: { try await startup.run() },
            startupDeadline: .seconds(1)
        )
        let completion = GeminiOperationProbe()
        let startTask = Task {
            do {
                _ = try await service.startRealtimeSession(language: "en")
                await completion.complete(error: nil)
            } catch {
                await completion.complete(error: error)
            }
        }
        #expect(await waitUntil { await startup.isFirstWaiting })

        startTask.cancel()
        #expect(await waitUntil(timeout: .milliseconds(120)) { await completion.isComplete })
        #expect(await completion.error is CancellationError)
        #expect(await waitUntil { await transport.cancelCount == 1 })

        await startup.succeedFirst()
        await startTask.value
    }

    @Test func tokenProvisioningParticipatesInAggregateStartupDeadline() async throws {
        let transport = GeminiTransportProbe()
        let tokenProbe = GeminiTokenStartupProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "fake",
            model: "gemini-3.1-flash-live-preview",
            transportForTesting: await transport.makeTransport(),
            tokenOperationForTesting: { try await tokenProbe.token() },
            startupDeadline: .milliseconds(30)
        )

        await #expect(throws: HardAsyncDeadlineExceeded.self) {
            _ = try await service.startRealtimeSession(language: "en")
        }
        #expect(await waitUntil { await transport.cancelCount == 1 })
        #expect(await waitUntil { await tokenProbe.isWaiting == false })
    }

    @Test func tokenProvisioningFailureCannotExposeCredentialText() async throws {
        let secret = "long-lived-or-ephemeral-secret"
        let transport = GeminiTransportProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "fake",
            model: "test",
            transportForTesting: await transport.makeTransport(),
            tokenOperationForTesting: {
                throw NSError(
                    domain: "GeminiTokenTest",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "failed with \(secret)"]
                )
            }
        )

        do {
            _ = try await service.startRealtimeSession(language: nil)
            Issue.record("expected token provisioning failure")
        } catch {
            #expect(error.localizedDescription.contains(secret) == false)
        }
        #expect(await waitUntil { await transport.cancelCount == 1 })
    }

    @Test func audioStreamEndDeadlineCancelsOnlyExactSessionAndIgnoresLateCallback() async throws {
        let transportA = GeminiTransportProbe()
        let transportB = GeminiTransportProbe()
        let serviceA = GeminiRealtimeTranscriber(
            apiKey: "fake-a",
            model: "test",
            transportForTesting: await transportA.makeTransport(),
            audioStreamEndTimeout: .milliseconds(30)
        )
        let serviceB = GeminiRealtimeTranscriber(
            apiKey: "fake-b",
            model: "test",
            transportForTesting: await transportB.makeTransport(),
            audioStreamEndTimeout: .milliseconds(30)
        )
        _ = try await serviceA.startRealtimeSession(language: "en")
        _ = try await serviceB.startRealtimeSession(language: "en")

        let flushProbe = GeminiOperationProbe()
        let flushTask = Task {
            do {
                try await serviceA.sendAudioStreamEnd()
                await flushProbe.complete(error: nil)
            } catch {
                await flushProbe.complete(error: error)
            }
        }
        #expect(await waitUntil { await transportA.sentPayloads.count == 1 })

        let completedBeforeRawCallback = await waitUntil(timeout: .milliseconds(120)) {
            await flushProbe.isComplete
        }
        #expect(completedBeforeRawCallback)
        #expect(await flushProbe.error != nil)
        #expect(await waitUntil { await transportA.cancelCount == 1 })
        #expect(await transportB.cancelCount == 0)

        // The network stack may report completion after our deadline won. This
        // callback must be ignored rather than resuming the continuation twice.
        await transportA.completeSend(at: 0)
        await flushTask.value

        let sendB = Task { try await serviceB.sendAudio(Data([0xB0])) }
        #expect(await waitUntil { await transportB.sentPayloads.count == 1 })
        await transportB.completeSend(at: 0)
        try await sendB.value
        #expect(await transportB.cancelCount == 0)

        try await serviceA.stopRealtimeSession()
        try await serviceB.stopRealtimeSession()
    }

    @Test func lateStartupFailureFromStoppedSessionCannotTearDownReplacementSession() async throws {
        let transportA = GeminiTransportProbe()
        let transportB = GeminiTransportProbe()
        let factory = GeminiTransportFactoryProbe([
            await transportA.makeTransport(),
            await transportB.makeTransport(),
        ])
        let startup = GeminiStartupSequenceProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "fake",
            model: "test",
            transportFactoryForTesting: { factory.next() },
            startupOperationForTesting: { try await startup.run() }
        )

        let startA = Task {
            try await service.startRealtimeSession(language: "en")
        }
        #expect(await waitUntil { await startup.isFirstWaiting })

        try await service.stopRealtimeSession()
        #expect(await waitUntil { await transportA.cancelCount == 1 })

        _ = try await service.startRealtimeSession(language: "en")
        #expect(await waitUntil { await transportB.receiveRequestCount == 1 })

        await startup.failFirst()
        await #expect(throws: GeminiLateStartupFailure.self) {
            try await startA.value
        }

        #expect(await service._testHasActiveTransport)
        #expect(await service._testHasReceiveTask)
        #expect(await transportA.cancelCount == 1)
        #expect(await transportB.cancelCount == 0)

        let sendB = Task { try await service.sendAudio(Data([0xB0])) }
        #expect(await waitUntil { await transportB.sentPayloads.count == 1 })
        await transportB.completeSend(at: 0)
        try await sendB.value

        try await service.stopRealtimeSession()
        #expect(await waitUntil { await transportB.cancelCount == 1 })
    }

    @Test func immediateCallerCancellationResolvesSendWithoutRawCallback() async throws {
        let transportA = GeminiTransportProbe()
        let transportB = GeminiTransportProbe()
        let serviceA = GeminiRealtimeTranscriber(
            apiKey: "fake-a",
            model: "test",
            transportForTesting: await transportA.makeTransport(),
            audioStreamEndTimeout: .seconds(1)
        )
        let serviceB = GeminiRealtimeTranscriber(
            apiKey: "fake-b",
            model: "test",
            transportForTesting: await transportB.makeTransport(),
            audioStreamEndTimeout: .seconds(1)
        )
        _ = try await serviceA.startRealtimeSession(language: nil)
        _ = try await serviceB.startRealtimeSession(language: nil)

        let completion = GeminiOperationProbe()
        let sendTask = Task {
            do {
                try await serviceA.sendAudioStreamEnd()
                await completion.complete(error: nil)
            } catch {
                await completion.complete(error: error)
            }
        }
        sendTask.cancel()

        #expect(await waitUntil(timeout: .milliseconds(120)) { await completion.isComplete })
        #expect(await completion.error is CancellationError)
        #expect(await waitUntil { await transportA.cancelCount == 1 })
        #expect(await transportB.cancelCount == 0)

        if await transportA.sentPayloads.count > 0 {
            await transportA.completeSend(at: 0)
        }
        await sendTask.value
        try await serviceA.stopRealtimeSession()
        try await serviceB.stopRealtimeSession()
    }

    @Test func stopFinishesStreamAndCancelsReceiveWithoutAwaitingCloseFrame() async throws {
        let transport = GeminiTransportProbe()
        let service = GeminiRealtimeTranscriber(
            apiKey: "fake",
            model: "test",
            transportForTesting: await transport.makeTransport(),
            audioStreamEndTimeout: .milliseconds(30)
        )
        let stream = try await service.startRealtimeSession(language: "en")
        let streamEnded = GeminiOperationProbe()
        let consumer = Task {
            do {
                for try await _ in stream {}
                await streamEnded.complete(error: nil)
            } catch {
                await streamEnded.complete(error: error)
            }
        }
        #expect(await waitUntil { await transport.receiveRequestCount == 1 })

        let stopCompleted = GeminiOperationProbe()
        let stopTask = Task {
            do {
                try await service.stopRealtimeSession()
                await stopCompleted.complete(error: nil)
            } catch {
                await stopCompleted.complete(error: error)
            }
        }

        let returnedWithoutCloseCallback = await waitUntil(timeout: .milliseconds(100)) {
            await stopCompleted.isComplete
        }
        #expect(returnedWithoutCloseCallback)
        #expect(await transport.sentPayloads.isEmpty)
        #expect(await waitUntil { await transport.cancelCount == 1 })
        #expect(await waitUntil { await streamEnded.isComplete })
        #expect(await service._testHasActiveTransport == false)
        #expect(await service._testHasReceiveTask == false)

        // Clean up the pre-fix behavior after recording the RED assertions.
        if await transport.sentPayloads.count > 0 {
            await transport.completeSend(at: 0)
        }
        await stopTask.value

        // A receive callback may arrive after task cancellation/connection close.
        // It must not resume its continuation twice or recreate session state.
        await transport.completeReceive(at: 0, data: Data([0x81, 0x00]))
        try? await Task.sleep(for: .milliseconds(20))
        try await service.stopRealtimeSession()
        #expect(await transport.cancelCount == 1)
        #expect(await service._testHasActiveTransport == false)
        #expect(await service._testHasReceiveTask == false)
        await consumer.value
    }

    @MainActor
    @Test func managerFlushDeadlineClosesExactOldServiceWithoutAffectingReplacement() async throws {
        let transportA = GeminiTransportProbe()
        let transportB = GeminiTransportProbe()
        let serviceA = GeminiRealtimeTranscriber(
            apiKey: "fake-a",
            model: "test",
            transportForTesting: await transportA.makeTransport(),
            audioStreamEndTimeout: .milliseconds(30)
        )
        let serviceB = GeminiRealtimeTranscriber(
            apiKey: "fake-b",
            model: "test",
            transportForTesting: await transportB.makeTransport(),
            audioStreamEndTimeout: .milliseconds(30)
        )
        let services: [any TranscriptionService] = [serviceA, serviceB]
        var serviceIndex = 0
        let manager = TranscriptionManager(realtimeServiceFactory: { _, _, _, _ in
            guard services.indices.contains(serviceIndex) else {
                throw TranscriptionError.notSupported("No test service configured")
            }
            defer { serviceIndex += 1 }
            return services[serviceIndex]
        })

        try await manager.startRealtime(provider: .gemini, apiKey: "fake-a")
        let oldHandle = manager.beginRealtimeStop()
        try await manager.startRealtime(provider: .gemini, apiKey: "fake-b")
        let replacementAttemptID = try #require(manager.currentRealtimeAttemptID)

        let clock = ContinuousClock()
        let startedAt = clock.now
        await manager.finishRealtimeStop(oldHandle)
        let elapsed = startedAt.duration(to: clock.now)

        #expect(elapsed < .milliseconds(800))
        #expect(await transportA.cancelCount == 1)
        #expect(await transportB.cancelCount == 0)
        #expect(await serviceA._testHasActiveTransport == false)
        #expect(await serviceA._testHasReceiveTask == false)
        #expect(manager.currentRealtimeAttemptID == replacementAttemptID)
        #expect(manager.realtimeProvider == .gemini)
        #expect(manager.isTranscribing)

        await manager.stopRealtime(abandonStartup: true)
        #expect(await waitUntil { await transportB.cancelCount == 1 })
    }
}

@Suite("Gemini realtime model families")
struct GeminiRealtimeModelFamilyTests {

    private func service(model: String) -> GeminiRealtimeTranscriber {
        GeminiRealtimeTranscriber(apiKey: "fake", model: model)
    }

    private func setupMessage(
        model: String,
        language: String?
    ) async throws -> [String: Any] {
        let config = await service(model: model).buildSetupConfig(language: language)
        return try #require(config["setup"] as? [String: Any])
    }

    // MARK: - Setup message

    @Test func dedicatedTranscriberAsksForTextAndStructuredLanguageHints() async throws {
        let setup = try await setupMessage(model: "gemini-3.5-transcribe-live", language: "zh")

        #expect(setup["model"] as? String == "models/gemini-3.5-transcribe-live")

        let generation = try #require(setup["generationConfig"] as? [String: Any])
        #expect(generation["responseModalities"] as? [String] == ["TEXT"])

        let input = try #require(setup["inputAudioTranscription"] as? [String: Any])
        #expect(input["languageCodes"] as? [String] == ["zh-CN"])

        // An ASR has nothing to instruct and no spoken reply to caption back.
        #expect(setup["systemInstruction"] == nil)
        #expect(setup["outputAudioTranscription"] == nil)
    }

    @Test func autoLanguageLeavesTheHintListEmptyForCodeSwitching() async throws {
        let setup = try await setupMessage(model: "gemini-3.5-transcribe-live", language: nil)
        let input = try #require(setup["inputAudioTranscription"] as? [String: Any])
        #expect((input["languageCodes"] as? [String])?.isEmpty == true)
    }

    @Test func dialogueModelKeepsItsAudioModalityAndPromptWorkaround() async throws {
        let setup = try await setupMessage(model: "gemini-3.1-flash-live-preview", language: nil)
        let generation = try #require(setup["generationConfig"] as? [String: Any])

        #expect(generation["responseModalities"] as? [String] == ["AUDIO"])
        #expect(setup["systemInstruction"] != nil)
        #expect(setup["outputAudioTranscription"] != nil)
    }

    // MARK: - Transcript extraction

    @Test func interimHypothesisIsNotFinalForTheDedicatedTranscriber() async throws {
        let extracted = await service(model: "gemini-3.5-transcribe-live").extractTranscript(
            from: ["interimInputTranscription": ["text": "we should ship"]],
            turnComplete: false
        )
        let transcript = try #require(extracted)
        #expect(transcript.text == "we should ship")
        #expect(transcript.isFinal == false)
    }

    @Test func inputTranscriptionIsAuthoritativeForTheDedicatedTranscriber() async throws {
        // The ASR emits this once the utterance settles, so it is final even
        // though the frame carries no turnComplete.
        let extracted = await service(model: "gemini-3.5-transcribe-live").extractTranscript(
            from: ["inputTranscription": ["text": "we should ship it today"]],
            turnComplete: false
        )
        #expect(try #require(extracted).isFinal)
    }

    @Test func dialogueModelStillDefersFinalityToTurnComplete() async throws {
        let dialogue = service(model: "gemini-3.1-flash-live-preview")

        let running = await dialogue.extractTranscript(
            from: ["inputTranscription": ["text": "we should"]],
            turnComplete: false
        )
        #expect(try #require(running).isFinal == false)

        let done = await dialogue.extractTranscript(
            from: ["inputTranscription": ["text": "we should ship"]],
            turnComplete: true
        )
        #expect(try #require(done).isFinal)
    }

    @Test func dialogueModelIgnoresInterimFramesItWouldOtherwiseAppendTwice() async {
        let extracted = await service(model: "gemini-3.1-flash-live-preview").extractTranscript(
            from: ["interimInputTranscription": ["text": "partial"]],
            turnComplete: false
        )
        #expect(extracted == nil)
    }

    @Test func snakeCaseFramesParseIdentically() async throws {
        let extracted = await service(model: "gemini-3.5-transcribe-live").extractTranscript(
            from: ["interim_input_transcription": ["text": "partial"]],
            turnComplete: false
        )
        let transcript = try #require(extracted)
        #expect(transcript.text == "partial")
        #expect(transcript.isFinal == false)
    }

    @Test func emptyAndAbsentTranscriptsYieldNothing() async {
        let dedicated = service(model: "gemini-3.5-transcribe-live")

        let absent = await dedicated.extractTranscript(from: [:], turnComplete: true)
        #expect(absent == nil)

        let blank = await dedicated.extractTranscript(
            from: ["inputTranscription": ["text": "   "]],
            turnComplete: true
        )
        #expect(blank == nil)
    }
}
