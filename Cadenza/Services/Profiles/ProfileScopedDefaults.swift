import Foundation

/// Per-profile UserDefaults mapping (spec §4.3). The migration copies the
/// explicitly-set global value of every inventoried key to its
/// profile-scoped twin `<originalKey>.profile.<profileID>`; the global keys
/// are retained so a rollback to a pre-profile build keeps working.
/// Consumers address the scoped keys through `ActiveProfileDefaults` (or
/// an injected resolver); in profile mode nothing reads the global keys.
///
/// Deliberately excluded: auth/session keys, `webSync.*.<userID>`
/// account-scoped flags (bound to the account, not the profile), model
/// configuration (`model.<provider>` family — device-level operator
/// settings), storage-root keys (`recordingsDirectory*` — mirrored in the
/// registry's audioDirectory instead), MCP server settings (the enablement,
/// capability toggles, and port are device-level; bearer credentials are
/// separately profile-scoped by `MCPProfileCredentialKeys`), appearance
/// settings, and view preferences without entity references
/// (`recordingsSort`, `contentViewMode`) or calendar-integration keys
/// (`disabledCalendarIDs`, `calColor.*`) — outside the authoritative
/// inventory.
struct ProfileScopedDefaults {
    let defaults: UserDefaults
    /// Persistent-domain name for reading explicitly-set values only —
    /// `dictionaryRepresentation` would also surface registered defaults,
    /// which must never be copied as if the user had set them.
    let persistentDomainName: String

    static func standard() -> ProfileScopedDefaults {
        ProfileScopedDefaults(
            defaults: .standard,
            persistentDomainName: Bundle.main.bundleIdentifier ?? "com.shuiandy.Cadenza"
        )
    }

    /// Exact inventory of profile-scoped keys, grouped by owning
    /// subsystem.
    static let scopedKeys: [String] = [
        // Markdown mirror settings and ledger
        "markdownMirrorEnabled",
        "markdownMirrorIncludeTranscript",
        "markdownMirrorDirectoryBookmark",
        "markdownMirrorDirectoryPath",
        "markdownMirrorLedger.v1",
        // Note-export integration toggles, targets, state, and ledgers
        "autoExportToNotion",
        "notion.databaseID",
        "notion.connected",
        "notion.workspaceName",
        "autoExportToCraft",
        "craft.spaceID",
        "craft.folderID",
        "craft.exportedRecordingIDs",
        // AI identity
        "userName",
        "userJobTitle",
        // UI state embedding entity identifiers
        "smartFolders.overrides.v2",
        "smartFolders.pinned.v1",
        "smartFolders.excluded.v1",
        // Scheduling toggles
        "enableAutomaticRecaps",
        "meetingPrepEnabled",
        "meetingPrepLeadMinutes",
    ]

    /// Dynamic key families: every explicitly-set key with one of these
    /// prefixes is scoped as a whole (per-folder sort keys embed folder
    /// UUIDs).
    static let scopedKeyPrefixes: [String] = [
        "folderSort.",
    ]

    /// Marker recording that the mapping for a profile completed; the
    /// bootstrap re-runs the (idempotent) copy whenever it is absent.
    static let mappingMarkerKey = "defaultsMappingComplete.v1"

    static func scopedKey(_ key: String, profileID: UUID) -> String {
        "\(key).profile.\(profileID.uuidString)"
    }

    /// Seeds each inventoried scoped key from its explicitly-set global twin.
    /// Values keep their plist type verbatim. A key absent globally is left
    /// absent scoped — no defaults are invented. A scoped key that already has
    /// a value is left alone: see `copy(key:from:profileID:)`. Globals are left
    /// in place for rollback. Idempotent; sets the completion marker last.
    func copyGlobalValues(to profileID: UUID) {
        let explicit = explicitValues()
        for key in Self.scopedKeys {
            copy(key: key, from: explicit, profileID: profileID)
        }
        for key in presentDynamicKeys(in: explicit) {
            copy(key: key, from: explicit, profileID: profileID)
        }
        defaults.set(true, forKey: Self.scopedKey(Self.mappingMarkerKey, profileID: profileID))
    }

    func mappingComplete(for profileID: UUID) -> Bool {
        defaults.object(
            forKey: Self.scopedKey(Self.mappingMarkerKey, profileID: profileID)
        ) as? Bool == true
    }

    /// Explicitly-set values only (persistent domain), never registered
    /// defaults.
    func explicitValues() -> [String: Any] {
        defaults.persistentDomain(forName: persistentDomainName) ?? [:]
    }

    func presentDynamicKeys(in explicit: [String: Any]) -> [String] {
        explicit.keys.filter { key in
            Self.scopedKeyPrefixes.contains { key.hasPrefix($0) }
                && !key.contains(".profile.")
        }.sorted()
    }

    /// Fills an absent scoped key from its global twin and does nothing else.
    ///
    /// It must never write over or delete a scoped value that is already there:
    /// once the first mapping has run, that value is the user's own per-profile
    /// setting, and this function's whole job was to seed it — not to keep it in
    /// sync with a global key the app no longer reads. The copy is designed to
    /// re-run (the marker exists to close a crash window, and any bump of
    /// `mappingMarkerKey` re-runs it for every profile), so a destructive branch
    /// here is a live hazard: on this developer's machine a re-run would have
    /// deleted `smartFolders.overrides.v2`, whose global twin is long gone.
    /// Skipping present keys is also what makes the re-run genuinely idempotent.
    private func copy(key: String, from explicit: [String: Any], profileID: UUID) {
        let scoped = Self.scopedKey(key, profileID: profileID)
        guard defaults.object(forKey: scoped) == nil else { return }
        guard let value = explicit[key] else { return }
        defaults.set(value, forKey: scoped)
    }
}
