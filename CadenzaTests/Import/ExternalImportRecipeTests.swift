import Testing
@testable import Cadenza

@Suite("External Import Recipe")
struct ExternalImportRecipeTests {
    @Test func promptIsIncrementalPreviewFirstAndCredentialFree() {
        let prompt = ExternalImportRecipe.prompt
        #expect(prompt.contains("cursor pagination"))
        #expect(prompt.contains("updated-after watermark"))
        #expect(prompt.contains("preview_external_recordings"))
        #expect(prompt.contains("Fetch full source-note details only"))
        #expect(prompt.contains("Do not call Cadenza write tools for unchanged or ignored"))
        #expect(prompt.contains("Never include provider credentials"))
        #expect(!prompt.localizedCaseInsensitiveContains("api key"))
    }

    @Test func dryRunKeepsReviewBucketsSeparate() {
        let results = [
            Self.preview(.new), Self.preview(.updated), Self.preview(.unchanged), Self.preview(.ignored),
            Self.preview(.conflict), Self.preview(.possibleDuplicate),
        ]
        let summary = ExternalImportRecipe.summarize(results)
        #expect(summary.newCount == 1)
        #expect(summary.updatedCount == 1)
        #expect(summary.unchangedCount == 1)
        #expect(summary.ignoredCount == 1)
        #expect(summary.conflictCount == 1)
        #expect(summary.possibleDuplicateCount == 1)
        #expect(summary.requiresReviewCount == 2)
    }

    private static func preview(_ status: ExternalImportPreviewStatus) -> ExternalRecordingPreviewResult {
        ExternalRecordingPreviewResult(
            provider: "example",
            externalID: "note-\(status.rawValue)",
            externalKey: "example:note-\(status.rawValue)",
            status: status,
            recordingID: nil,
            matchedRecordingID: nil,
            reason: nil,
            qualitySignals: []
        )
    }
}
