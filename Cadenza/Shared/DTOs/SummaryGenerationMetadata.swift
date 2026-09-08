import Foundation
import CryptoKit

/// Local provenance only. Remote sync uses its own explicit field whitelist.
struct SummarySourceVersion: Codable, Equatable, Sendable {
    let transcriptID: UUID
    let digest: String
    // Optional for compatibility with summaries saved before the split. Transcript
    // replacements always create a new ID; legacy digests also included mappings.
    var transcriptDigest: String? = nil
    var mappingDigest: String? = nil

    func matchesTranscript(_ current: Self?) -> Bool {
        guard let current, transcriptID == current.transcriptID else { return false }
        guard let transcriptDigest else { return true }
        return transcriptDigest == current.transcriptDigest
    }

    func mappingsDiffer(from current: Self) -> Bool {
        if let mappingDigest { return mappingDigest != current.mappingDigest }
        return digest != current.digest
    }

    static func capture(_ transcript: TranscriptDTO, mappings: [SpeakerLabelMappingDTO]) -> Self {
        // Encode every segment, including its exact timing and identity. Formatting alone
        // rounds timestamps and trims tails, so it is insufficient as a revision token.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let transcriptData = (try? encoder.encode(transcript)) ?? Data()
        let mappedData = Data(SummaryTranscriptFormatter.format(fullText: transcript.fullText,
            segments: transcript.segments, speakerMappings: mappings).utf8)
        func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return Self(transcriptID: transcript.id, digest: hash(transcriptData + mappedData),
                    transcriptDigest: hash(transcriptData), mappingDigest: hash(mappedData))
    }
}

struct SummaryReviewIssue: Codable, Equatable, Sendable {
    let section: String
    let itemIndex: Int?
    let kind: String
    let evidence: String
    let description: String
    let resolved: Bool

    func canRepair(from transcript: String, summary: SummaryResult? = nil) -> Bool {
        if let index = itemIndex, let summary {
            let counts = ["overview": 1, "key_points": summary.keyPoints.count, "action_items": summary.actionItems.count,
                          "decisions": summary.decisions.count, "follow_ups": summary.followUps.count, "your_tasks": summary.yourTasks.count]
            guard index >= 0, index < (counts[section] ?? 0) else { return false }
        }
        return ["overview", "key_points", "action_items", "decisions", "follow_ups", "your_tasks"].contains(section)
            && !resolved && !description.isEmpty && !evidence.isEmpty
            && transcript.contains(evidence) && (itemIndex == nil || itemIndex! >= 0)
    }
}

struct SummaryGenerationMetadata: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case unrecorded, draft, reviewed, repaired, repairIncomplete, singlePass, mapReduced, local }
    var schemaVersion = 1
    var promptVersion = "summary-review-v3"
    var detailLevel: String
    var stage: Stage
    var source: SummarySourceVersion? = nil
    var sourceChanged = false
    var speakerMappingsChanged: Bool? = nil
    var issues: [SummaryReviewIssue] = []
    var generatedAt = Date()

    var exportStatusText: String {
        String(format: String(localized: "Summary status: %@"), statusText)
    }

    var statusText: String {
        if sourceChanged { return String(localized: "Transcript changed. Regenerate summary.") }
        if speakerMappingsChanged == true {
            return String(localized: "Speaker names changed. Summary may use earlier names.")
        }
        return stage.displayName
    }

    var json: String? { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } }
    static func decode(_ json: String?) -> Self? {
        guard let data = json?.data(using: .utf8), let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schemaVersion == 1 else { return nil }
        return value
    }
}

extension SummaryGenerationMetadata.Stage {
    var displayName: String {
        switch self {
        case .unrecorded: String(localized: "Review status not recorded")
        case .draft: String(localized: "Draft · review incomplete")
        case .reviewed: String(localized: "Review completed")
        case .repaired: String(localized: "Review and repair completed")
        case .repairIncomplete: String(localized: "Review has unresolved issues")
        case .singlePass: String(localized: "Generated in one pass")
        case .mapReduced: String(localized: "Combined from transcript segments")
        case .local: String(localized: "Generated locally")
        }
    }
}
