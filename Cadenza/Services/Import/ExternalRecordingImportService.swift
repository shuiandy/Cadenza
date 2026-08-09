import Foundation

actor ExternalRecordingImportService {
    static let maxPreviewBatch = 100
    static let maxChunkBytes = 192 * 1024
    static let maxTranscriptBytes = 20 * 1024 * 1024
    static let maxChunks = 256
    static let maxActiveUploads = 16
    static let maxStagedBytes = 64 * 1024 * 1024
    static let uploadLifetime: TimeInterval = 30 * 60

    private struct StagedUpload: Sendable {
        let totalChunks: Int
        let transcriptSHA256: String?
        let createdAt: Date
        var lastUpdatedAt: Date
        var chunks: [Int: String]

        var receivedBytes: Int {
            chunks.values.reduce(0) { $0 + $1.utf8.count }
        }
    }

    private enum TranscriptResolutionError: Error, LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message): message
            }
        }
    }

    private let store: RecordingsStore
    private var stagedUploads: [UUID: StagedUpload] = [:]

    init(store: RecordingsStore) {
        self.store = store
    }

    func preview(_ inputs: [ExternalRecordingPreviewInput]) async -> [ExternalRecordingPreviewResult] {
        let bounded = inputs.prefix(Self.maxPreviewBatch)
        var results: [ExternalRecordingPreviewResult] = []
        results.reserveCapacity(bounded.count)
        for input in bounded {
            results.append(await store.previewExternalRecording(input))
        }
        return results
    }

    func setDisposition(
        previewInput: ExternalRecordingPreviewInput,
        disposition: ExternalImportDisposition,
        reason: String?
    ) async -> ExternalImportDispositionResult {
        await store.setExternalImportDisposition(
            previewInput: previewInput,
            disposition: disposition,
            reason: reason
        )
    }

    func stageTranscriptChunk(
        _ input: ExternalTranscriptChunkInput,
        now: Date = Date()
    ) -> ExternalTranscriptChunkResult {
        removeExpiredUploads(now: now)
        guard (1...Self.maxChunks).contains(input.totalChunks),
              input.index >= 0,
              input.index < input.totalChunks else {
            return chunkResult(.rejected, input: input, upload: stagedUploads[input.uploadID],
                               reason: "Chunk index or totalChunks is outside the allowed range.")
        }
        let chunkData = Data(input.text.utf8)
        guard chunkData.count <= Self.maxChunkBytes else {
            return chunkResult(.rejected, input: input, upload: stagedUploads[input.uploadID],
                               reason: "Chunk exceeds \(Self.maxChunkBytes) UTF-8 bytes.")
        }
        if let expected = normalizedSHA256(input.chunkSHA256),
           ExternalRecordingFingerprint.data(chunkData) != expected {
            return chunkResult(.rejected, input: input, upload: stagedUploads[input.uploadID],
                               reason: "Chunk SHA-256 does not match its content.")
        }
        if input.chunkSHA256 != nil, normalizedSHA256(input.chunkSHA256) == nil {
            return chunkResult(.rejected, input: input, upload: stagedUploads[input.uploadID],
                               reason: "chunkSHA256 must contain 64 hexadecimal characters.")
        }
        let expectedTranscriptHash = normalizedSHA256(input.transcriptSHA256)
        if input.transcriptSHA256 != nil, expectedTranscriptHash == nil {
            return chunkResult(.rejected, input: input, upload: stagedUploads[input.uploadID],
                               reason: "transcriptSHA256 must contain 64 hexadecimal characters.")
        }

        let existingUpload = stagedUploads[input.uploadID]
        guard existingUpload != nil || stagedUploads.count < Self.maxActiveUploads else {
            return chunkResult(.rejected, input: input, upload: nil,
                               reason: "Too many active transcript uploads. Retry after an upload completes or expires.")
        }
        var upload = existingUpload ?? StagedUpload(
            totalChunks: input.totalChunks,
            transcriptSHA256: expectedTranscriptHash,
            createdAt: now,
            lastUpdatedAt: now,
            chunks: [:]
        )
        guard upload.totalChunks == input.totalChunks,
              upload.transcriptSHA256 == expectedTranscriptHash else {
            return chunkResult(.rejected, input: input, upload: upload,
                               reason: "Upload metadata changed for an existing upload id.")
        }
        if let existing = upload.chunks[input.index] {
            let status: ExternalTranscriptChunkStatus = existing == input.text ? .alreadyStaged : .rejected
            let reason = existing == input.text ? nil : "This chunk index was already staged with different content."
            return chunkResult(status, input: input, upload: upload, reason: reason)
        }
        guard upload.receivedBytes + chunkData.count <= Self.maxTranscriptBytes else {
            return chunkResult(.rejected, input: input, upload: upload,
                               reason: "Staged transcript exceeds \(Self.maxTranscriptBytes) UTF-8 bytes.")
        }
        let totalStagedBytes = stagedUploads.values.reduce(0) { $0 + $1.receivedBytes }
        guard totalStagedBytes + chunkData.count <= Self.maxStagedBytes else {
            return chunkResult(.rejected, input: input, upload: upload,
                               reason: "All staged transcripts together exceed the allowed memory budget.")
        }
        upload.chunks[input.index] = input.text
        upload.lastUpdatedAt = now
        stagedUploads[input.uploadID] = upload
        let status: ExternalTranscriptChunkStatus = upload.chunks.count == upload.totalChunks ? .complete : .staged
        return chunkResult(status, input: input, upload: upload, reason: nil)
    }

    func upsert(
        _ input: ExternalRecordingUpsertInput,
        transcriptUploadID: UUID? = nil
    ) async -> ExternalRecordingUpsertResult {
        var resolvedInput = input
        if let transcriptUploadID {
            switch completeTranscript(uploadID: transcriptUploadID, now: Date()) {
            case .success(let fullText):
                resolvedInput.transcript = ExternalTranscriptInput(
                    fullText: fullText,
                    segments: [],
                    detectedLanguage: resolvedInput.transcript?.detectedLanguage ?? resolvedInput.language
                )
            case .failure(let error):
                return ExternalRecordingUpsertResult(
                    status: .incompleteUpload,
                    externalKey: (try? ExternalRecordingIdentity.make(
                        provider: input.provider,
                        externalID: input.externalID
                    ))?.externalKey,
                    recordingID: nil,
                    reason: error.localizedDescription,
                    qualitySignals: []
                )
            }
        }

        let result = await store.upsertExternalRecording(resolvedInput)
        if let transcriptUploadID,
           [.imported, .updated, .unchanged].contains(result.status) {
            stagedUploads.removeValue(forKey: transcriptUploadID)
        }
        return result
    }

    private func completeTranscript(
        uploadID: UUID,
        now: Date
    ) -> Result<String, TranscriptResolutionError> {
        removeExpiredUploads(now: now)
        guard let upload = stagedUploads[uploadID] else {
            return .failure(.message("Transcript upload was not found or expired."))
        }
        guard upload.chunks.count == upload.totalChunks else {
            return .failure(.message("Transcript upload is incomplete: received \(upload.chunks.count) of \(upload.totalChunks) chunks."))
        }
        var fullText = ""
        fullText.reserveCapacity(upload.receivedBytes)
        for index in 0..<upload.totalChunks {
            guard let chunk = upload.chunks[index] else {
                return .failure(.message("Transcript upload is missing chunk \(index)."))
            }
            fullText.append(chunk)
        }
        let data = Data(fullText.utf8)
        guard data.count <= Self.maxTranscriptBytes else {
            return .failure(.message("Transcript exceeds the maximum staged size."))
        }
        if let expected = upload.transcriptSHA256,
           ExternalRecordingFingerprint.data(data) != expected {
            return .failure(.message("Transcript SHA-256 does not match the assembled chunks."))
        }
        return .success(fullText)
    }

    private func removeExpiredUploads(now: Date) {
        stagedUploads = stagedUploads.filter {
            now.timeIntervalSince($0.value.lastUpdatedAt) <= Self.uploadLifetime
        }
    }

    private func normalizedSHA256(_ value: String?) -> String? {
        ExternalRecordingFingerprint.normalizedSHA256(value)
    }

    private func chunkResult(
        _ status: ExternalTranscriptChunkStatus,
        input: ExternalTranscriptChunkInput,
        upload: StagedUpload?,
        reason: String?
    ) -> ExternalTranscriptChunkResult {
        ExternalTranscriptChunkResult(
            status: status,
            uploadID: input.uploadID,
            receivedChunks: upload?.chunks.count ?? 0,
            totalChunks: upload?.totalChunks ?? input.totalChunks,
            receivedBytes: upload?.receivedBytes ?? 0,
            reason: reason
        )
    }
}
