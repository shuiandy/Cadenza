import Foundation

/// Fictional, hand-annotated cases. Expectations are for review, never sent to the provider.
enum SummaryQualityEvaluation {
    static let fixtureVersion = "summary-eval-v1"
    struct Sample: Codable, Sendable {
        let id: String
        let transcript: String
        let requiredFacts: [String]
        let prohibitedClaims: [String]
    }
    struct Result: Codable, Sendable {
        let sampleID: String
        let model: String
        let provider: String
        let strategy: String
        let repetition: Int
        let detail: String
        let elapsedSeconds: Double
        let firstReadableSeconds: Double?
        let quickDraft: String?
        let output: String
        let error: String?
        let telemetry: AIGenerationTrace.Snapshot
        var outputLanguage: String? = nil
    }
    struct Report: Codable, Sendable {
        let fixtureVersion: String
        let codeVersion: String
        let samples: [Sample]
        var results: [Result] = []
        var status = "running"
        var outputLanguage: String? = nil
    }

    static let samples: [Sample] = [
        Sample(id: "pilot-suggestion", transcript: """
        [00:00] Nora: We are moving the Atlas archive. The import script is tested, but the access-group mapping is not ready.
        [00:20] Eli: I suggest starting with the tiny sandbox archive. Run the whole process and check read access before planning the large customer archives.
        [00:40] Nora: That is a useful suggestion. We have not chosen an owner or a pilot date. I will ask the directory team about the mapping.
        """, requiredFacts: ["Import tested; access mapping blocks rollout", "Eli suggests a small sandbox end-to-end pilot before large archives", "No pilot owner/date agreed", "Nora will ask directory team"], prohibitedClaims: ["Pilot is approved or scheduled", "Eli committed to run pilot"]),
        Sample(id: "date-purpose", transcript: """
        [00:00] Mina: Please send the migration schedule.
        [00:10] Leo: I thought every team had a November deadline.
        [00:20] Mina: No universal November deadline. Each team should propose its schedule; the overall goal is completion before year end.
        [00:35] Leo: My team expects to finish migration in November. I'll work out a specific completion date and send it to you. We haven't set a date for sending the schedule.
        """, requiredFacts: ["No universal November deadline", "Year-end overall goal", "Leo team November migration target", "Schedule submission deadline unknown"], prohibitedClaims: ["Schedule must be submitted in November", "All teams must finish in November"]),
        Sample(id: "view-versus-decision", transcript: """
        [00:00] Nora: I believe a runtime placeholder is not an embedded credential. In my view our rule should only flag actual values committed in source.
        [00:20] Mina: We cannot decide this ticket yet. The example and policy need review. I will inspect both and report back.
        [00:40] Eli: No policy change has been approved today. The alert remains open.
        """, requiredFacts: ["Nora's view on placeholders", "Mina will review example and policy", "Alert remains open; no policy decision"], prohibitedClaims: ["Alert confirmed false positive", "Exemption policy adopted"]),
        Sample(id: "execution-versus-oversight", transcript: """
        [00:00] Eli: Operations still performs the operating-system upgrades. The product team will track vulnerable versions and coordinate the schedule.
        [00:15] Nora: Do we also install the patches?
        [00:20] Eli: No. Installation remains with Operations. Nora, please compile the affected product list by Friday; the actual upgrade window is still undecided.
        """, requiredFacts: ["Operations executes upgrades", "Product team monitors and coordinates", "Nora product list due Friday", "Upgrade date undecided"], prohibitedClaims: ["Product team installs patches", "Upgrades due Friday"]),
        Sample(id: "ambiguous-name", transcript: """
        [00:00] Leo: The entry sounds like Luma or Luna, I cannot hear the product name clearly. It is an application name, not a new key type.
        [00:15] Mina: Leave that name unconfirmed. Nora will check the catalog. The confirmed application, Meridian, belongs to the Orchard platform.
        """, requiredFacts: ["Luma/Luna application name uncertain", "Nora checks catalog", "Meridian belongs to Orchard"], prohibitedClaims: ["Uncertain name asserted as confirmed", "A new key type inferred"]),
        Sample(id: "proposal-rejected", transcript: """
        [00:00] Nora: We could cut over all customers on Tuesday.
        [00:15] Eli: That would exceed support capacity. I propose two waves, internal users then customers, with rollback validated first.
        [00:30] Nora: Agreed on two waves, contingent on rollback validation. Tuesday is no longer the target. No replacement date yet.
        """, requiredFacts: ["All-customer Tuesday proposal rejected due support capacity", "Two waves agreed: internal then customers", "Rollback validation prerequisite", "No replacement date"], prohibitedClaims: ["Tuesday remains committed", "Two waves approved unconditionally"]),
        Sample(id: "unidentified-speakers", transcript: """
        [00:00] Speaker 1: Can you check whether the new interns finished onboarding?
        [00:15] Speaker 2: I will check the onboarding list tomorrow. I am not one of the interns.
        [00:30] Speaker 1: Thanks. I am reporting the issue on behalf of their supervisor.
        """, requiredFacts: ["Speaker 2 checks list tomorrow", "Speaker 1 reporting on supervisor's behalf", "Identities unknown"], prohibitedClaims: ["Speaker 1 or 2 is the user", "Either speaker is a new intern"]),
        Sample(id: "scope-and-exceptions", transcript: """
        [00:00] Mina: Release one covers only the 18 internal services in the Cedar region. The two payment services are excluded pending legal review.
        [00:20] Leo: Does that include external tenants?
        [00:25] Mina: No. External tenants remain on the current service. We will re-evaluate the two payment services after legal review, not automatically include them.
        """, requiredFacts: ["Release one: 18 internal Cedar services", "Two payment services excluded pending review", "External tenants unchanged", "Re-evaluate after review; not automatic approval"], prohibitedClaims: ["All services or tenants included", "Payment services automatically approved after review"]),
        Sample(id: "unresolved-disagreement", transcript: """
        [00:00] Eli: I believe only stable and release branches are scanned now.
        [00:15] Nora: My dashboard still shows every branch. I don't think the change has been applied.
        [00:30] Mina: We don't have the configuration here, so this remains unresolved. I will check it with the platform team. The Aurora exclusion was approved but its deployment is unconfirmed.
        """, requiredFacts: ["Conflicting branch-scan accounts preserved", "Mina verifies configuration", "Aurora exclusion approved, deployment unconfirmed"], prohibitedClaims: ["All branches definitely scanned", "Only release branches definitely scanned", "Exclusion deployed"]),
        Sample(id: "secondary-updates", transcript: """
        [00:00] Leo: Storage cost is down 12 percent after cleanup, but backup retention remains 30 days.
        [00:20] Nora: There are 24 workshop seats left. Existing engineers completed training; two contractors joined yesterday and their status is unknown. I'll check their attendance.
        [00:40] Eli: The tracing dashboard is delayed because the test account lacks access. No new delivery date. Incident alerts continue to work.
        """, requiredFacts: ["Storage cost down 12%; retention still 30 days", "24 seats; existing engineers done; two new contractors unknown", "Nora checks attendance", "Tracing delayed by account access; no new date; incident alerts work"], prohibitedClaims: ["Everyone completed training", "Incident alerts broken"]),
        Sample(id: "conditional-owner", transcript: """
        [00:00] Nora: Sam may be able to help with the export, but Sam is not here and has not agreed.
        [00:15] Eli: I'll ask Sam tomorrow. If Sam cannot help, we need another owner. The export itself has no deadline yet.
        [00:30] Mina: Agreed. Eli owns asking, not delivering the export.
        """, requiredFacts: ["Sam is a proposed, unconfirmed export owner", "Eli asks Sam tomorrow", "Export deadline unknown", "Eli not export owner"], prohibitedClaims: ["Sam committed", "Export due tomorrow", "Eli must deliver export"]),
        Sample(id: "cross-chunk-correction", transcript:
            "[00:00] Nora: My initial proposal is to retire all gateways on December 3. We have not approved it.\n" +
            (0..<260).map { i in "[\(i + 1):00] Eli: Validation checkpoint \(i) for fictional archive Orion repeats the same status: staging reads succeed, production permissions remain unverified. This is a repeated status, not a separate decision or a new task.\n" }.joined() +
            "[262:00] Mina: Correction to the opening proposal: retire only the staging gateways after a successful restore test. Production is excluded. December 3 is withdrawn; no replacement date. Nora owns the restore test, no due date set.\n[263:00] Nora: Agreed to that revised scope and prerequisite.",
               requiredFacts: ["Staging only, production excluded", "December 3 withdrawn with no replacement", "Restore test prerequisite", "Nora owns restore test, deadline unknown", "Repeated staging reads succeed; production permissions unverified"],
               prohibitedClaims: ["All gateways retire", "December 3 deadline", "Production retirement approved"])
    ]

    /// Immutable pre-review strategy, from c1ad852's enrich contract. Same transport/budget as candidate.
    static func legacyEnrichPrompt(language: String) -> String {
        """
        You are a meeting analysis assistant. You will receive a meeting transcript and an initial summary that already covers the overview, key points, and action items.
        Your job is to extract additional insights that the initial summary did not cover.
        \(SummaryPrompt.speakerAttributionRules)
        Respond in \(SummaryPrompt.languageName(language)). Output ONLY valid JSON with this exact structure:
        {"decisions": ["decision 1"], "follow_ups": ["topic 1"]}
        Decisions: explicit agreements, approvals, or commitments made during the meeting.
        Follow-ups: topics that need further discussion, research, or action in future meetings.
        If none found, use empty arrays. Do not repeat information from the initial summary.
        """
    }
}
