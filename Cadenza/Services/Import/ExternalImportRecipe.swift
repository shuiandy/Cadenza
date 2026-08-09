import Foundation

struct ExternalImportDryRunSummary: Equatable, Sendable {
    let newCount: Int
    let updatedCount: Int
    let unchangedCount: Int
    let ignoredCount: Int
    let conflictCount: Int
    let possibleDuplicateCount: Int

    var requiresReviewCount: Int {
        conflictCount + possibleDuplicateCount
    }
}

enum ExternalImportRecipe {
    static let prompt = """
    Sync meeting notes from an external provider into Cadenza without changing either system until the preview is reviewed.

    1. List source notes with cursor pagination and an updated-after watermark when the provider supports it. Collect only lightweight metadata first.
    2. Send batches of at most 100 metadata records to Cadenza preview_external_recordings with a stable, lowercase provider identifier.
    3. Show a dry-run summary grouped as new, updated, unchanged, ignored, conflict, and possible duplicate. Stop for review if any item is conflict or possible duplicate.
    4. Fetch full source-note details only for preview results marked new or updated. Do not fetch unchanged or ignored notes.
    5. Upsert approved notes with upsert_external_recording. For transcripts too large for one request, upload ordered chunks first and then reference the upload id.
    6. Do not call Cadenza write tools for unchanged or ignored results. Treat their existing Cadenza ledger state as authoritative for this run; a metadata-only upsert could falsely look like a content change.
    7. Report created, updated, unchanged, ignored, conflicted, and possible-duplicate counts. Advance the watermark only after every approved item succeeds.

    Never include provider credentials in Cadenza tool arguments, logs, notes, or saved artifacts.
    """

    static func summarize(_ results: [ExternalRecordingPreviewResult]) -> ExternalImportDryRunSummary {
        var newCount = 0
        var updatedCount = 0
        var unchangedCount = 0
        var ignoredCount = 0
        var conflictCount = 0
        var possibleDuplicateCount = 0

        for result in results {
            switch result.status {
            case .new:
                newCount += 1
            case .updated:
                updatedCount += 1
            case .unchanged:
                unchangedCount += 1
            case .ignored:
                ignoredCount += 1
            case .conflict:
                conflictCount += 1
            case .possibleDuplicate:
                possibleDuplicateCount += 1
            }
        }

        return ExternalImportDryRunSummary(
            newCount: newCount,
            updatedCount: updatedCount,
            unchangedCount: unchangedCount,
            ignoredCount: ignoredCount,
            conflictCount: conflictCount,
            possibleDuplicateCount: possibleDuplicateCount
        )
    }
}
