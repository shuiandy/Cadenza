import Darwin
import Foundation
import SwiftData
import Testing

@testable import Cadenza

// MARK: - Target policy

enum DemoSeedTargetPolicyError: Error, Equatable {
    case emptyPath
    case nonAbsolutePath
    case unsafeLocation
    case existingTarget
    case cannotPrepareTarget
}

/// Fail-closed policy for the opt-in screenshot fixture store.
///
/// This intentionally lives in the test target: production code never needs a
/// fixture-store escape hatch. The policy resolves every existing path component
/// with `realpath(3)`, so an in-root symlink cannot redirect the store into the
/// repository or a user's real Cadenza library.
enum DemoSeedTargetPolicy {
    static let environmentKey = "TEST_RUNNER_CADENZA_DEMO_SEED_STORE"

    struct Context {
        let allowedTemporaryRoots: [URL]
        let protectedRoots: [URL]
    }

    static func validatedStoreURL(
        _ rawPath: String,
        fileManager: FileManager = .default,
        context: Context? = nil
    ) throws -> URL {
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DemoSeedTargetPolicyError.emptyPath
        }
        guard rawPath.hasPrefix("/") else {
            throw DemoSeedTargetPolicyError.nonAbsolutePath
        }

        let policyContext = try context ?? liveContext(fileManager: fileManager)
        let requestedURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        let preliminaryURL = try canonicalProspectiveURL(requestedURL)
        try requireSafeLocation(preliminaryURL, context: policyContext)
        try requirePrivateExistingAncestor(preliminaryURL, context: policyContext)
        guard !storeArtifactExists(at: preliminaryURL) else {
            throw DemoSeedTargetPolicyError.existingTarget
        }

        do {
            try fileManager.createDirectory(
                at: preliminaryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw DemoSeedTargetPolicyError.cannotPrepareTarget
        }

        // Re-resolve after directory creation. This catches an existing symlink
        // in any newly materialized parent path before SwiftData sees the URL.
        let finalURL = try canonicalProspectiveURL(requestedURL)
        try requireSafeLocation(finalURL, context: policyContext)
        try requirePrivateExistingAncestor(finalURL, context: policyContext)
        guard !storeArtifactExists(at: finalURL) else {
            throw DemoSeedTargetPolicyError.existingTarget
        }
        return finalURL
    }

    static func liveContext(fileManager: FileManager = .default) throws -> Context {
        let realHome = try realHomeDirectory()
        let realApplicationSupport = realHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return Context(
            allowedTemporaryRoots: try [
                URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                fileManager.temporaryDirectory,
            ].map(canonicalProspectiveURL),
            protectedRoots: try [
                realApplicationSupport.appendingPathComponent("Cadenza", isDirectory: true),
                realApplicationSupport.appendingPathComponent("default.store"),
                realHome.appendingPathComponent("Documents/Cadenza", isDirectory: true),
                repositoryRoot,
            ].map(canonicalProspectiveURL)
        )
    }

    static func realHomeDirectory() throws -> URL {
        guard let passwordEntry = getpwuid(getuid()),
              let homePointer = passwordEntry.pointee.pw_dir
        else {
            throw DemoSeedTargetPolicyError.cannotPrepareTarget
        }
        return URL(fileURLWithPath: String(cString: homePointer), isDirectory: true)
            .standardizedFileURL
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private static func requireSafeLocation(_ candidate: URL, context: Context) throws {
        let isUnderTemporaryRoot = context.allowedTemporaryRoots.contains { root in
            isStrictDescendant(candidate, of: root)
        }
        let touchesProtectedRoot = context.protectedRoots.contains { root in
            isSameOrDescendant(candidate, of: root)
        }
        guard isUnderTemporaryRoot, !touchesProtectedRoot else {
            throw DemoSeedTargetPolicyError.unsafeLocation
        }
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.path != root.path && isSameOrDescendant(candidate, of: root)
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    /// The system temporary roots themselves are shared trust boundaries.
    /// Require an already-created, app-specific directory below one of them
    /// that belongs to this uid and cannot be written by another uid.
    private static func requirePrivateExistingAncestor(
        _ candidate: URL,
        context: Context
    ) throws {
        var ancestor = candidate.deletingLastPathComponent()
        while !pathEntryExists(ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else {
                throw DemoSeedTargetPolicyError.unsafeLocation
            }
            ancestor = parent
        }

        let isAppSpecificTemporaryDirectory = context.allowedTemporaryRoots.contains { root in
            isStrictDescendant(ancestor, of: root)
        }
        var metadata = stat()
        guard isAppSpecificTemporaryDirectory,
              lstat(ancestor.path, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
        else {
            throw DemoSeedTargetPolicyError.unsafeLocation
        }
    }

    /// Resolve the nearest existing ancestor with `realpath(3)`, then append
    /// missing components lexically. A dangling symlink is an existing path
    /// entry whose `realpath` fails, so it is rejected rather than followed.
    private static func canonicalProspectiveURL(_ url: URL) throws -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []

        while !pathEntryExists(existingAncestor.path) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else {
                throw DemoSeedTargetPolicyError.cannotPrepareTarget
            }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor = parent
        }

        guard let resolvedPointer = realpath(existingAncestor.path, nil) else {
            throw DemoSeedTargetPolicyError.unsafeLocation
        }
        defer { free(resolvedPointer) }

        var resolved = URL(
            fileURLWithPath: String(cString: resolvedPointer),
            isDirectory: true
        )
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        // Do not call `standardizedFileURL` here. Foundation rewrites an
        // existing `/private/var/...` directory back to `/var/...`, but leaves
        // a prospective descendant as `/private/var/...`; preserving the
        // `realpath(3)` spelling keeps root and descendant comparisons stable.
        return resolved
    }

    private static func pathEntryExists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    private static func storeArtifactExists(at storeURL: URL) -> Bool {
        ["", "-wal", "-shm", "-journal"].contains { suffix in
            pathEntryExists(storeURL.path + suffix)
        }
    }
}

/// Screenshot fixture generator. Disabled by default: it only runs when
/// `TEST_RUNNER_CADENZA_DEMO_SEED_STORE` passes the fail-closed temporary-path
/// policy below, so a normal test run never touches user data.
@Suite("DemoSeed", .serialized)
struct DemoSeedTests {

    @Test("seed demo store")
    func seedDemoStore() throws {
        guard let target = ProcessInfo.processInfo.environment[
            DemoSeedTargetPolicy.environmentKey
        ] else {
            return
        }
        let storeURL = try DemoSeedTargetPolicy.validatedStoreURL(target)
        let container = try RecordingsStore.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)

        let calendar = Calendar.current
        let now = Date()
        func day(_ back: Int, hour: Int, minute: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: -back, to: now)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        }

        for spec in DemoFixtures.recordings {
            let recording = Recording(
                title: spec.title,
                startDate: day(spec.daysAgo, hour: spec.hour, minute: spec.minute),
                language: "en",
                source: .captured
            )
            recording.duration = spec.duration
            recording.endDate = recording.startDate.addingTimeInterval(spec.duration)
            recording.meetingApp = spec.app
            recording.meetingType = spec.type.rawValue
            recording.tags = spec.tags
            recording.createdAt = recording.startDate
            recording.updatedAt = recording.startDate.addingTimeInterval(spec.duration + 180)
            recording.lastAccessedDate = recording.updatedAt

            let transcript = Transcript(
                fullText: spec.transcript.map(\.text).joined(separator: "\n\n"),
                segments: spec.transcript
            )
            transcript.detectedLanguage = "en"
            recording.transcript = transcript

            let summary = MeetingSummary(
                overview: spec.overview,
                keyPoints: spec.keyPoints,
                actionItems: spec.actionItems,
                decisions: spec.decisions,
                followUps: spec.followUps,
                provider: .claude,
                model: "claude-sonnet-4-6",
                language: "en"
            )
            recording.summary = summary
            context.insert(recording)
        }

        try context.save()
    }

    @Test("accepts a new store under a canonical system temporary root")
    func acceptsCanonicalTemporaryTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CadenzaDemoSeedPolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let requested = root.appendingPathComponent("Fixtures/Cadenza.store")
        let validated = try DemoSeedTargetPolicy.validatedStoreURL(requested.path)

        #expect(validated.lastPathComponent == "Cadenza.store")
        #expect(FileManager.default.fileExists(
            atPath: validated.deletingLastPathComponent().path
        ))
        #expect(!FileManager.default.fileExists(atPath: validated.path))
    }

    @Test("rejects a relative store path")
    func rejectsRelativeTarget() {
        #expect(throws: DemoSeedTargetPolicyError.nonAbsolutePath) {
            try DemoSeedTargetPolicy.validatedStoreURL("fixtures/Cadenza.store")
        }
    }

    @Test("rejects every real Cadenza library location")
    func rejectsRealLibraryTargets() throws {
        let realHome = try DemoSeedTargetPolicy.realHomeDirectory()
        let realApplicationSupport = realHome
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let targets = [
            realApplicationSupport.appendingPathComponent("Cadenza/Cadenza.store"),
            realApplicationSupport.appendingPathComponent("default.store"),
            realHome.appendingPathComponent("Documents/Cadenza/Cadenza.store"),
            DemoSeedTargetPolicy.repositoryRoot.appendingPathComponent("Cadenza.store"),
        ]

        for target in targets {
            #expect(throws: DemoSeedTargetPolicyError.unsafeLocation) {
                try DemoSeedTargetPolicy.validatedStoreURL(target.path)
            }
        }
    }

    @Test("rejects temporary-root prefix confusion")
    func rejectsTemporaryPrefixConfusion() {
        let target = URL(
            fileURLWithPath: "/private/tmp-cadenza-demo-\(UUID().uuidString)/Cadenza.store"
        )
        #expect(throws: DemoSeedTargetPolicyError.unsafeLocation) {
            try DemoSeedTargetPolicy.validatedStoreURL(target.path)
        }
    }

    @Test("rejects a target whose nearest existing ancestor is a shared temp root")
    func rejectsSharedTemporaryRootAncestor() {
        let target = URL(
            fileURLWithPath: "/private/tmp/CadenzaUnprepared-\(UUID().uuidString)/Cadenza.store"
        )
        #expect(throws: DemoSeedTargetPolicyError.unsafeLocation) {
            try DemoSeedTargetPolicy.validatedStoreURL(target.path)
        }
    }

    @Test("rejects a group-or-world-writable fixture ancestor")
    func rejectsWritableFixtureAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CadenzaDemoSeedShared-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: DemoSeedTargetPolicyError.unsafeLocation) {
            try DemoSeedTargetPolicy.validatedStoreURL(
                root.appendingPathComponent("Cadenza.store").path
            )
        }
    }

    @Test("rejects a symlink that escapes a temporary root")
    func rejectsSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CadenzaDemoSeedSymlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let link = root.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: DemoSeedTargetPolicy.realHomeDirectory()
        )

        #expect(throws: DemoSeedTargetPolicyError.unsafeLocation) {
            try DemoSeedTargetPolicy.validatedStoreURL(
                link.appendingPathComponent("Cadenza.store").path
            )
        }
    }

    @Test("rejects an existing store instead of appending fixtures")
    func rejectsExistingStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CadenzaDemoSeedExisting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("Cadenza.store")
        try Data("not a fixture store".utf8).write(to: target)

        #expect(throws: DemoSeedTargetPolicyError.existingTarget) {
            try DemoSeedTargetPolicy.validatedStoreURL(target.path)
        }
    }

    @Test("rejects orphaned SQLite sidecars instead of recovering old fixtures")
    func rejectsOrphanedSQLiteSidecars() throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "CadenzaDemoSeedSidecar-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let target = root.appendingPathComponent("Cadenza.store")
            try Data("orphaned SQLite state".utf8).write(
                to: URL(fileURLWithPath: target.path + suffix)
            )

            #expect(throws: DemoSeedTargetPolicyError.existingTarget) {
                try DemoSeedTargetPolicy.validatedStoreURL(target.path)
            }
        }
    }
}

// MARK: - Fixtures

/// Entirely fictional meeting content for documentation screenshots.
enum DemoFixtures {
    struct RecordingSpec {
        let title: String
        let daysAgo: Int
        let hour: Int
        var minute: Int = 0
        let duration: TimeInterval
        let app: String
        let type: MeetingType
        let tags: [String]
        let overview: String
        var keyPoints: [String] = []
        var decisions: [String] = []
        var followUps: [String] = []
        var actionItems: [ActionItem] = []
        var transcript: [TranscriptEntry] = []
    }

    static func entry(_ start: TimeInterval, _ end: TimeInterval, _ speaker: String, _ text: String)
        -> TranscriptEntry
    {
        TranscriptEntry(startTime: start, endTime: end, text: text, speaker: speaker)
    }

    static let recordings: [RecordingSpec] = [
        RecordingSpec(
            title: "Atlas Weekly Product Sync",
            daysAgo: 1,
            hour: 10,
            duration: 42 * 60 + 18,
            app: "zoom.us",
            type: .general,
            tags: ["atlas", "onboarding", "activation"],
            overview:
                "The team reviewed activation metrics for the Atlas onboarding rewrite. Week-two retention moved from 31% to 38% after the guided setup shipped, but the invite step is still where most teams stall. Maya proposed cutting the workspace-naming screen entirely and inferring the name from the email domain. The group agreed to run it as an experiment behind a flag rather than a full rollout, with a read on results before the next planning cycle.",
            keyPoints: [
                "Week-two retention rose from 31% to 38% after guided setup shipped to all new workspaces.",
                "42% of teams that drop off never complete the teammate invite step — the single largest funnel gap.",
                "Workspace naming was the second-highest drop-off; domain inference could remove the screen entirely.",
                "Support volume on setup questions fell by roughly a third since the rewrite.",
                "Mobile activation still trails desktop by 11 points and has no owner this cycle.",
            ],
            decisions: [
                "Ship domain-inferred workspace names behind the `onboarding_v3` flag at 25% rather than a full rollout.",
                "Hold the mobile activation work until after the Q3 planning session — no owner available this cycle.",
            ],
            followUps: [
                "Share the funnel breakdown by company size before Thursday's design review.",
                "Confirm whether the invite step can be deferred to post-first-session without hurting seat expansion.",
            ],
            actionItems: [
                ActionItem(
                    assignee: "Maya", task: "Draft the experiment brief for domain-inferred workspace names",
                    deadline: "Thursday", priority: .high),
                ActionItem(
                    assignee: "Devin", task: "Instrument the invite step so drop-off is attributable to a specific field",
                    deadline: "Next sprint", priority: .medium),
                ActionItem(
                    assignee: "Priya", task: "Pull activation numbers split by company size for the design review",
                    deadline: "Wednesday", isCompleted: true, priority: .medium),
                ActionItem(
                    assignee: "Sam", task: "Write up why mobile activation is deferred so it doesn't resurface as a surprise",
                    priority: .low),
            ],
            transcript: [
                entry(
                    0, 14, "Maya",
                    "Let's start with activation since that's the reason we moved this meeting earlier. The guided setup has been out to every new workspace for two weeks now, so we finally have a clean read."),
                entry(
                    14, 41, "Priya",
                    "Week-two retention is at 38%. It was 31% before the rewrite. That's the first real movement we've had on that number in about three quarters, and it held steady across both self-serve and sales-assisted signups."),
                entry(
                    41, 58, "Devin",
                    "Worth saying that's not evenly distributed. Teams under ten people are doing much better. Larger orgs barely moved, and I think that's the invite flow rather than the setup itself."),
                entry(
                    58, 82, "Maya",
                    "That matches what I'm seeing in the funnel. Forty-two percent of the teams that drop off never send a single invite. They finish setup, land in an empty workspace, and there's nothing pulling them back the next day."),
                entry(
                    82, 96, "Sam",
                    "Is the invite step actually hard, or is it just that people don't want to commit before they've looked around?"),
                entry(
                    96, 128, "Devin",
                    "Honestly we can't tell from the data we have. The step is one screen with three fields and we only instrument whether it was completed or skipped. I'd want to break it down per field before we redesign anything."),
                entry(
                    128, 151, "Priya",
                    "The other spike is workspace naming. People sit on that screen for a long time and a nontrivial number just close the tab. It's a naming decision with no context, right at the point where they have the least investment."),
                entry(
                    151, 174, "Maya",
                    "So why are we asking at all? We have their email domain. We can name the workspace after the company and let them rename it later from settings, where it costs nothing."),
                entry(
                    174, 190, "Sam",
                    "I like it, but I don't want to ship it to everyone at once. If domain inference gets it wrong for consultancies or agencies it'll look careless."),
                entry(
                    190, 213, "Maya",
                    "Fair. Twenty-five percent behind the onboarding flag, and we read it before Q3 planning. If it's flat we've lost nothing and we've removed a screen."),
                entry(
                    213, 236, "Devin",
                    "Support side is already better, by the way. Setup questions are down about a third since the rewrite. That's the clearest signal we've had that the new flow is less confusing."),
                entry(
                    236, 262, "Priya",
                    "Mobile is the one that still worries me. Activation there is eleven points behind desktop and nobody owns it this cycle. I'd rather say that out loud than let it quietly slip again."),
                entry(
                    262, 281, "Sam",
                    "Then let's write it down as a deliberate deferral. We revisit it in Q3 planning with an owner attached, and it doesn't come back as a surprise in three months."),
            ]
        ),
        RecordingSpec(
            title: "Design Review — Onboarding Flow",
            daysAgo: 2,
            hour: 14,
            minute: 30,
            duration: 55 * 60 + 40,
            app: "Google Meet",
            type: .designReview,
            tags: ["atlas", "onboarding", "figma"],
            overview:
                "Walkthrough of the three-screen onboarding revision. Consensus on removing the workspace-naming step; disagreement on whether the template picker earns its place. The empty-state illustration set was approved as-is. Copy for the invite screen still needs a pass before handoff.",
            keyPoints: [
                "Three screens collapse to two once workspace naming is inferred.",
                "The template picker tested poorly with first-time users who had no mental model yet.",
                "Empty-state illustrations approved without changes.",
            ],
            decisions: [
                "Cut the template picker from first-run; surface it contextually after the first document instead."
            ],
            actionItems: [
                ActionItem(
                    assignee: "Jonah", task: "Rewrite invite-screen copy and hand off to engineering",
                    deadline: "Monday", priority: .high),
                ActionItem(
                    assignee: "Maya", task: "Update the flow diagram to reflect the two-screen version",
                    priority: .medium),
            ]
        ),
        RecordingSpec(
            title: "Customer Interview — Lattice Labs",
            daysAgo: 3,
            hour: 11,
            duration: 38 * 60 + 5,
            app: "zoom.us",
            type: .interview,
            tags: ["research", "lattice-labs", "permissions"],
            overview:
                "A 40-person research org walked through how they actually use shared workspaces. Their biggest friction is permissions: they maintain a spreadsheet outside the product to track who can see what. They would pay for granular per-folder access and said the current all-or-nothing sharing model blocks wider rollout.",
            keyPoints: [
                "The team tracks access in an external spreadsheet because the product has no per-folder permissions.",
                "All-or-nothing sharing is cited as the specific blocker to rolling out past 12 seats.",
                "They rebuilt search themselves because results were not scoped to their team.",
            ],
            followUps: [
                "Ask whether per-folder permissions would unblock the seat expansion they described."
            ],
            actionItems: [
                ActionItem(
                    assignee: "Priya", task: "Write up the permissions findings and circulate to the platform team",
                    deadline: "This week", priority: .high)
            ]
        ),
        RecordingSpec(
            title: "Q3 Roadmap Planning",
            daysAgo: 5,
            hour: 9,
            duration: 72 * 60 + 12,
            app: "Microsoft Teams",
            type: .sprintPlanning,
            tags: ["roadmap", "q3", "permissions"],
            overview:
                "Scoped Q3 around two bets: granular permissions and search quality. Mobile activation was explicitly deferred with an owner to be named in the first week of the quarter. The integrations backlog stays frozen until the permissions work lands, since most requests depend on it.",
            keyPoints: [
                "Q3 commits to granular permissions and search quality; everything else is explicitly out of scope.",
                "Integrations backlog frozen — most open requests depend on the permissions model landing first.",
                "Mobile activation deferred with an owner to be assigned in week one.",
            ],
            decisions: [
                "Freeze the integrations backlog until per-folder permissions ship.",
                "Two bets for Q3, not three — search quality and permissions.",
            ],
            actionItems: [
                ActionItem(
                    assignee: "Sam", task: "Name a mobile activation owner in week one of the quarter",
                    deadline: "Jul 8", priority: .high),
                ActionItem(
                    assignee: "Devin", task: "Break the permissions model into shippable milestones",
                    priority: .high),
            ]
        ),
        RecordingSpec(
            title: "1:1 — Priya",
            daysAgo: 6,
            hour: 16,
            duration: 27 * 60 + 33,
            app: "Microsoft Teams",
            type: .oneOnOne,
            tags: ["career-growth", "research"],
            overview:
                "Discussed workload after the research team lost a headcount, and what a move toward a lead role would require. Agreed to hand off two smaller studies so there is room for the permissions research. Revisit the role conversation at the mid-quarter check-in.",
            keyPoints: [
                "Two smaller studies to be handed off to make room for permissions research.",
                "Role conversation parked until the mid-quarter check-in, by mutual agreement.",
            ],
            actionItems: [
                ActionItem(
                    assignee: "Priya", task: "Propose which two studies to hand off", deadline: "Friday",
                    priority: .medium)
            ]
        ),
        RecordingSpec(
            title: "Sprint Retro",
            daysAgo: 8,
            hour: 15,
            duration: 45 * 60 + 2,
            app: "zoom.us",
            type: .retrospective,
            tags: ["atlas", "release-process"],
            overview:
                "The onboarding release went out two days late because staging drifted from production. Consensus that the fix is environment parity, not more manual QA. One action taken: block releases when the staging schema differs from production.",
            keyPoints: [
                "Release slipped two days; root cause was staging/production schema drift, not review load.",
                "The team rejected adding more manual QA as the remedy.",
            ],
            decisions: [
                "Block releases automatically when the staging schema differs from production."
            ],
            actionItems: [
                ActionItem(
                    assignee: "Devin", task: "Add the schema-parity check to the release pipeline",
                    deadline: "Next sprint", priority: .high)
            ]
        ),
        RecordingSpec(
            title: "Infrastructure Cost Review",
            daysAgo: 9,
            hour: 13,
            duration: 31 * 60 + 47,
            app: "Google Meet",
            type: .general,
            tags: ["infrastructure", "cost"],
            overview:
                "Monthly spend is up 18% quarter over quarter, driven almost entirely by transcript storage growth rather than compute. Tiering transcripts older than 90 days to cold storage would cover most of the increase without touching retention policy.",
            keyPoints: [
                "Spend up 18% QoQ; storage rather than compute accounts for nearly all of it.",
                "Tiering transcripts older than 90 days recovers most of the increase.",
            ],
            actionItems: [
                ActionItem(
                    assignee: "Devin", task: "Estimate the savings from cold-storage tiering before committing",
                    priority: .medium)
            ]
        ),
        RecordingSpec(
            title: "All-Hands Prep",
            daysAgo: 11,
            hour: 10,
            minute: 30,
            duration: 22 * 60 + 16,
            app: "zoom.us",
            type: .allHands,
            tags: ["all-hands", "atlas"],
            overview:
                "Agreed the all-hands leads with the activation result, then the Q3 bets. Cut the detailed roadmap slide — it invited scope questions the team can't answer yet. Demo slot goes to the onboarding flow.",
            keyPoints: [
                "Lead with activation, then Q3 bets; cut the detailed roadmap slide.",
                "Demo slot assigned to the new onboarding flow.",
            ],
            actionItems: [
                ActionItem(
                    assignee: "Maya", task: "Record a two-minute onboarding demo as a backup for the live walkthrough",
                    deadline: "Day before", priority: .medium)
            ]
        ),
        RecordingSpec(
            title: "Search Quality Kickoff",
            daysAgo: 12,
            hour: 11,
            duration: 48 * 60 + 21,
            app: "Google Meet",
            type: .brainstorm,
            tags: ["search", "ranking"],
            overview:
                "Opened the search bet by agreeing on what \"bad results\" actually means today. Recency beats relevance far too often, and results are not scoped to the team you're in. Ranking changes come first; the index rebuild is a later milestone.",
            keyPoints: [
                "Recency dominates ranking — exact-title matches lose to newer documents.",
                "Results are not team-scoped, which is what customers describe as noise.",
                "Ranking first, index rebuild later; the two are separable.",
            ],
            decisions: [
                "Sequence ranking work before the index rebuild."
            ],
            actionItems: [
                ActionItem(
                    assignee: "Devin", task: "Assemble a labeled query set from real support tickets",
                    deadline: "Next week", priority: .high)
            ]
        ),
        RecordingSpec(
            title: "Support Escalation Review",
            daysAgo: 13,
            hour: 9,
            minute: 30,
            duration: 34 * 60 + 9,
            app: "zoom.us",
            type: .general,
            tags: ["support", "permissions"],
            overview:
                "Three escalations this month traced back to the same cause: someone shared a workspace to grant access to one folder. Support is absorbing the gap with manual workarounds, and the permissions work is the actual fix.",
            keyPoints: [
                "All three escalations share one root cause — sharing granularity.",
                "Support's manual workaround does not scale past the current volume.",
            ],
            followUps: [
                "Feed the escalation transcripts into the permissions design review."
            ],
            actionItems: [
                ActionItem(
                    assignee: "Priya", task: "Attach the three escalation write-ups to the permissions spec",
                    priority: .medium)
            ]
        ),
        RecordingSpec(
            title: "Onboarding Copy Walkthrough",
            daysAgo: 15,
            hour: 14,
            duration: 29 * 60 + 44,
            app: "Google Meet",
            type: .designReview,
            tags: ["onboarding", "copywriting"],
            overview:
                "Line-by-line pass over the setup screens. Cut two thirds of the explanatory text — first-time users skip it entirely. The invite screen now leads with why rather than how.",
            keyPoints: [
                "Explanatory paragraphs cut by roughly two thirds across the flow.",
                "Invite screen reframed around the benefit, not the mechanics.",
            ],
            actionItems: [
                ActionItem(
                    assignee: "Jonah", task: "Land the revised strings before the flag rollout",
                    deadline: "Friday", priority: .high)
            ]
        ),
        RecordingSpec(
            title: "Platform Sync — Permissions Model",
            daysAgo: 16,
            hour: 15,
            minute: 30,
            duration: 51 * 60 + 6,
            app: "Microsoft Teams",
            type: .general,
            tags: ["permissions", "platform"],
            overview:
                "Settled on inherited folder permissions with explicit overrides, rather than per-document ACLs. The migration path for existing workspaces is the hard part: everything currently sits at workspace scope, and nobody wants a flag day.",
            keyPoints: [
                "Inherited folder permissions with explicit overrides, not per-document ACLs.",
                "Existing workspaces migrate incrementally — no flag day.",
            ],
            decisions: [
                "Inheritance plus overrides is the model; per-document ACLs are out of scope."
            ],
            actionItems: [
                ActionItem(
                    assignee: "Devin", task: "Write the incremental migration plan for workspace-scoped shares",
                    deadline: "Two weeks", priority: .high),
                ActionItem(
                    assignee: "Sam", task: "Check the model against the Lattice Labs requirements",
                    priority: .medium),
            ]
        ),
    ]
}
