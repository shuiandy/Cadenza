import SwiftUI
import AppKit
private let speakerTimelineColorPalette: [Color] = [
    Color(red: 0.20, green: 0.82, blue: 0.92),
    Color(red: 1.00, green: 0.70, blue: 0.25),
    Color(red: 1.00, green: 0.36, blue: 0.62),
    Color(red: 0.58, green: 0.48, blue: 1.00),
    Color(red: 0.34, green: 0.88, blue: 0.48),
    Color(red: 0.22, green: 0.56, blue: 1.00),
    Color(red: 1.00, green: 0.45, blue: 0.24),
    Color(red: 0.18, green: 0.86, blue: 0.68)
]

private func speakerTimelineColor(for colorIndex: Int) -> Color {
    if colorIndex == SpeakerTimelineBuilder.unknownSpeakerColorIndex {
        return Color.secondary.opacity(0.48)
    }
    if colorIndex == SpeakerTimelineBuilder.othersColorIndex {
        return Color.secondary.opacity(0.68)
    }
    let normalizedIndex = ((colorIndex % speakerTimelineColorPalette.count) + speakerTimelineColorPalette.count) % speakerTimelineColorPalette.count
    return speakerTimelineColorPalette[normalizedIndex]
}

private func speakerTimelineFallbackColor(for speakerKey: String) -> Color {
    speakerTimelineColor(for: SpeakerTimelineBuilder.fallbackColorIndex(for: speakerKey))
}

enum CalendarLinkResolver {
    static func linkedEvent(
        linkedCalendarEventID: String?,
        candidateEvents: [MeetingEventDTO],
        fallback: (String) -> MeetingEventDTO?
    ) -> MeetingEventDTO? {
        guard let linkedCalendarEventID else { return nil }
        if let candidate = candidateEvents.first(where: { $0.id == linkedCalendarEventID }) {
            return candidate
        }
        return fallback(linkedCalendarEventID)
    }
}

struct SpeakerTimelineData: Equatable, Sendable {
    struct Segment: Identifiable, Equatable, Sendable {
        let id: UUID
        let speakerKey: String
        let speakerName: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let startFraction: Double
        let widthFraction: Double
        let colorIndex: Int
    }

    struct SpeakerSummary: Identifiable, Equatable, Sendable {
        var id: String { speakerKey }
        let speakerKey: String
        let speakerName: String
        let totalDuration: TimeInterval
        let fraction: Double
        let colorIndex: Int
    }

    let segments: [Segment]
    let speakers: [SpeakerSummary]
    let totalDuration: TimeInterval

    var identifiedSpeakerCount: Int {
        speakers.count { $0.speakerKey != SpeakerTimelineBuilder.unknownSpeakerKey }
    }
}

enum SpeakerTimelineBuilder {
    static let unknownSpeakerKey = "__unknown_speaker__"
    static let unknownSpeakerColorIndex = -1
    static let othersColorIndex = -2

    static func build(
        entries: [TranscriptEntryDTO],
        recordingDuration: TimeInterval,
        displayName: (String?) -> String = { raw in
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? String(localized: "Unknown") : trimmed
        },
        identityKey: (String?) -> String? = { raw in
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    ) -> SpeakerTimelineData? {
        let maxEntryEnd = entries.map(\.endTime).filter(\.isFinite).max() ?? 0
        let totalDuration = max(recordingDuration.isFinite ? recordingDuration : 0, maxEntryEnd)
        guard totalDuration > 0 else { return nil }

        let validEntries = entries.compactMap { entry -> (entry: TranscriptEntryDTO, start: TimeInterval, end: TimeInterval, key: String, name: String)? in
            guard entry.startTime.isFinite, entry.endTime.isFinite else { return nil }
            let start = max(0, min(totalDuration, entry.startTime))
            let end = max(0, min(totalDuration, entry.endTime))
            guard end > start else { return nil }

            let rawSpeaker = entry.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            if rawSpeaker?.isEmpty == false {
                let resolvedKey = identityKey(rawSpeaker)?.trimmingCharacters(in: .whitespacesAndNewlines)
                key = resolvedKey?.isEmpty == false ? resolvedKey! : rawSpeaker!
            } else {
                key = unknownSpeakerKey
            }
            return (entry, start, end, key, displayName(rawSpeaker?.isEmpty == false ? rawSpeaker : nil))
        }
        .sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }
        guard !validEntries.isEmpty else { return nil }
        guard validEntries.contains(where: { $0.key != unknownSpeakerKey }) else { return nil }

        var totals: [String: (name: String, duration: TimeInterval)] = [:]
        for item in validEntries {
            let duration = item.end - item.start
            let current = totals[item.key] ?? (item.name, 0)
            totals[item.key] = (current.name, current.duration + duration)
        }
        let spokenDuration = max(totals.values.reduce(0) { $0 + $1.duration }, .leastNonzeroMagnitude)
        let sortedTotals = totals.sorted { lhs, rhs in
            if lhs.value.duration == rhs.value.duration { return lhs.value.name < rhs.value.name }
            return lhs.value.duration > rhs.value.duration
        }
        let colorIndexByKey = Dictionary(uniqueKeysWithValues: sortedTotals.enumerated().map { index, item in
            let colorIndex = item.key == unknownSpeakerKey ? unknownSpeakerColorIndex : index
            return (item.key, colorIndex)
        })
        let speakers = sortedTotals.map { key, value in
            SpeakerTimelineData.SpeakerSummary(
                speakerKey: key,
                speakerName: value.name,
                totalDuration: value.duration,
                fraction: value.duration / spokenDuration,
                colorIndex: colorIndexByKey[key] ?? fallbackColorIndex(for: key)
            )
        }

        let segments = validEntries.map { item in
            SpeakerTimelineData.Segment(
                id: item.entry.id,
                speakerKey: item.key,
                speakerName: item.name,
                startTime: item.start,
                endTime: item.end,
                startFraction: item.start / totalDuration,
                widthFraction: (item.end - item.start) / totalDuration,
                colorIndex: colorIndexByKey[item.key] ?? fallbackColorIndex(for: item.key)
            )
        }

        return SpeakerTimelineData(segments: segments, speakers: speakers, totalDuration: totalDuration)
    }

    static func fallbackColorIndex(for speakerKey: String) -> Int {
        if speakerKey == unknownSpeakerKey {
            return unknownSpeakerColorIndex
        }
        let uppercased = speakerKey.uppercased()
        if uppercased.hasPrefix("SPEAKER_"),
           let value = Int(uppercased.dropFirst(8)) {
            return value % speakerTimelineColorPalette.count
        }
        if uppercased.count == 1,
           let scalar = uppercased.unicodeScalars.first,
           scalar >= "A" && scalar <= "Z" {
            return Int(scalar.value - Unicode.Scalar("A").value) % speakerTimelineColorPalette.count
        }
        let stableHash = speakerKey.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) { result, scalar in
            (result ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }
        return Int(stableHash % UInt64(speakerTimelineColorPalette.count))
    }
}

/// Keeps the detail toolbar's language control and actions on one line when
/// they fit, then falls back to a readable leading row plus wrapping actions.
/// The fixed-size probes are deliberate: without them `ViewThatFits` sees a
/// compressible `HStack` as fitting even while button labels are clipped.
struct RecordingDetailToolbarLayout<Leading: View, Actions: View>: View {
    private let leading: Leading
    private let actions: Actions

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder actions: () -> Actions
    ) {
        self.leading = leading()
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                leadingContent
                Spacer(minLength: 10)
                actionRow
            }

            VStack(alignment: .leading, spacing: 8) {
                leadingContent
                ViewThatFits(in: .horizontal) {
                    actionRow
                    actionColumn
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var leadingContent: some View {
        leading
            .fixedSize(horizontal: true, vertical: false)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            actions
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            actions
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct RecordingDetailTabBarLayout<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 0) {
                content
            }
        }
    }
}

struct RecordingDetailView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recordingID: UUID
    @Environment(AppState.self) private var appState
    // Per-recording repair, offered for every legacyAbsolute reference
    // whether or not the old file still exists; created on demand when
    // the user starts the search.
    @State private var legacyRelink: LegacyAudioRelinkCoordinator?
    @State private var detail: RecordingDetailDTO?
    /// Resolved URL currently loaded in the player — reload compares against
    /// this, not the reference, so a root migration triggers a reload.
    @State private var loadedAudioURL: URL?
    /// Resolved once per load. Checking the file in `body` ran a `stat` on the
    /// main thread on every playback tick.
    @State private var playableAudioURL: URL?
    /// Playback-derived UI state. Written by the two observers below only when
    /// the value changes, so the page body never depends on the 4 Hz clock.
    @State private var activeTranscriptEntryID: UUID?
    @State private var activeChapterIndex: Int?
    @State private var selectedTab = 0
    @State private var audioPlayer = AudioPlayerService()
    @State private var detailLoadTracker = DetailLoadTracker()
    /// Speaker segments shown on the player scrubber. Cached per detail load
    /// (see `rebuildPlayerTimeline`) so playback ticks never rebuild it.
    @State private var playerTimeline: SpeakerTimelineData?
    /// Transcript rows with consecutive same-speaker segments merged into
    /// turns. Cached per detail load: merging concatenates the full
    /// transcript text, which must never run on 10Hz playback re-renders.
    @State private var transcriptTurns: [TranscriptDisplayEntry] = []

    // Transcript search & speaker filter (Concept C)
    @State private var transcriptQuery = ""
    @State private var speakerFilterKey: String?
    @AppStorage("transcriptFollowsPlayback") private var transcriptFollowsPlayback = true

    // Tag editing (metadata rail)
    @State private var isAddingTag = false
    @State private var newTagText = ""

    // Rename / Delete
    @State private var isEditingTitle = false
    @State private var renameText = ""
    @FocusState private var titleFieldFocused: Bool
    @State private var showDeleteAlert = false
    @AppStorage("trashRetentionDays") private var trashRetentionDays = 7

    // Summary
    @AppStorage("summaryLanguage") private var summaryLanguage: TranscriptionLanguage = .auto

    // Transcript translation
    @State private var translateLanguage: TranscriptionLanguage = .auto
    @State private var translatedText: String?
    @State private var isTranslating = false

    // Copy feedback
    @State private var copiedTab: Int?

    // Calendar linking
    @State private var linkedEvent: MeetingEventDTO?
    @State private var candidateEvents: [MeetingEventDTO] = []

    // Speaker mapping
    @State private var speakerProfiles: [SpeakerProfileDTO] = []
    @State private var newSpeakerName = ""
    @State private var speakerMappingLabel: String?

    // Action items
    @State private var newActionItemText = ""

    // Date editing
    @State private var isEditingDate = false
    @State private var editedDate = Date()
    /// Natural size of the graphical DatePicker, used to restore layout size after
    /// scaling. Seeded with the measured macOS value so the popover does not collapse
    /// to zero on its first frame.
    @State private var isPickingCalendarEvent = false
    @State private var datePickerNaturalSize = CGSize(width: 290, height: 250)
    private static let datePickerScale: CGFloat = 1.25
    @State private var dateButtonHovered = false

    /// Whether this recording is the one currently being recorded.
    private var isActiveRecording: Bool {
        appState.currentRecordingID == recordingID
            && (appState.recordingState == .recording || appState.recordingState == .paused)
    }

    private var isTranscriptionBusy: Bool {
        appState.isRetryingTranscription(for: recordingID) || appState.isProcessing(recordingID: recordingID)
    }

    private var isSummaryBusy: Bool {
        appState.isGeneratingSummary(for: recordingID) || appState.isProcessing(recordingID: recordingID)
    }

    static func moveToTrashMessage(
        retentionDays: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let format = LocalizedBundle.string(
            "The recording will stay in Trash for %lld days. After that, it is removed from the active library and its Cadenza-owned audio and derived data are deleted. Automatic recovery backups may retain a copy until rotation or explicit deletion. You can restore it before removal.",
            locale: locale
        )
        let effectiveDays = retentionDays > 0 ? retentionDays : 7
        return String(format: format, Int64(effectiveDays))
    }

    var body: some View {
        Group {
            if let detail {
                detailContent(detail)
            } else if isActiveRecording {
                recordingInProgressView
            } else if detailLoadTracker.phase == .unavailable {
                unavailableRecordingView
            } else {
                VStack {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 三态里只有 loading 分支自己撑满过；detailContent 收缩时整页跟着缩，
        // 外面那层玻璃面板就填不满窗口。统一在 Group 上撑开。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            NSLog("[RecordingDetailView] onAppear for %@", recordingID.uuidString)
            Task { await appState.store.markAccessed(recordingID: recordingID) }
            loadDetail()
            triggerBackgroundSpeakerMemory()
        }
        .onDisappear {
            audioPlayer.stop()
            // Leaving the page stops an in-flight legacy-relink traversal.
            legacyRelink?.cancel()
        }
        .onChange(of: appState.recordingState) { oldState, newState in
            if (oldState == .recording || oldState == .paused) && newState != .recording && newState != .paused {
                loadDetail()
            }
            if newState == .transcribing || newState == .summarizing {
                loadDetail()
            }
            if (oldState == .transcribing || oldState == .summarizing) && newState == .idle {
                loadDetail()
            }
        }
        .onChange(of: appState.postProcessingCompletedToken) { _, _ in
            loadDetail()
        }
        .onChange(of: appState.recordingsChangedToken) { _, _ in
            loadDetail()
        }
        .alert("Move Recording to Trash?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                appState.deleteRecording(recordingID: recordingID) { succeeded in
                    if succeeded { closeDetailTab() }
                }
            }
        } message: {
            Text(Self.moveToTrashMessage(retentionDays: trashRetentionDays, locale: locale))
        }
        .alert("New Speaker", isPresented: Binding(
            get: { speakerMappingLabel != nil },
            set: { if !$0 { speakerMappingLabel = nil; newSpeakerName = "" } }
        )) {
            TextField("Speaker Name", text: $newSpeakerName)
            Button("Cancel", role: .cancel) {
                speakerMappingLabel = nil
                newSpeakerName = ""
            }
            Button("Create") {
                let name = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let rawLabel = speakerMappingLabel else { return }
                appState.createSpeakerProfile(displayName: name) { profile in
                    if let profile {
                        appState.setSpeakerMapping(recordingID: recordingID, rawLabel: rawLabel, profileID: profile.id) {
                            loadDetail()
                        }
                    }
                }
                speakerMappingLabel = nil
                newSpeakerName = ""
            }
        } message: {
            if let label = speakerMappingLabel {
                Text("Create a speaker for \"\(label)\" and assign it.")
            }
        }
    }

    // MARK: - Recording In Progress

    @ViewBuilder
    private var recordingInProgressView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "waveform")
                .font(.cadenza(48, scale: uiScale))
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative)

            Text(appState.currentMeetingName ?? String(localized: "Recording"))
                .font(.cadenza(13 + 5, weight: .bold, scale: uiScale))

            Text("Recording in progress — \(formattedDuration)")
                .font(.cadenza(13, scale: uiScale))
                .foregroundStyle(.secondary)

            Text("Transcript and summary will appear here after the recording is stopped.")
                .font(.cadenza(13, scale: uiScale))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var formattedDuration: String {
        let d = Int(appState.recordingDuration)
        let minutes = d / 60
        let seconds = d % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var unavailableRecordingView: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "Recording Error",
                systemImage: "exclamationmark.triangle",
                description: Text("This recording is no longer available.")
            )
            HStack(spacing: 8) {
                Button("Refresh") { loadDetail() }
                    .buttonStyle(.bordered)
                Button("Back to Library") { closeDetailTab() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Reload policy, resolved-URL based; nil resolution never reloads.
    nonisolated static func playerNeedsReload(loaded: URL?, resolved: URL?) -> Bool {
        guard let resolved else { return false }
        return resolved != loaded
    }

    // MARK: - Audio Resolution

    /// Static so detached speaker-memory tasks can call it without capturing
    /// the view. Resolution failure renders the same as a missing file.
    nonisolated private static func resolvedAudioURL(_ reference: AudioFileReference?) -> URL? {
        guard let reference else { return nil }
        return try? ProfileStorageResolver.current.resolveAudio(reference)
    }

    // MARK: - Speaker Memory

    private func refreshSpeakerSuggestions(detail: RecordingDetailDTO) {
        guard SpeakerMemoryConsent.isEnabled() else { return }
        let recordingID = detail.id
        Task {
            guard let snapshot = await appState.store.fetchSpeakerAnalysisSnapshot(
                recordingID: recordingID
            ), let audioURL = Self.resolvedAudioURL(snapshot.detail.audioFile) else { return }
            let spans = snapshot.detail.transcript?.segments.compactMap { entry in
                SpeakerLabelSpan(label: entry.speaker, startTime: entry.startTime, endTime: entry.endTime)
            } ?? []
            let service = SpeakerMemoryService()
            do {
                try await service.analyze(
                    recordingID: recordingID,
                    audioURL: audioURL,
                    speakerSpans: spans,
                    speakerIdentityRevision: snapshot.speakerIdentityRevision,
                    store: appState.store
                )
                loadDetail()
            } catch {
                NSLog("[SpeakerMemory] Refresh failed: %@", "\(error)")
            }
        }
    }

    private func triggerBackgroundSpeakerMemory() {
        guard SpeakerDiarizer.shared.isEnabled else { return }
        guard SpeakerMemoryConsent.isEnabled() else { return }
        // Skip during active recording to avoid actor contention with RecordingsStore
        guard appState.recordingState == .idle else { return }
        let rid = recordingID
        guard let store = appState.store else { return }
        let state = appState
        Task.detached(priority: .utility) { [store, state] in
            guard let snapshot = await store.fetchSpeakerAnalysisSnapshot(recordingID: rid) else { return }
            let detail = snapshot.detail
            guard
                  let audioURL = Self.resolvedAudioURL(detail.audioFile),
                  let transcript = detail.transcript else { return }
            let spans = transcript.segments.compactMap { entry in
                SpeakerLabelSpan(label: entry.speaker, startTime: entry.startTime, endTime: entry.endTime)
            }
            guard !spans.isEmpty else { return }
            let hasSamples = await store.hasVoiceSamples(recordingID: rid)
            guard !hasSamples || (detail.speakerMappings.isEmpty && detail.speakerSuggestions.isEmpty) else { return }
            do {
                try await SpeakerMemoryService().analyze(
                    recordingID: rid,
                    audioURL: audioURL,
                    speakerSpans: spans,
                    speakerIdentityRevision: snapshot.speakerIdentityRevision,
                    store: store
                )
                await state.refreshRecordings()
            } catch {
                NSLog("[SpeakerMemory] Background analysis failed: %@", "\(error)")
            }
        }
    }

    // MARK: - Legacy audio relink (spec 10.3)

    /// How the repair surface introduces itself: a missing file already
    /// sits under the unavailable warning; a playable legacy row gets a
    /// calm explanation instead.
    private enum LegacyRelinkStyle {
        case residualLocation
        case missingFile
    }

    /// Repair surface for a legacyAbsolute audio reference (spec 10.3),
    /// offered whether or not the old file still exists: searches the
    /// current root by filename and rewrites this recording's reference
    /// only after an explicit per-candidate choice.
    @ViewBuilder
    private func legacyRelinkSection(
        _ audioFile: AudioFileReference, style: LegacyRelinkStyle
    ) -> some View {
        let coordinator = legacyRelink
        VStack(alignment: .leading, spacing: 6) {
            if style == .residualLocation {
                Text("This recording still points at its old location outside the storage folder. Relink it to keep everything in one place.")
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            switch coordinator?.phase {
            case nil, .idle:
                Button("Locate File…") {
                    let active = coordinator ?? LegacyAudioRelinkCoordinator.live(
                        recordingID: recordingID,
                        fileName: audioFile.lastPathComponent,
                        store: appState.store
                    )
                    legacyRelink = active
                    Task { await active.search() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .searching:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching the storage folder…")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            case .relinking:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Relinking…")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            case .noMatch:
                Text("No file with this name was found in the current storage folder.")
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.secondary)
                relinkRetryButtons(coordinator)
            case .matches(let candidates):
                if candidates.count == 1 {
                    Text("Found a matching file:")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Several files share this name. Choose the exact one:")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                // Index identity: canonically equivalent paths are equal
                // as Strings, so path-keyed IDs could collide.
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                    HStack(spacing: 8) {
                        Text(candidate.path)
                            .font(.cadenza(11, design: .monospaced, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Use This File") {
                            Task {
                                await coordinator?.adopt(candidate)
                                if case .repaired = coordinator?.phase {
                                    loadDetail()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                Button("Cancel") { coordinator?.cancel() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            case .saveFailed(let message):
                Text(message)
                    .font(.cadenza(.caption, scale: uiScale))
                    .foregroundStyle(.orange)
                relinkRetryButtons(coordinator)
            case .repaired:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Audio relinked.")
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func relinkRetryButtons(_ coordinator: LegacyAudioRelinkCoordinator?) -> some View {
        HStack(spacing: 8) {
            Button("Search Again") {
                Task { await coordinator?.search() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Cancel") { coordinator?.cancel() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }

    // MARK: - Load Detail

    private func loadDetail() {
        // Don't load detail while actively recording — there's no content yet,
        // and loading would cause a flash from the animated "recording in progress"
        // view to the static detail placeholder.
        if isActiveRecording { return }

        let request = detailLoadTracker.begin(hasContent: detail != nil)
        appState.fetchRecordingDetail(recordingID: recordingID) { dto in
            guard detailLoadTracker.finish(request: request, found: dto != nil) else { return }
            if let dto {
                detail = dto
                // Reload on resolved-URL change: a directory migration keeps
                // the relative reference but moves the file, so comparing
                // references alone would leave the player on the old root.
                let resolved = dto.audioFile.flatMap { Self.resolvedAudioURL($0) }
                playableAudioURL = resolved.flatMap {
                    FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
                }
                if Self.playerNeedsReload(loaded: loadedAudioURL, resolved: resolved),
                   let resolved {
                    audioPlayer.load(url: resolved)
                    loadedAudioURL = resolved
                }
                appState.recordingDetailTitle = dto.title
                loadLinkedEvent()
                loadSpeakerProfiles()
                rebuildPlayerTimeline()
                rebuildTranscriptTurns()

                // Lazily generate chapters when user views a recording with summary but no chapters
                if dto.summary != nil && (dto.summary?.chapters.isEmpty ?? true) {
                    appState.coordinator?.generateChaptersIfNeeded(recordingID: recordingID)
                }
            } else {
                detail = nil
                playableAudioURL = nil
                playerTimeline = nil
                transcriptTurns = []
            }
        }
    }

    private func closeDetailTab() {
        appState.closeDetail()
    }

    // MARK: - Detail Content

    /// Measured width of the detail panel; drives which side rails fit.
    @State private var detailContentWidth: CGFloat = 0

    /// The chapter rail needs the summary tab, real chapters and room.
    private func showsChapterRail(_ detail: RecordingDetailDTO) -> Bool {
        selectedTab == 0
            && !(detail.summary?.chapters.isEmpty ?? true)
            && detailContentWidth >= 940
            && !CadenzaTextScale.isAccessibilitySize(dynamicTypeSize)
    }

    /// Metadata rail (linked meeting, participants, action items, tags).
    /// Below the threshold that metadata folds back into the header.
    private var showsRightRail: Bool {
        detailContentWidth >= 1120
            && !CadenzaTextScale.isAccessibilitySize(dynamicTypeSize)
    }

    /// Fixed chrome (header, player, tab row) with a columned scroll area
    /// under it: chapter rail | content | metadata rail. The player is always
    /// visible, which is what lets it carry the speaker band and chapter
    /// marks for every tab; the old scroll-out sticky mini player is gone
    /// because nothing scrolls above the fold anymore.
    @ViewBuilder
    private func detailContent(_ detail: RecordingDetailDTO) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection(detail, compact: showsRightRail)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

            if let audioFile = detail.audioFile {
                Group {
                    if playableAudioURL != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            audioPlayerSection(detail)
                            // A playable legacyAbsolute row is still an
                            // un-converged M1 residue; the repair stays
                            // available without an alarming warning.
                            if audioFile.isLegacy {
                                legacyRelinkSection(audioFile, style: .residualLocation)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                                Text("Audio file unavailable — it may have been removed to free storage.")
                                    .font(.cadenza(.caption, scale: uiScale))
                                    .foregroundStyle(.secondary)
                            }
                            if audioFile.isLegacy {
                                legacyRelinkSection(audioFile, style: .missingFile)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            Divider()

            tabRow(detail)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                if showsChapterRail(detail) {
                    chapterRail(detail)
                        .frame(width: 200)
                    Divider()
                }

                ScrollView {
                    Group {
                        switch selectedTab {
                        case 0:
                            // Cap the reading measure only when there is
                            // something to read: at full panel width the
                            // summary ran ~1000pt lines, but empty and
                            // in-progress states should center in the column
                            // instead of hugging a leading 720pt cage.
                            if detail.summary != nil
                                || appState.quickSummaryResult(for: recordingID) != nil {
                                summaryContent(detail)
                                    .frame(maxWidth: 720, alignment: .leading)
                            } else {
                                summaryContent(detail)
                                    .frame(maxWidth: .infinity, minHeight: 420)
                            }
                        case 1:
                            if detail.summary?.actionItems.isEmpty == false {
                                actionItemsContent(detail)
                                    .frame(maxWidth: 720, alignment: .leading)
                            } else {
                                actionItemsContent(detail)
                                    .frame(maxWidth: .infinity, minHeight: 420)
                            }
                        case 2: transcriptContent(detail)
                        default: EmptyView()
                        }
                    }
                    .transition(reduceMotion ? .identity : .opacity)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                // Commit inline title editing when tapping empty space: on macOS clicking a
                // non-interactive area does not resign first responder on its own, so the field
                // would stay in edit mode. Child views still receive their own taps first.
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isEditingTitle else { return }
                    commitRename()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }

                if showsRightRail {
                    Divider()
                    rightRail(detail)
                        .frame(width: 236)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            detailContentWidth = width
        }
    }

    // MARK: - Tab Row

    /// One row: the tab cluster leads, the active tab's actions trail. The
    /// old layout spent a full row on tabs and another on the toolbar; the
    /// toolbar-layout wrapper still reflows everything at narrow widths and
    /// accessibility sizes.
    @ViewBuilder
    private func tabRow(_ detail: RecordingDetailDTO) -> some View {
        RecordingDetailToolbarLayout {
            RecordingDetailTabBarLayout {
                tabButton("Summary", icon: "sparkles", index: 0)
                tabButton("Action Items", icon: "checklist", index: 1, badge: openActionItemCount(detail))
                tabButton("Transcript", icon: "text.bubble", index: 2)
            }
        } actions: {
            if selectedTab == 0 {
                if !showsChapterRail(detail), let chapters = detail.summary?.chapters, !chapters.isEmpty {
                    Menu {
                        ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                            Button {
                                audioPlayer.seek(to: chapter.startSeconds)
                                if !audioPlayer.isPlaying {
                                    audioPlayer.play()
                                }
                            } label: {
                                Text(verbatim: "\(formatTime(chapter.startSeconds))  \(chapter.title)")
                            }
                        }
                    } label: {
                        Label("Chapters", systemImage: "list.bullet")
                    }
                    .fixedSize()
                }
                summaryToolbarControls(detail)
            } else if selectedTab == 2 {
                transcriptToolbarControls(detail)
            }
        }
    }

    private func openActionItemCount(_ detail: RecordingDetailDTO) -> Int {
        (detail.summary?.actionItems ?? []).count { !$0.isCompleted }
    }

    private func tabButton(_ title: LocalizedStringKey, icon: String, index: Int, badge: Int = 0) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.15)) {
                selectedTab = index
            }
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.cadenza(13, scale: uiScale))
                    Text(title)
                        .font(.cadenza(13, weight: .medium, scale: uiScale))
                    if badge > 0 {
                        Text(verbatim: "\(badge)")
                            .font(.cadenza(13 - 4, weight: .bold, scale: uiScale))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .foregroundStyle(selectedTab == index ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())

                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .opacity(selectedTab == index ? 1 : 0)
            }
            .fixedSize()
        }
        .buttonStyle(.cadenzaPlain)
    }

    // MARK: - Chapter Rail

    /// Clickable chapter navigation that follows playback. Chapter descriptions
    /// are available on hover without repeating them in the summary body.
    private func chapterRail(_ detail: RecordingDetailDTO) -> some View {
        let chapters = detail.summary?.chapters ?? []
        let activeIndex = activeChapterIndex
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                PlaybackChapterObserver(
                    player: audioPlayer, chapters: chapters, activeIndex: $activeChapterIndex
                )
                Text("Chapters")
                    .font(.cadenza(10, weight: .bold, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)

                ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                    let isActive = index == activeIndex
                    Button {
                        audioPlayer.seek(to: chapter.startSeconds)
                        if !audioPlayer.isPlaying {
                            audioPlayer.play()
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(formatTime(chapter.startSeconds))
                                .font(.cadenza(10, design: .monospaced, scale: uiScale))
                                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                                .fixedSize(horizontal: true, vertical: false)
                            Text(chapter.title)
                                .font(.cadenza(12, weight: isActive ? .semibold : .regular, scale: uiScale))
                                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isActive ? Color.accentColor.opacity(0.12) : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.cadenzaPlain)
                    .help(chapter.summary.isEmpty ? chapter.title : chapter.summary)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Metadata Rail

    /// Right-hand metadata rail: linked meeting, participants, action-item
    /// progress and tags. Everything here is a relocation, not an addition;
    /// when the rail doesn't fit, the same controls fold back into the
    /// header and tab contents.
    private func rightRail(_ detail: RecordingDetailDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                railCard("Linked Meeting") {
                    calendarLinkRow(detail, stacked: true)
                        .font(.cadenza(13 - 1, scale: uiScale))
                }

                if let speakers = playerTimeline?.speakers, !speakers.isEmpty {
                    railCard("Participants") {
                        ForEach(speakers.prefix(4)) { speaker in
                            participantRow(speaker)
                        }
                    }
                }

                if let items = detail.summary?.actionItems, !items.isEmpty {
                    railCard("Action Items") {
                        actionItemsProgress(items)
                    }
                }

                railCard("Tags") {
                    tagsCardContent(detail)
                }
            }
            .padding(12)
        }
    }

    private func railCard<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.cadenza(10, weight: .bold, scale: uiScale))
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCollectionCard(cornerRadius: 10)
    }

    /// Tapping a participant jumps to the transcript filtered to them.
    private func participantRow(_ speaker: SpeakerTimelineData.SpeakerSummary) -> some View {
        Button {
            speakerFilterKey = speaker.speakerKey
            withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.15)) {
                selectedTab = 2
            }
        } label: {
            HStack(spacing: 7) {
                speakerInitialAvatar(
                    name: speaker.speakerName,
                    color: speakerTimelineColor(for: speaker.colorIndex),
                    diameter: 20
                )
                Text(speaker.speakerName)
                    .font(.cadenza(13 - 1, scale: uiScale))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: "\(Int((speaker.fraction * 100).rounded()))%")
                    .font(.cadenza(13 - 3, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.cadenzaPlain)
        .help("Show only this speaker")
    }

    private func speakerInitialAvatar(name: String, color: Color, diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
            Text(verbatim: String(name.prefix(1)).uppercased())
                .font(.cadenza(diameter * 0.42, weight: .bold, scale: 1))
                .foregroundStyle(color)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func actionItemsProgress(_ items: [ActionItemDTO]) -> some View {
        let doneCount = items.count(where: \.isCompleted)
        HStack {
            ProgressView(value: Double(doneCount), total: Double(max(items.count, 1)))
                .controlSize(.small)
            Text(verbatim: "\(doneCount) / \(items.count)")
                .font(.cadenza(13 - 3, scale: uiScale))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }

        ForEach(items.filter { !$0.isCompleted }.prefix(2)) { item in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    appState.toggleActionItem(recordingID: recordingID, actionItemID: item.id)
                    loadDetail()
                } label: {
                    Image(systemName: "circle")
                        .font(.cadenza(13 - 2, scale: uiScale))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.cadenzaPlain)
                Text(item.task)
                    .font(.cadenza(13 - 2, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }

        Button {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.15)) {
                selectedTab = 1
            }
        } label: {
            Text("View All")
                .font(.cadenza(13 - 2, weight: .semibold, scale: uiScale))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.cadenzaPlain)
    }

    @ViewBuilder
    private func tagsCardContent(_ detail: RecordingDetailDTO) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(detail.tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Circle()
                        .fill(RecordingCardView.tagColor(for: tag))
                        .frame(width: 5, height: 5)
                        .padding(.trailing, 2)
                        .accessibilityHidden(true)
                    Text(tag)
                    Button {
                        appState.removeTag(recordingID: recordingID, tag: tag)
                        self.detail?.tags.removeAll { $0 == tag }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.cadenza(7, weight: .bold, scale: uiScale))
                    }
                    .buttonStyle(.cadenzaPlain)
                }
                .font(.cadenza(13 - 2, scale: uiScale))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.fill.tertiary, in: Capsule())
            }

            Button {
                newTagText = ""
                isAddingTag = true
            } label: {
                Image(systemName: "plus")
                    .font(.cadenza(13 - 3, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.fill.tertiary, in: Capsule())
            }
            .buttonStyle(.cadenzaPlain)
            .help("Add Tag")
            .popover(isPresented: $isAddingTag, arrowEdge: .bottom) {
                HStack(spacing: 6) {
                    TextField("Add Tag", text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .onSubmit { commitNewTag() }
                    Button {
                        commitNewTag()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(10)
            }
        }
    }

    private func commitNewTag() {
        let tag = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        appState.addTag(recordingID: recordingID, tag: tag)
        newTagText = ""
        isAddingTag = false
    }

    // MARK: - Transcript Toolbar

    /// Transcript actions for the unified tab row: language, re-transcribe,
    /// speaker identification, copy, export. Emitted as siblings so the
    /// enclosing toolbar layout can reflow them.
    @ViewBuilder
    private func transcriptToolbarControls(_ detail: RecordingDetailDTO) -> some View {
            if detail.transcript != nil {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.cadenza(13, scale: uiScale))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $translateLanguage) {
                        Text("Original").tag(TranscriptionLanguage.auto)
                        Divider()
                        ForEach(TranscriptionLanguage.allCases.filter { $0 != .auto }) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 130)
                    .disabled(!appState.startupPolicy.allowsContentGeneration)
                    .onChange(of: translateLanguage) { _, newLang in
                        if newLang == .auto {
                            translatedText = nil
                        } else {
                            Task { await translateTranscript(to: newLang) }
                        }
                    }

                    if isTranslating {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if detail.audioFile != nil {
                Button {
                    appState.retryTranscription(recordingID: recordingID)
                } label: {
                    if isTranscriptionBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Transcribing...")
                        }
                    } else {
                        Label("Re-transcribe", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    isTranscriptionBusy
                        || !appState.startupPolicy.allowsContentGeneration
                )
                .help(isTranscriptionBusy ? String(localized: "Transcribing...") : String(localized: "Re-transcribe"))
            }

            if detail.audioFile != nil
                && detail.transcript != nil
                && SpeakerDiarizer.shared.isEnabled
                && SpeakerMemoryConsent.isEnabled() {
                Button {
                    refreshSpeakerSuggestions(detail: detail)
                } label: {
                    Label("Identify speakers", systemImage: "brain.head.profile")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(String(localized: "Refresh speaker identification"))
            }

            Button {
                copyTranscript()
            } label: {
                Label(copiedTab == 0 ? "Copied" : "Copy", systemImage: copiedTab == 0 ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(detail.transcript == nil && translatedText == nil)
            .help(copiedTab == 0 ? String(localized: "Copied") : String(localized: "Copy"))

            exportMenu
    }

    // MARK: - Summary Toolbar

    /// Summary actions for the unified tab row: language, regenerate, copy,
    /// export. Emitted as siblings so the toolbar layout can reflow them.
    @ViewBuilder
    private func summaryToolbarControls(_ detail: RecordingDetailDTO) -> some View {
            if detail.transcript != nil {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.cadenza(13, scale: uiScale))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $summaryLanguage) {
                        ForEach(TranscriptionLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 130)
                    .disabled(
                        isSummaryBusy
                            || !appState.startupPolicy.allowsContentGeneration
                    )
                    .onChange(of: summaryLanguage) { _, newLang in
                        regenerateSummary(language: newLang)
                    }
                }
            }

            if detail.transcript != nil {
                Button {
                    regenerateSummary(language: summaryLanguage)
                } label: {
                    if isSummaryBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Generating…")
                        }
                    } else {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    isSummaryBusy
                        || !appState.startupPolicy.allowsContentGeneration
                )
                .help(isSummaryBusy ? String(localized: "Generating…") : String(localized: "Regenerate"))
            }

            Button {
                copySummary()
            } label: {
                Label(copiedTab == 1 ? "Copied" : "Copy", systemImage: copiedTab == 1 ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(detail.summary == nil)
            .help(copiedTab == 1 ? String(localized: "Copied") : String(localized: "Copy"))

            exportMenu
    }

    // MARK: - Export Menu

    @ViewBuilder
    private var exportMenu: some View {
        Menu {
            Button {
                Task { await runExport(provider: .notion) }
            } label: {
                Label("Notion", systemImage: "arrow.up.doc")
            }
            .disabled(!appState.notionConnected)

            Button {
                Task { await runExport(provider: .craft) }
            } label: {
                Label("Craft", systemImage: "doc.richtext")
            }
            .disabled(!appState.craftIsAvailable)

            Divider()

            Button {
                exportTranscriptFile(.txt)
            } label: {
                Label("Transcript (.txt)", systemImage: "doc.plaintext")
            }
            .disabled(detail?.transcript == nil)

            Button {
                exportTranscriptFile(.srt)
            } label: {
                Label("Subtitles (.srt)", systemImage: "captions.bubble")
            }
            .disabled(detail?.transcript == nil)

            Button {
                exportTranscriptFile(.markdown)
            } label: {
                Label("Transcript (.md)", systemImage: "doc.text")
            }
            .disabled(detail?.transcript == nil)

            Button {
                exportSummaryFile()
            } label: {
                Label("Summary (.md)", systemImage: "doc.badge.ellipsis")
            }
            .disabled(detail?.summary == nil)

            Button {
                exportAudioFile()
            } label: {
                Label("Audio (.m4a)", systemImage: "waveform")
            }
            .disabled(detail?.audioFile == nil)
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        // Bordered like its Regenerate/Copy neighbours in the tab row —
        // the borderless variant floated bare next to bordered buttons.
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help(String(localized: "Export"))
    }

    /// Single-recording export entry point. Replaced the prior alert-
    /// driven flow (which surfaced `error.localizedDescription` straight
    /// — yielding `Cadenza.CadenzaAPIError 错误 0` for envelope
    /// failures) with a top-anchored toast. Success now emits a green
    /// confirmation capsule the user actually sees; failure emits a
    /// red capsule whose text comes from the fail-closed export presentation
    /// mapper (localized §6.5 code or a stable generic fallback).
    private func runExport(provider: ExportProvider) async {
        let target = provider.localizedName
        do {
            switch provider {
            case .notion: try await appState.exportToNotion(recordingID: recordingID)
            case .craft:  try await appState.exportToCraft(recordingID: recordingID)
            }
            ToastCenter.shared.success(
                String(localized: "Exported to \(target)")
            )
        } catch {
            NSLog("[RecordingDetail] %@ export failed: %@", target, String(describing: error))
            ToastCenter.shared.error(
                String(localized: "Export to \(target) failed"),
                subtitle: ExportUserMessage.message(for: error)
            )
        }
    }

    private enum ExportProvider {
        case notion, craft
        var localizedName: String {
            switch self {
            case .notion: return "Notion"
            case .craft:  return "Craft"
            }
        }
    }

    // MARK: - Local File Export

    private enum LocalTranscriptFormat {
        case txt, srt, markdown
        var fileExtension: String {
            switch self {
            case .txt: return "txt"
            case .srt: return "srt"
            case .markdown: return "md"
            }
        }
    }

    // 菜单禁用只看 DB 字段（body 求值不做文件系统 stat——网络卷会卡主线程）；
    // 文件是否真的存在在点击时检查。

    private func exportTranscriptFile(_ format: LocalTranscriptFormat) {
        guard let detail, let transcript = detail.transcript else { return }
        let content: String
        switch format {
        case .txt:
            content = ExportContentRenderer.transcriptText(transcript, mappings: detail.speakerMappings)
        case .srt:
            content = ExportContentRenderer.transcriptSRT(transcript, mappings: detail.speakerMappings)
        case .markdown:
            content = ExportContentRenderer.transcriptMarkdown(transcript, detail: detail)
        }
        // .md 与摘要同扩展名，加后缀避免同目录导出时互相覆盖
        let base = ExportContentRenderer.exportDirectoryName(for: detail)
            + (format == .markdown ? " - Transcript" : "")
        saveTextFile(content, suggestedName: "\(base).\(format.fileExtension)")
    }

    private func exportSummaryFile() {
        guard let detail, let summary = detail.summary else { return }
        let base = ExportContentRenderer.exportDirectoryName(for: detail) + " - Summary"
        saveTextFile(
            ExportContentRenderer.summaryMarkdown(summary, detail: detail),
            suggestedName: "\(base).md"
        )
    }

    private func exportAudioFile() {
        guard let detail, let audioFile = detail.audioFile else { return }
        guard let source = Self.resolvedAudioURL(audioFile),
              FileManager.default.fileExists(atPath: source.path) else {
            ToastCenter.shared.error(
                String(localized: "File export failed"),
                subtitle: String(localized: "The audio file for this recording could not be found.")
            )
            return
        }
        do {
            if let url = try ExportSavePanel.copyFile(
                from: source,
                suggestedName: ExportContentRenderer.exportDirectoryName(for: detail) + ".m4a"
            ) {
                ToastCenter.shared.success(String(localized: "File exported"), subtitle: url.lastPathComponent)
            }
        } catch {
            NSLog("[RecordingDetail] audio file export failed: %@", String(describing: error))
            ToastCenter.shared.error(
                String(localized: "File export failed"),
                subtitle: ExportUserMessage.message(for: error)
            )
        }
    }

    private func saveTextFile(_ content: String, suggestedName: String) {
        do {
            if let url = try ExportSavePanel.saveText(content, suggestedName: suggestedName) {
                ToastCenter.shared.success(String(localized: "File exported"), subtitle: url.lastPathComponent)
            }
        } catch {
            NSLog("[RecordingDetail] text file export failed: %@", String(describing: error))
            ToastCenter.shared.error(
                String(localized: "File export failed"),
                subtitle: ExportUserMessage.message(for: error)
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    /// `compact` hides tags and the calendar link: with the metadata rail
    /// visible they live there instead, and the header stays two lines.
    private func headerSection(_ detail: RecordingDetailDTO, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isEditingTitle {
                    TextField("Title", text: $renameText, onCommit: {
                        commitRename()
                    })
                    .font(.cadenza(13 + 5, weight: .bold, scale: uiScale))
                    .textFieldStyle(.plain)
                    .focused($titleFieldFocused)
                    .onChange(of: titleFieldFocused) { _, focused in
                        if !focused {
                            commitRename()
                        }
                    }
                    .onExitCommand {
                        isEditingTitle = false
                    }
                } else {
                    Text(detail.title)
                        .font(.cadenza(13 + 5, weight: .bold, scale: uiScale))
                        .onTapGesture(count: 2) {
                            beginRename()
                        }
                }

                if !isEditingTitle {
                    IconHoverButton(title: "Rename", icon: "pencil", color: .secondary) {
                        beginRename()
                    }
                }

                if let typeRaw = detail.meetingType,
                   let type = MeetingType(rawValue: typeRaw),
                   type != .general {
                    Text(type.displayName)
                        .font(.cadenza(13 - 1, weight: .medium, scale: uiScale))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.12), in: Capsule())
                }

                Spacer()

                DeleteButton { showDeleteAlert = true }
            }

            // Tags
            if !compact, !detail.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(detail.tags, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(RecordingCardView.tagColor(for: tag))
                                .frame(width: 5, height: 5)
                                .padding(.trailing, 2)
                                .accessibilityHidden(true)
                            Text(tag)
                            Button {
                                appState.removeTag(recordingID: recordingID, tag: tag)
                                self.detail?.tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.cadenza(7, weight: .bold, scale: uiScale))
                            }
                            .buttonStyle(.cadenzaPlain)
                        }
                        .font(.cadenza(13, scale: uiScale))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.fill.tertiary, in: Capsule())
                    }
                }
            }

            // Metadata rows share one leading alignment guide, one font and one foreground
            // style from this container. Rows must not add their own horizontal padding or
            // offsets to line up — matching structure is the only alignment mechanism here.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Button {
                        editedDate = detail.startDate
                        isEditingDate = true
                    } label: {
                        // Same structure as the calendar-link row below. `Label` is not
                        // usable here: its icon column is wider than the glyph, so the two
                        // rows' icons would start at different x positions.
                        HStack(spacing: 5) {
                            Image(systemName: "calendar")
                            Text(dateString(detail.startDate))
                        }
                        .foregroundStyle(dateButtonHovered ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.cadenzaPlain)
                    .onHover { dateButtonHovered = $0 }
                    .popover(isPresented: $isEditingDate, arrowEdge: .bottom) {
                        dateEditPopover
                    }
                    Label(durationString(detail.duration), systemImage: "clock")
                    if let app = detail.meetingApp {
                        Label(app, systemImage: "video")
                    }
                }

                if !compact {
                    calendarLinkRow(detail)
                }
            }
            .font(.cadenza(13, scale: uiScale))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Calendar Link

    /// Uses `Button` + `popover`, never `Menu`: a `.menuStyle(.borderlessButton)` label is
    /// laid out by AppKit inside its own button box, which adds an inset SwiftUI cannot see
    /// or offset (its label reports `minX == 0` in global coordinates). Matching the date
    /// row's `Button` + `HStack` structure is what keeps the two calendar icons aligned.
    @ViewBuilder
    private func calendarLinkRow(_ detail: RecordingDetailDTO, stacked: Bool = false) -> some View {
        Button {
            isPickingCalendarEvent = true
        } label: {
            if stacked {
                // Rail variant: the 236pt column cannot fit title and time side
                // by side, so the title keeps up to two full lines and the time
                // drops underneath (concept B's card anatomy).
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "calendar")
                        .foregroundStyle(linkedEvent != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .padding(.top, 1)
                    if let event = linkedEvent {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(eventTimeString(event))
                                .font(.cadenza(12, scale: uiScale))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Link Meeting")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.cadenza(13 - 4, scale: uiScale))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                }
                .font(.cadenza(13, scale: uiScale))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 5) {
                    // Same glyph as the date row: `calendar.badge.checkmark` has a wider and
                    // taller bounding box, which no amount of padding can bring back into line.
                    // The linked state is carried by the tint colour instead.
                    Image(systemName: "calendar")
                        .foregroundStyle(linkedEvent != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    if let event = linkedEvent {
                        Text(event.title)
                            .lineLimit(1)
                        Text(eventTimeString(event))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Link Meeting")
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.cadenza(13 - 4, scale: uiScale))
                        .foregroundStyle(.tertiary)
                }
                .font(.cadenza(13, scale: uiScale))
            }
        }
        .buttonStyle(.cadenzaPlain)
        .popover(isPresented: $isPickingCalendarEvent, arrowEdge: .bottom) {
            calendarEventPickerPopover
        }
        .onAppear {
            loadCandidateEvents(detail)
        }
    }

    private var calendarEventPickerPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            if candidateEvents.isEmpty {
                Text("No nearby calendar events")
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
            }

            // The candidate query returns every non-all-day event of the day, so the
            // list is unbounded — scroll it instead of growing the popover off-screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidateEvents) { event in
                        let isLinked = detail?.linkedCalendarEventID == event.id
                        Button {
                            appState.linkCalendarEvent(recordingID: recordingID, event: event)
                            detail?.linkedCalendarEventID = event.id
                            linkedEvent = event
                            isPickingCalendarEvent = false
                        } label: {
                            HStack(spacing: 6) {
                                // Decorative: selection is exposed through `.isSelected`
                                // below, so VoiceOver must not read this glyph as content.
                                Image(systemName: "checkmark")
                                    .font(.cadenza(11, weight: .bold, scale: uiScale))
                                    .opacity(isLinked ? 1 : 0)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.title)
                                        .lineLimit(1)
                                    Text(eventTimeString(event))
                                        .font(.cadenza(12, scale: uiScale))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .font(.cadenza(13, scale: uiScale))
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.cadenzaPlain(in: RoundedRectangle(cornerRadius: 6)))
                        .accessibilityLabel(Text(verbatim: "\(event.title) \(eventTimeString(event))"))
                        .accessibilityAddTraits(isLinked ? [.isSelected] : [])
                    }
                }
            }
            .frame(maxHeight: 280)
            .scrollBounceBehavior(.basedOnSize)

            if linkedEvent != nil {
                Divider()
                    .padding(.vertical, 4)
                Button(role: .destructive) {
                    appState.linkCalendarEvent(recordingID: recordingID, calendarEventID: nil)
                    detail?.linkedCalendarEventID = nil
                    linkedEvent = nil
                    isPickingCalendarEvent = false
                } label: {
                    Label("Remove Link", systemImage: "minus.circle")
                        .font(.cadenza(13, scale: uiScale))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.cadenzaPlain(in: RoundedRectangle(cornerRadius: 6)))
            }
        }
        .padding(8)
        .frame(width: 320)
    }

    private func loadCandidateEvents(_ detail: RecordingDetailDTO) {
        candidateEvents = appState.fetchCandidateEvents(
            around: detail.startDate,
            endDate: detail.endDate
        )
        loadLinkedEvent()
    }

    private func loadLinkedEvent() {
        guard let detail else { linkedEvent = nil; return }
        linkedEvent = CalendarLinkResolver.linkedEvent(
            linkedCalendarEventID: detail.linkedCalendarEventID,
            candidateEvents: candidateEvents
        ) { eventID in
            appState.fetchLinkedCalendarEvent(
                calendarEventID: eventID,
                around: detail.startDate,
                endDate: detail.endDate
            )
        }
    }

    private func priorityColor(_ priority: ActionPriority) -> Color {
        switch priority {
        case .high: .red
        case .medium: .orange
        case .low: .blue
        }
    }

    private func eventTimeString(_ event: MeetingEventDTO) -> String {
        LocalizedDateFormatting.interval(
            from: event.startDate,
            to: event.endDate,
            dateStyle: .none,
            timeStyle: .short,
            locale: locale
        )
    }

    // MARK: - Action Items

    @ViewBuilder
    private func actionItemsContent(_ detail: RecordingDetailDTO) -> some View {
        let items = detail.summary?.actionItems ?? []

        if items.isEmpty && detail.summary == nil {
            VStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.cadenza(.largeTitle, scale: uiScale))
                    .foregroundStyle(.quaternary)
                Text("Action items will appear after the summary is generated.")
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    actionItemRow(item)
                }

                // Add new item
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                    TextField("Add action item...", text: $newActionItemText)
                        .textFieldStyle(.plain)
                        .font(.cadenza(13, scale: uiScale))
                        .onSubmit {
                            let text = newActionItemText.trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty else { return }
                            appState.addActionItem(recordingID: recordingID, task: text)
                            newActionItemText = ""
                            loadDetail()
                        }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func actionItemRow(_ item: ActionItemDTO) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                appState.toggleActionItem(recordingID: recordingID, actionItemID: item.id)
                loadDetail()
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isCompleted ? .green : .secondary)
                    .font(.cadenza(13 + 2, scale: uiScale))
            }
            .buttonStyle(.cadenzaPlain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.task)
                    .font(.cadenzaBody(13, scale: uiScale))
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)

                HStack(spacing: 8) {
                    if let assignee = item.assignee, !assignee.isEmpty {
                        Label(assignee, systemImage: "person")
                    }
                    if let deadline = item.deadline, !deadline.isEmpty {
                        Label(deadline, systemImage: "calendar.badge.clock")
                    }
                    let priority = ActionPriority(rawValue: item.priority) ?? .medium
                    Label(priority.displayName, systemImage: priority.icon)
                        .foregroundStyle(priorityColor(priority))
                }
                .font(.cadenza(13 - 2, scale: uiScale))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - Audio Player

    @ViewBuilder
    /// Speaker-annotated scrubber (Concept B): the play bar carries who is
    /// speaking, the chapter marks and the playhead, so the timeline reads
    /// the same from every tab instead of living inside the transcript.
    private func audioPlayerSection(_ detail: RecordingDetailDTO) -> some View {
        // The only view on the page that reads the playback clock directly.
        PlaybackControlsBar(
            player: audioPlayer,
            segments: playerTimeline?.segments ?? [],
            chapters: detail.summary?.chapters ?? [],
            formatTime: formatTime
        )
    }

    /// Play/pause, the two time labels, the scrubber and the rate menu. Kept
    /// in its own struct so the 4 Hz `currentTime` write re-evaluates this
    /// small body instead of the whole detail page (which used to re-run the
    /// transcript filter, the speaker map and a file `stat` on every tick).
    private struct PlaybackControlsBar: View {
        @Environment(\.uiScale) private var uiScale: CGFloat
        let player: AudioPlayerService
        let segments: [SpeakerTimelineData.Segment]
        let chapters: [ChapterDTO]
        let formatTime: (TimeInterval) -> String

        var body: some View {
            HStack(spacing: 12) {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.cadenza(.title, scale: uiScale))
                }
                .buttonStyle(.cadenzaPlain)

                Text(formatTime(player.currentTime))
                    .font(.cadenza(13, design: .monospaced, scale: uiScale))
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .trailing)

                SpeakerAnnotatedScrubber(
                    duration: max(player.duration, 0.01),
                    currentTime: player.currentTime,
                    segments: segments,
                    chapters: chapters,
                    formatTime: formatTime,
                    onSeek: { player.seek(to: $0) }
                )

                Text(formatTime(player.duration))
                    .font(.cadenza(13, design: .monospaced, scale: uiScale))
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .leading)

                PlaybackRateMenuView(player: player, fontSize: 13)
            }
            .padding(.vertical, 4)
        }
    }

    /// Zero-size view that turns the playback clock into "which transcript
    /// row is active", writing the parent's state only on change. Rows compare
    /// against that id instead of reading `currentTime` themselves.
    private struct PlaybackEntryObserver: View {
        let player: AudioPlayerService
        let entries: [TranscriptDisplayEntry]
        @Binding var activeID: UUID?

        private var currentActiveID: UUID? {
            guard player.isPlaying else { return nil }
            let t = player.currentTime
            return entries.first(where: { t >= $0.startTime && t < $0.endTime })?.id
        }

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .onChange(of: currentActiveID, initial: true) { _, newID in
                    if activeID != newID { activeID = newID }
                }
        }
    }

    /// Same idea for the chapter rail: the chapter containing the playhead,
    /// paused or not, published only when it changes.
    private struct PlaybackChapterObserver: View {
        let player: AudioPlayerService
        let chapters: [ChapterDTO]
        @Binding var activeIndex: Int?

        private var currentActiveIndex: Int? {
            guard !chapters.isEmpty else { return nil }
            let t = player.currentTime
            var active = 0
            for (index, chapter) in chapters.enumerated() where chapter.startSeconds <= t {
                active = index
            }
            return active
        }

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .onChange(of: currentActiveIndex, initial: true) { _, newIndex in
                    if activeIndex != newIndex { activeIndex = newIndex }
                }
        }
    }

    /// Merges consecutive segments of the same speaker into one turn, so the
    /// transcript scans as a conversation instead of a run of fragments.
    /// Speakerless entries stay untouched: those come from the plain-text
    /// chunker, whose splits exist purely for readability.
    private func rebuildTranscriptTurns() {
        guard let detail, let transcript = detail.transcript else {
            transcriptTurns = []
            return
        }
        let entries = displayTranscriptEntries(for: transcript, duration: detail.duration)
        var turns: [TranscriptDisplayEntry] = []
        turns.reserveCapacity(entries.count)
        for entry in entries {
            // The ~120s/~800-char cap keeps a long same-speaker stretch from
            // rendering as one wall of text; the stored segments underneath
            // are already capped at 30s/500 chars by the diarizer merge.
            guard let speaker = entry.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !speaker.isEmpty,
                  let last = turns.last,
                  let lastSpeaker = last.speaker,
                  transcriptTurnKey(lastSpeaker) == transcriptTurnKey(speaker),
                  entry.endTime - last.startTime <= 120,
                  last.text.count <= 800
            else {
                turns.append(entry)
                continue
            }
            turns[turns.count - 1] = TranscriptDisplayEntry(
                id: last.id,
                startTime: last.startTime,
                endTime: max(last.endTime, entry.endTime),
                text: "\(last.text) \(entry.text)",
                speaker: last.speaker,
                mergedCount: last.mergedCount + 1
            )
        }
        transcriptTurns = turns
    }

    private func transcriptTurnKey(_ rawLabel: String) -> String {
        speakerTimelineIdentityKey(rawLabel: rawLabel) ?? rawLabel
    }

    /// Speaker filter and in-transcript search, applied to the cached turns.
    private func visibleTranscriptTurns() -> [TranscriptDisplayEntry] {
        var result = transcriptTurns
        if let speakerFilterKey {
            result = result.filter { entry in
                guard let speaker = entry.speaker else { return false }
                return transcriptTurnKey(speaker) == speakerFilterKey
            }
        }
        let query = transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.text.localizedCaseInsensitiveContains(query) }
        }
        return result
    }

    /// Search, speaker filter chips and the follow-playback switch on one
    /// row. The chips double as the speaking-share legend, replacing the old
    /// distribution card (the band itself lives on the player now).
    private func transcriptFilterBar(_ timeline: SpeakerTimelineData) -> some View {
        HStack(spacing: 8) {
            transcriptSearchField

            Divider()
                .frame(height: 18)

            ForEach(timeline.speakers.prefix(4)) { speaker in
                let isFilterable = speaker.speakerKey != SpeakerTimelineBuilder.unknownSpeakerKey
                let chip = SpeakerShareChip(
                    speaker: speaker,
                    color: speakerTimelineColor(for: speaker.colorIndex),
                    percentString: "\(Int((speaker.fraction * 100).rounded()))%",
                    isSelected: speakerFilterKey == speaker.speakerKey,
                    isDimmed: speakerFilterKey != nil && speakerFilterKey != speaker.speakerKey
                )
                .fixedSize()

                if isFilterable {
                    Button {
                        if speakerFilterKey == speaker.speakerKey {
                            speakerFilterKey = nil
                        } else {
                            speakerFilterKey = speaker.speakerKey
                        }
                    } label: {
                        chip
                    }
                    .buttonStyle(.cadenzaPlain)
                    .help("Show only this speaker")
                    .accessibilityValue(
                        speakerFilterKey == speaker.speakerKey
                            ? Text("Selected") : Text("Not selected")
                    )
                } else {
                    chip
                }
            }

            Spacer(minLength: 8)

            Toggle(isOn: $transcriptFollowsPlayback) {
                Text("Follow playback")
                    .font(.cadenza(13 - 2, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
        }
    }

    private var transcriptSearchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search transcript", text: $transcriptQuery)
                .textFieldStyle(.plain)
                .font(.cadenza(12, scale: uiScale))
                .accessibilityLabel("Search transcript")
            if !transcriptQuery.isEmpty {
                Button {
                    transcriptQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.cadenza(11, scale: uiScale))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.cadenzaPlain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppStyle.ColorToken.softFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(AppStyle.ColorToken.stroke, lineWidth: 0.75)
        )
    }

    /// Rebuilt only when `detail` is (re)loaded: speaker mappings and
    /// suggestions all live on the DTO, and every mutation funnels through
    /// `loadDetail`. Playback ticks must never rebuild the segment model.
    private func rebuildPlayerTimeline() {
        guard let detail, let transcript = detail.transcript else {
            playerTimeline = nil
            return
        }
        playerTimeline = SpeakerTimelineBuilder.build(
            entries: transcript.segments,
            recordingDuration: detail.duration,
            displayName: { rawLabel in
                guard let rawLabel else { return String(localized: "Unknown") }
                return resolvedSpeakerName(rawLabel: rawLabel)
            },
            identityKey: { rawLabel in
                speakerTimelineIdentityKey(rawLabel: rawLabel)
            }
        )
    }

    // MARK: - Speaker-Annotated Scrubber

    /// Replaces the plain `Slider`: a speaker-colored band with chapter tick
    /// marks and a draggable playhead. Drawing goes through one `Canvas` pass
    /// so playback ticks repaint cheaply even with hundreds of segments; the
    /// chapter tooltips are thin invisible hover targets layered above it.
    private struct ScrubberTrackCanvas: View, Equatable {
        let duration: TimeInterval
        let segments: [SpeakerTimelineData.Segment]
        let chapters: [ChapterDTO]

        static func chapterFraction(_ chapter: ChapterDTO, duration: TimeInterval) -> Double? {
            guard duration > 0, chapter.startSeconds.isFinite else { return nil }
            let fraction = chapter.startSeconds / duration
            guard fraction >= 0, fraction <= 1 else { return nil }
            return fraction
        }

        var body: some View {
            Canvas { context, size in
                // Chapter ticks above the band (drawn before the band
                // clip narrows the context).
                for chapter in chapters {
                    guard let fraction = Self.chapterFraction(chapter, duration: duration) else { continue }
                    let tick = CGRect(x: fraction * size.width - 1, y: 0, width: 2, height: 6)
                    context.fill(
                        Path(roundedRect: tick, cornerRadius: 1),
                        with: .color(Color.primary.opacity(0.35))
                    )
                }

                let bandRect = CGRect(x: 0, y: 8, width: size.width, height: 16)
                let bandPath = Path(roundedRect: bandRect, cornerRadius: 6)
                context.clip(to: bandPath)
                context.fill(bandPath, with: .color(Color.primary.opacity(0.08)))
                for segment in segments {
                    let rect = CGRect(
                        x: segment.startFraction * size.width,
                        y: 8,
                        width: max(segment.widthFraction * size.width, 0.8),
                        height: 16
                    )
                    context.fill(
                        Path(rect),
                        with: .color(speakerTimelineColor(for: segment.colorIndex).opacity(0.94))
                    )
                }
                // Thin vertical striping gives the band its waveform
                // texture without the cost of drawing real audio.
                var stripeX: CGFloat = 0
                while stripeX < size.width {
                    context.fill(
                        Path(CGRect(x: stripeX, y: 8, width: 2, height: 16)),
                        with: .color(Color.black.opacity(0.2))
                    )
                    stripeX += 5
                }
            }
        }
    }

    private struct SpeakerAnnotatedScrubber: View {
        let duration: TimeInterval
        let currentTime: TimeInterval
        let segments: [SpeakerTimelineData.Segment]
        let chapters: [ChapterDTO]
        let formatTime: (TimeInterval) -> String
        let onSeek: (TimeInterval) -> Void

        /// Non-nil while the user is dragging; the playhead follows the drag
        /// instead of the (still advancing) playback clock.
        @State private var dragFraction: Double?
        /// Chapter tick under the pointer; drives the floating title bubble.
        @State private var hoveredChapterIndex: Int?
        /// Measured bubble width, used to keep it inside the track's bounds.
        @State private var hoverBubbleWidth: CGFloat = 0

        private var progressFraction: Double {
            if let dragFraction { return dragFraction }
            guard duration > 0 else { return 0 }
            return min(max(currentTime / duration, 0), 1)
        }

        private func chapterFraction(_ chapter: ChapterDTO) -> Double? {
            ScrubberTrackCanvas.chapterFraction(chapter, duration: duration)
        }

        var body: some View {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .topLeading) {
                    // Nothing in the track depends on the playhead, so it is
                    // Equatable: playback ticks reuse the rasterized layer
                    // instead of repainting hundreds of fills 4 times a second.
                    ScrubberTrackCanvas(duration: duration, segments: segments, chapters: chapters)
                        .equatable()

                    // Playhead: white with a top knob, defined by shadow so it
                    // reads over any segment color in both appearances.
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .shadow(color: .black.opacity(0.45), radius: 1.5)
                        .offset(x: progressFraction * width - 4, y: 0)
                        .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white)
                        .frame(width: 2, height: 22)
                        .shadow(color: .black.opacity(0.45), radius: 1.5)
                        .offset(x: progressFraction * width - 1, y: 4)
                        .allowsHitTesting(false)

                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        if let fraction = chapterFraction(chapter) {
                            Color.clear
                                .frame(width: 14, height: 30)
                                .contentShape(Rectangle())
                                .offset(x: fraction * width - 7, y: 0)
                                .onHover { hovering in
                                    if hovering {
                                        hoveredChapterIndex = index
                                    } else if hoveredChapterIndex == index {
                                        hoveredChapterIndex = nil
                                    }
                                }
                        }
                    }

                    // Floating chapter bubble above the hovered tick — the
                    // instant styled affordance the delayed system tooltip
                    // never delivered. Deliberately overflows the track's
                    // frame; nothing above clips it.
                    if let index = hoveredChapterIndex,
                       chapters.indices.contains(index),
                       let fraction = chapterFraction(chapters[index]) {
                        Text(verbatim: "\(formatTime(chapters[index].startSeconds))  \(chapters[index].title)")
                            .font(.cadenza(10.5, weight: .medium, scale: 1))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.width
                            } action: { measured in
                                hoverBubbleWidth = measured
                            }
                            .position(
                                x: min(
                                    max(fraction * width, hoverBubbleWidth / 2),
                                    max(width - hoverBubbleWidth / 2, hoverBubbleWidth / 2)
                                ),
                                y: -16
                            )
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            let fraction = min(max(value.location.x / width, 0), 1)
                            dragFraction = nil
                            onSeek(fraction * duration)
                        }
                )
            }
            .frame(height: 30)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Playback position"))
            .accessibilityValue(Text(verbatim: formatTime(currentTime)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onSeek(min(currentTime + 15, duration))
                case .decrement: onSeek(max(currentTime - 15, 0))
                @unknown default: break
                }
            }
        }
    }

    // MARK: - Transcript Content

    @ViewBuilder
    private func transcriptContent(_ detail: RecordingDetailDTO) -> some View {
        if isTranslating {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Translating...")
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if let translated = translatedText {
            Text(translated)
                .font(.cadenzaBody(13, scale: uiScale))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let transcript = detail.transcript, !transcript.fullText.isEmpty {
            // Turns and timeline come from the per-load caches; recomputing
            // either here would run on every 10Hz playback re-render.
            let displayEntries = transcriptTurns
            let timeline = playerTimeline
            let colorBySpeakerKey = Dictionary(
                uniqueKeysWithValues: (timeline?.speakers ?? []).map { ($0.speakerKey, $0.colorIndex) }
            )
            VStack(alignment: .leading, spacing: 8) {
                if displayEntries.isEmpty {
                    Text(transcript.fullText)
                        .font(.cadenzaBody(13, scale: uiScale))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // The speaker band lives on the player now; here the
                    // speakers appear as filter chips beside the search field.
                    if let timeline {
                        transcriptFilterBar(timeline)
                            .padding(.bottom, 4)
                    } else {
                        transcriptSearchField
                    }

                    let visibleEntries = visibleTranscriptTurns()
                    if visibleEntries.isEmpty {
                        ContentUnavailableView.search(text: transcriptQuery)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else {
                        ScrollViewReader { proxy in
                            LazyVStack(alignment: .leading, spacing: 0) {
                                PlaybackEntryObserver(
                                    player: audioPlayer,
                                    entries: visibleEntries,
                                    activeID: $activeTranscriptEntryID
                                )
                                ForEach(visibleEntries) { entry in
                                    let isActive = entry.id == activeTranscriptEntryID
                                    TranscriptSegmentRow(
                                        entry: entry,
                                        isActive: isActive,
                                        fontSize: 13,
                                        // Only recordings with identified speakers mark
                                        // unattributed rows as Unknown; plain-text chunker
                                        // output stays unadorned.
                                        showsUnknownSpeaker: timeline != nil,
                                        formatTime: formatTime,
                                        speakerTint: { speaker in
                                            speakerColor(for: speaker, colorBySpeakerKey: colorBySpeakerKey)
                                        },
                                        speakerDisplayName: { speaker in
                                            resolvedSpeakerName(rawLabel: speaker)
                                        },
                                        speakerLabel: { speaker in
                                            speakerLabel(
                                                rawLabel: speaker,
                                                isActive: isActive,
                                                colorBySpeakerKey: colorBySpeakerKey
                                            )
                                        },
                                        onTap: {
                                            audioPlayer.seek(to: entry.startTime)
                                            if !audioPlayer.isPlaying {
                                                audioPlayer.play()
                                            }
                                        }
                                    )
                                    .id(entry.id)

                                    if entry.id != visibleEntries.last?.id {
                                        Divider()
                                            .padding(.leading, 56)
                                    }
                                }
                            }
                            // Keep the reading measure bounded even in a wide
                            // window; the timeline card above stays full width.
                            .frame(maxWidth: 820, alignment: .leading)
                            .onChange(of: activeTranscriptEntryID) { _, newID in
                                if let newID, transcriptFollowsPlayback {
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                                        proxy.scrollTo(newID, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else if isActiveRecording {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "Recording in Progress",
                    systemImage: "waveform",
                    description: Text("Transcript will be generated after the recording is stopped.")
                )
            }
            .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
        } else if isTranscriptionBusy {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Transcribing...")
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "text.bubble",
                    description: Text(detail.audioFile != nil
                        ? String(localized: "Transcription failed or was not run. You can retry from the audio file.")
                        : String(localized: "This recording doesn't have a transcript."))
                )

                if detail.audioFile != nil {
                    Button {
                        appState.retryTranscription(recordingID: recordingID)
                    } label: {
                        HStack(spacing: 8) {
                            if isTranscriptionBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "waveform.badge.arrow.right")
                            }
                            Text(isTranscriptionBusy ? String(localized: "Transcribing...") : String(localized: "Start Transcription"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        isTranscriptionBusy
                            || !appState.startupPolicy.allowsContentGeneration
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
        }
    }

    private struct TranscriptDisplayEntry: Identifiable {
        let id: UUID
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
        let speaker: String?
        /// How many raw segments this turn merged (1 = unmerged).
        var mergedCount: Int = 1
    }

    private struct SpeakerTimelineView: View {
        @Environment(\.uiScale) private var uiScale: CGFloat

        let data: SpeakerTimelineData
        let formatTime: (TimeInterval) -> String
        /// When set, the matching share chip renders selected and the others
        /// dim: the legend doubles as the transcript's speaker filter.
        var selectedSpeakerKey: String? = nil
        var onSelectSpeaker: ((SpeakerTimelineData.SpeakerSummary) -> Void)? = nil

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Speaker Distribution")
                        .font(.cadenza(13, weight: .semibold, scale: uiScale))
                    Text("Speakers: \(data.identifiedSpeakerCount)")
                        .font(.cadenza(13 - 1, scale: uiScale))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))

                        ForEach(data.segments) { segment in
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(speakerTimelineColor(for: segment.colorIndex))
                                .frame(
                                    width: max(3, proxy.size.width * segment.widthFraction - 1),
                                    height: 18
                                )
                                .offset(x: proxy.size.width * segment.startFraction)
                                .shadow(
                                    color: speakerTimelineColor(for: segment.colorIndex).opacity(0.22),
                                    radius: 3
                                )
                                .help(Text(
                                    verbatim: "\(segment.speakerName) · \(formatTime(segment.startTime))-\(formatTime(segment.endTime))"
                                ))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .frame(height: 22)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132), spacing: 8, alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(legendSpeakers) { speaker in
                        let isFilterable = onSelectSpeaker != nil
                            && speaker.speakerKey != "__others__"
                            && speaker.speakerKey != SpeakerTimelineBuilder.unknownSpeakerKey
                        let chip = SpeakerShareChip(
                            speaker: speaker,
                            color: speakerTimelineColor(for: speaker.colorIndex),
                            percentString: percentString(speaker.fraction),
                            isSelected: selectedSpeakerKey == speaker.speakerKey,
                            isDimmed: selectedSpeakerKey != nil && selectedSpeakerKey != speaker.speakerKey
                        )
                        if isFilterable {
                            Button {
                                onSelectSpeaker?(speaker)
                            } label: {
                                chip
                            }
                            .buttonStyle(.cadenzaPlain)
                            .help("Show only this speaker")
                            .accessibilityValue(
                                selectedSpeakerKey == speaker.speakerKey
                                    ? Text("Selected") : Text("Not selected")
                            )
                        } else {
                            chip
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 1)
            )
        }

        private var legendSpeakers: [SpeakerTimelineData.SpeakerSummary] {
            guard data.speakers.count > 4 else { return data.speakers }
            let visible = Array(data.speakers.prefix(4))
            let others = data.speakers.dropFirst(4)
            let total = others.reduce(0) { $0 + $1.totalDuration }
            let fraction = others.reduce(0) { $0 + $1.fraction }
            return visible + [
                SpeakerTimelineData.SpeakerSummary(
                    speakerKey: "__others__",
                    speakerName: String(localized: "Other"),
                    totalDuration: total,
                    fraction: fraction,
                    colorIndex: SpeakerTimelineBuilder.othersColorIndex
                )
            ]
        }

        private func percentString(_ value: Double) -> String {
            "\(Int((value * 100).rounded()))%"
        }
    }

    /// Speaker share chip shared by the (superseded) distribution card and
    /// the transcript filter bar. Capsule with a hue dot, per the concept;
    /// selection styling backs the filter role.
    private struct SpeakerShareChip: View {
        @Environment(\.uiScale) private var uiScale: CGFloat

        let speaker: SpeakerTimelineData.SpeakerSummary
        let color: Color
        let percentString: String
        var isSelected: Bool = false
        var isDimmed: Bool = false

        var body: some View {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(speaker.speakerName)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(percentString)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
            }
            .font(.cadenza(13 - 2, scale: uiScale))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                color.opacity(isSelected ? 0.22 : 0.13),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(color.opacity(isSelected ? 0.7 : 0.32), lineWidth: isSelected ? 1.5 : 1)
            )
            .opacity(isDimmed ? 0.55 : 1)
        }
    }

    private struct IconHoverButton: View {
        @Environment(\.uiScale) private var uiScale: CGFloat

        let title: LocalizedStringKey
        let icon: String
        let color: Color
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Label(title, systemImage: icon)
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(isHovered ? color : color.opacity(0.7))
                    .padding(.horizontal, 9)
                    .frame(minHeight: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isHovered ? color.opacity(0.1) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.cadenzaPlain)
            .onHover { isHovered = $0 }
        }
    }

    private struct DeleteButton: View {
        @Environment(\.uiScale) private var uiScale: CGFloat

        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Label("Delete", systemImage: "trash")
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(isHovered ? .red : .red.opacity(0.6))
                    .padding(.horizontal, 9)
                    .frame(minHeight: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isHovered ? Color.red.opacity(0.12) : .clear)
                    )
                    .cadenzaGlass(
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                        interactive: true
                    )
            }
            .buttonStyle(.cadenzaPlain)
            .onHover { isHovered = $0 }
        }
    }

    private struct CopySegmentButton: View {
        @Environment(\.uiScale) private var uiScale: CGFloat

        let text: String
        let isRowHovered: Bool
        @State private var isButtonHovered = false
        @State private var showCopied = false

        var body: some View {
            let controlSize = CadenzaControlMetrics.squareIconFrame(
                base: 22,
                symbolPointSize: 12,
                scale: uiScale,
                padding: 6
            )
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { showCopied = false }
            } label: {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.cadenza(12, weight: showCopied ? .semibold : .regular, scale: uiScale))
                    .foregroundStyle(showCopied ? Color.green : (isButtonHovered ? Color.primary : Color.secondary.opacity(0.5)))
                    .frame(width: controlSize, height: controlSize)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isButtonHovered ? Color.primary.opacity(0.08) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.cadenzaPlain)
            .opacity(isRowHovered ? 1 : 0)
            .onHover { isButtonHovered = $0 }
            .help("Copy this segment")
        }
    }

    /// A conversation turn: gutter timestamp, speaker avatar, then a name
    /// line (identity menu, time range, merge count, playing badge) above
    /// the merged body text.
    private struct TranscriptSegmentRow<SpeakerView: View>: View {
        @Environment(\.uiScale) private var uiScale: CGFloat

        let entry: TranscriptDisplayEntry
        let isActive: Bool
        let fontSize: Double
        /// When the recording has identified speakers, rows the diarizer could
        /// not attribute show an explicit Unknown chip instead of nothing.
        let showsUnknownSpeaker: Bool
        let formatTime: (TimeInterval) -> String
        let speakerTint: (String) -> Color
        let speakerDisplayName: (String) -> String
        @ViewBuilder let speakerLabel: (String) -> SpeakerView
        let onTap: () -> Void

        @State private var isHovered = false

        private var unknownSpeakerColor: Color {
            speakerTimelineColor(for: SpeakerTimelineBuilder.unknownSpeakerColorIndex)
        }

        /// Same capsule shape as the identity chip, minus the mapping menu:
        /// there is no identity to assign to an unattributed row.
        private var unknownSpeakerChip: some View {
            HStack(spacing: 4) {
                Circle()
                    .fill(unknownSpeakerColor)
                    .frame(width: 7, height: 7)
                Text("Unknown")
                    .font(.cadenza(13 - 1, weight: .semibold, scale: uiScale))
                    .foregroundStyle(unknownSpeakerColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(unknownSpeakerColor.opacity(0.12))
            )
            .fixedSize()
        }

        var body: some View {
            HStack(alignment: .top, spacing: 6) {
                // Copy button — visible on hover, placed next to timestamp
                CopySegmentButton(text: entry.text, isRowHovered: isHovered)

                // Timestamp
                Text(formatTime(entry.startTime))
                    .font(.cadenza(13 - 2, design: .monospaced, scale: uiScale))
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 38, alignment: .trailing)
                    .padding(.top, 3)

                if let speaker = entry.speaker {
                    ZStack {
                        Circle()
                            .fill(speakerTint(speaker).opacity(0.2))
                        Text(verbatim: String(speakerDisplayName(speaker).prefix(1)).uppercased())
                            .font(.cadenza(11, weight: .bold, scale: uiScale))
                            .foregroundStyle(speakerTint(speaker))
                    }
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                } else if showsUnknownSpeaker {
                    ZStack {
                        Circle()
                            .fill(unknownSpeakerColor.opacity(0.2))
                        Text(verbatim: "?")
                            .font(.cadenza(11, weight: .bold, scale: uiScale))
                            .foregroundStyle(unknownSpeakerColor)
                    }
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                }

                // Speaker + text
                VStack(alignment: .leading, spacing: 3) {
                    if entry.speaker != nil || showsUnknownSpeaker {
                        HStack(spacing: 8) {
                            if let speaker = entry.speaker {
                                speakerLabel(speaker)
                            } else {
                                unknownSpeakerChip
                            }
                            Text(verbatim: "\(formatTime(entry.startTime)) - \(formatTime(entry.endTime))")
                                .font(.cadenza(fontSize - 3, scale: uiScale))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                            if entry.mergedCount > 1 {
                                Text("Merged from \(entry.mergedCount) segments")
                                    .font(.cadenza(fontSize - 3, scale: uiScale))
                                    .foregroundStyle(.quaternary)
                            }
                            if isActive {
                                Text("Playing")
                                    .font(.cadenza(fontSize - 4, weight: .semibold, scale: uiScale))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            }
                        }
                    }
                    Text(entry.text)
                        .font(.cadenzaBody(13, scale: uiScale))
                        .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineSpacing(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.1) : (isHovered ? Color.primary.opacity(0.04) : .clear))
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { onTap() }
        }
    }

    private func displayTranscriptEntries(for transcript: TranscriptDTO, duration: TimeInterval) -> [TranscriptDisplayEntry] {
        if transcript.segments.count > 1 {
            // Filter out whitespace-only entries that some transcription providers produce
            return transcript.segments.compactMap {
                guard !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return TranscriptDisplayEntry(id: $0.id, startTime: $0.startTime, endTime: $0.endTime, text: $0.text, speaker: $0.speaker)
            }
        }

        let chunks = splitTranscriptTextForDisplay(transcript.fullText)
        guard !chunks.isEmpty else { return [] }
        if chunks.count == 1 {
            return [
                TranscriptDisplayEntry(
                    id: transcript.segments.first?.id ?? UUID(),
                    startTime: transcript.segments.first?.startTime ?? 0,
                    endTime: transcript.segments.first?.endTime ?? duration,
                    text: chunks[0],
                    speaker: nil
                )
            ]
        }

        let totalDuration = max(duration, 0)
        let totalWeight = max(1, chunks.reduce(0) { $0 + $1.count })
        var cursor: TimeInterval = 0
        return chunks.enumerated().map { index, chunk in
            let weightedDuration = totalDuration > 0 ? (totalDuration * Double(chunk.count) / Double(totalWeight)) : 2.0
            let segmentDuration = max(totalDuration > 0 ? 0.6 : 2.0, weightedDuration)
            let start = cursor
            let end = totalDuration > 0
                ? (index == chunks.count - 1 ? totalDuration : min(totalDuration, cursor + segmentDuration))
                : cursor + segmentDuration
            cursor = end
            return TranscriptDisplayEntry(id: UUID(), startTime: start, endTime: end, text: chunk, speaker: nil)
        }
    }

    private func splitTranscriptTextForDisplay(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return [] }

        var marked = normalized
        let punctuationBreaks: [(String, String)] = [
            ("。", "。\n"),
            ("！", "！\n"),
            ("？", "？\n"),
            ("；", "；\n"),
            ("…", "…\n"),
            (". ", ".\n"),
            ("! ", "!\n"),
            ("? ", "?\n"),
            ("; ", ";\n")
        ]
        for (from, to) in punctuationBreaks {
            marked = marked.replacingOccurrences(of: from, with: to)
        }

        let roughChunks = marked
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        for chunk in roughChunks {
            chunks.append(contentsOf: splitLongDisplayChunk(chunk, maxLength: 72))
        }

        var merged: [String] = []
        for chunk in chunks {
            if chunk.count < 10, let last = merged.last {
                merged[merged.count - 1] = "\(last) \(chunk)"
            } else {
                merged.append(chunk)
            }
        }

        return merged
    }

    private func splitLongDisplayChunk(_ chunk: String, maxLength: Int) -> [String] {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed.isEmpty ? [] : [trimmed] }

        if !trimmed.contains(" ") {
            return splitDisplayByCharacterCount(trimmed, maxLength: maxLength)
        }

        var result: [String] = []
        var current = ""

        for wordSub in trimmed.split(separator: " ") {
            let word = String(wordSub)
            if current.isEmpty {
                if word.count > maxLength {
                    result.append(contentsOf: splitDisplayByCharacterCount(word, maxLength: maxLength))
                } else {
                    current = word
                }
                continue
            }

            if current.count + 1 + word.count <= maxLength {
                current += " " + word
            } else {
                result.append(current)
                if word.count > maxLength {
                    result.append(contentsOf: splitDisplayByCharacterCount(word, maxLength: maxLength))
                    current = ""
                } else {
                    current = word
                }
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }

    private func splitDisplayByCharacterCount(_ text: String, maxLength: Int) -> [String] {
        guard maxLength > 0 else { return [text] }

        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
            let piece = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                result.append(piece)
            }
            start = end
        }
        return result
    }

    // MARK: - Summary Content

    @ViewBuilder
    private func yourTasksSection(_ tasks: [String]) -> some View {
        if !tasks.isEmpty {
            SummarySection(title: "Your Tasks", fontSize: 13) {
                ForEach(tasks, id: \.self) { task in
                    Label(task, systemImage: "person.fill.checkmark")
                        .font(.cadenzaBody(13, scale: uiScale))
                        .labelStyle(BulletLabelStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func summaryContent(_ detail: RecordingDetailDTO) -> some View {
        VStack(alignment: .leading, spacing: 16) {
        SummaryContextView(detail: detail, event: linkedEvent).id(detail.id)
        if let quickResult = appState.quickSummaryResult(for: recordingID), isSummaryBusy {
            // Two-stage: quick result available, show it with enrich spinner
            VStack(alignment: .leading, spacing: 16) {
                if !quickResult.overview.isEmpty {
                    SummarySection(title: "Overview", fontSize: 13) {
                        Text(quickResult.overview)
                            .font(.cadenzaBody(13, scale: uiScale))
                    }
                }

                if !quickResult.keyPoints.isEmpty {
                    SummarySection(title: "Key Points", fontSize: 13) {
                        ForEach(quickResult.keyPoints, id: \.self) { point in
                            Label(point, systemImage: "circle.fill")
                                .font(.cadenzaBody(13, scale: uiScale))
                                .labelStyle(BulletLabelStyle())
                        }
                    }
                }

                yourTasksSection(quickResult.yourTasks)

                // Enrich spinner
                if appState.isEnrichingSummary(for: recordingID) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reviewing summary...")
                            .font(.cadenza(13 - 1, scale: uiScale))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
        } else if appState.isGeneratingSummary(for: recordingID) || appState.isProcessing(recordingID: recordingID) {
            // Still processing (transcribing or generating summary, no quick result yet)
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(appState.isProcessing(recordingID: recordingID) && !appState.isGeneratingSummary(for: recordingID)
                     ? String(localized: "Processing...")
                     : String(localized: "Generating summary..."))
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else if let summary = detail.summary {
            VStack(alignment: .leading, spacing: 16) {
                if let metadata = summary.generationMetadata {
                    Text(metadata.statusText)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !summary.overview.isEmpty {
                    SummarySection(title: "Overview", fontSize: 13) {
                        Text(summary.overview)
                            .font(.cadenzaBody(13, scale: uiScale))
                    }
                }

                if !summary.keyPoints.isEmpty {
                    SummarySection(title: "Key Points", fontSize: 13) {
                        ForEach(summary.keyPoints, id: \.self) { point in
                            Label(point, systemImage: "circle.fill")
                                .font(.cadenzaBody(13, scale: uiScale))
                                .labelStyle(BulletLabelStyle())
                        }
                    }
                }

                yourTasksSection(summary.yourTasks)

                if !summary.decisions.isEmpty {
                    SummarySection(title: "Decisions", fontSize: 13) {
                        ForEach(summary.decisions, id: \.self) { decision in
                            Label(decision, systemImage: "circle.fill")
                                .font(.cadenzaBody(13, scale: uiScale))
                                .labelStyle(BulletLabelStyle())
                        }
                    }
                }

                if !summary.followUps.isEmpty {
                    SummarySection(title: "Follow-ups", fontSize: 13) {
                        ForEach(summary.followUps, id: \.self) { followUp in
                            Label(followUp, systemImage: "circle.fill")
                                .font(.cadenzaBody(13, scale: uiScale))
                                .labelStyle(BulletLabelStyle())
                        }
                    }
                }
            }
        } else if isActiveRecording {
            ContentUnavailableView(
                "Recording in Progress",
                systemImage: "waveform",
                description: Text("Summary will be generated after the recording is stopped.")
            )
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
        } else {
            ContentUnavailableView(
                "No Summary",
                systemImage: "sparkles",
                description: Text(detail.transcript != nil
                    ? String(localized: "Select a language above to generate a summary.")
                    : String(localized: "This recording doesn't have a summary."))
            )
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
        }
        }
    }

    // MARK: - Actions

    private func beginRename() {
        renameText = detail?.title ?? ""
        isEditingTitle = true
        titleFieldFocused = true
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            appState.updateRecordingTitle(recordingID: recordingID, title: trimmed)
            detail?.title = trimmed
        }
        isEditingTitle = false
    }

    private var dateEditPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            // `.graphical` is a fixed-size NSDatePicker: widening the container only adds
            // empty space, and `.controlSize` is ignored. Scaling is the only way to enlarge
            // it — measure the natural size, scale, then restore the layout size via `frame`
            // (scaleEffect does not change layout, so without it the Time row overlaps).
            DatePicker("", selection: $editedDate, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    guard size.width > 0 else { return }
                    datePickerNaturalSize = size
                }
                // Scale from the centre; a topLeading anchor pins the calendar to the
                // corner and leaves the padding on one side.
                .scaleEffect(Self.datePickerScale)
                .frame(
                    width: datePickerNaturalSize.width * Self.datePickerScale,
                    height: datePickerNaturalSize.height * Self.datePickerScale
                )
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            HStack {
                Text("Time")
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(.secondary)
                Spacer()
                DatePicker("", selection: $editedDate, displayedComponents: [.hourAndMinute])
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Done") { commitDateEdit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .fixedSize()
    }

    private func commitDateEdit() {
        guard let current = detail else {
            isEditingDate = false
            return
        }
        appState.updateRecordingDate(recordingID: recordingID, newDate: editedDate)
        detail?.startDate = editedDate
        if let oldEnd = current.endDate {
            // Mirror the store: shift the interval, don't recompute from duration.
            detail?.endDate = oldEnd.addingTimeInterval(editedDate.timeIntervalSince(current.startDate))
        }
        if let updated = detail {
            loadCandidateEvents(updated)
        }
        isEditingDate = false
    }

    private func translateTranscript(to language: TranscriptionLanguage) async {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        guard let fullText = detail?.transcript?.fullText, !fullText.isEmpty else { return }

        let providerRaw = UserDefaults.standard.string(forKey: "defaultAIProvider") ?? AIProvider.apple.rawValue
        let provider = AIProvider(rawValue: providerRaw) ?? .apple
        let apiKey: String
        if provider.requiresAPIKey {
            guard let key = KeychainManager.shared.apiKey(for: provider), !key.isEmpty else { return }
            apiKey = key
        } else {
            apiKey = ""
        }

        isTranslating = true
        translatedText = nil

        guard let service = RecordingsContentGenerationBoundary.constructService(
            startupPolicy: appState.startupPolicy,
            factory: { Optional(createAIService(provider: provider, apiKey: apiKey)) }
        ) else { return }
        let systemPrompt = "You are a translator. Translate the provided meeting transcript to \(language.displayName). Keep the original meaning and tone. Output only the translated text, nothing else."

        do {
            let stream = service.streamChat(
                systemPrompt: systemPrompt,
                userMessage: fullText,
                // Explicit resolver: translation uses the summary-tier
                // configured model rather than relying on any service-level
                // nil-fallback behavior.
                model: provider.summaryModel
            )
            var result = ""
            for try await chunk in stream {
                result += chunk
            }
            translatedText = result
        } catch {
            translatedText = String(localized: "Translation failed: \(error.localizedDescription)")
        }

        isTranslating = false
    }

    private func regenerateSummary(language: TranscriptionLanguage) {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        let providerRaw = UserDefaults.standard.string(forKey: "defaultAIProvider") ?? AIProvider.apple.rawValue
        appState.generateSummary(recordingID: recordingID, provider: providerRaw, language: language.rawValue)
    }

    private func copyTranscript() {
        let text: String
        if let translated = translatedText {
            text = translated
        } else if let transcript = detail?.transcript, let detail {
            let entries = displayTranscriptEntries(for: transcript, duration: detail.duration)
            if entries.count > 1 {
                text = entries.map { "\(formatTime($0.startTime))  \($0.text)" }.joined(separator: "\n\n")
            } else {
                text = transcript.fullText
            }
        } else {
            text = ""
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedTab = 0
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedTab == 0 { copiedTab = nil }
        }
    }

    private func copySummary() {
        guard let summary = detail?.summary else { return }
        let text = formatSummaryForCopy(summary)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedTab = 1
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedTab == 1 { copiedTab = nil }
        }
    }

    private nonisolated func createAIService(provider: AIProvider, apiKey: String) -> AIServiceProtocol {
        provider.makeChatService(apiKey: apiKey) ?? OpenAIService(apiKey: apiKey)
    }

    private func formatSummaryForCopy(_ summary: SummaryDTO) -> String {
        var parts: [String] = []
        if let metadata = summary.generationMetadata { parts.append(metadata.exportStatusText) }

        if !summary.overview.isEmpty {
            parts.append("## Overview\n\(summary.overview)")
        }
        if !summary.keyPoints.isEmpty {
            parts.append("## Key Points\n" + summary.keyPoints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.actionItems.isEmpty {
            let items = summary.actionItems.map { item in
                let assignee = item.assignee.map { " (@\($0))" } ?? ""
                return "- [ ] \(item.task)\(assignee)"
            }
            parts.append("## Action Items\n" + items.joined(separator: "\n"))
        }
        if !summary.decisions.isEmpty {
            parts.append("## Decisions\n" + summary.decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.yourTasks.isEmpty {
            parts.append("## Your Tasks\n" + summary.yourTasks.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !summary.followUps.isEmpty {
            parts.append("## Follow-ups\n" + summary.followUps.map { "- \($0)" }.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Formatting

    private func dateString(_ date: Date) -> String {
        LocalizedDateFormatting.string(
            from: date,
            style: .dateTime.year().month(.abbreviated).day()
                .hour(.defaultDigits(amPM: .abbreviated)).minute(),
            locale: locale
        )
    }

    private func durationString(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Speaker Mapping

    /// Resolves a raw speaker label to its mapped display name, a suggestion, or a friendly fallback.
    private func resolvedSpeakerName(rawLabel: String) -> String {
        if let mapping = detail?.speakerMappings.first(where: { $0.rawLabel == rawLabel }) {
            return mapping.profileName
        }
        if let suggestion = suggestionForLabel(rawLabel) {
            return String(localized: "Probably \(suggestion.profileName)")
        }
        return Self.friendlySpeakerLabel(rawLabel)
    }

    private static func friendlySpeakerLabel(_ raw: String) -> String {
        SpeakerLabelFormatter.displayName(forRawLabel: raw)
    }

    private func isSpeakerMapped(_ rawLabel: String) -> Bool {
        detail?.speakerMappings.contains(where: { $0.rawLabel == rawLabel }) ?? false
    }

    private func suggestionForLabel(_ rawLabel: String) -> SpeakerLabelSuggestionDTO? {
        guard !isSpeakerMapped(rawLabel) else { return nil }
        return detail?.speakerSuggestions.first(where: { $0.rawLabel == rawLabel })
    }

    private func speakerTimelineIdentityKey(rawLabel: String?) -> String? {
        guard let rawLabel = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLabel.isEmpty else { return nil }
        if let mapping = detail?.speakerMappings.first(where: { $0.rawLabel == rawLabel }) {
            return "profile:\(mapping.profileID.uuidString)"
        }
        return rawLabel
    }

    /// Assigns a stable color to each speaker based on their raw label.
    private func speakerColor(for rawLabel: String, colorBySpeakerKey: [String: Int]) -> Color {
        let identityKey = speakerTimelineIdentityKey(rawLabel: rawLabel) ?? rawLabel
        if let colorIndex = colorBySpeakerKey[identityKey] {
            return speakerTimelineColor(for: colorIndex)
        }
        return speakerTimelineFallbackColor(for: identityKey)
    }

    @ViewBuilder
    private func speakerLabel(
        rawLabel: String,
        isActive: Bool,
        colorBySpeakerKey: [String: Int]
    ) -> some View {
        let displayName = resolvedSpeakerName(rawLabel: rawLabel)
        let mapped = isSpeakerMapped(rawLabel)
        let color = speakerColor(for: rawLabel, colorBySpeakerKey: colorBySpeakerKey)

        Menu {
            if mapped {
                Button {
                    appState.removeSpeakerMapping(recordingID: recordingID, rawLabel: rawLabel)
                    // removeSpeakerMapping triggers refreshRecordings → onChange → loadDetail
                } label: {
                    Label("Reset to \"\(rawLabel)\"", systemImage: "arrow.uturn.backward")
                }
                Divider()
            }

            if let suggestion = suggestionForLabel(rawLabel) {
                Button {
                    appState.setSpeakerMapping(
                        recordingID: detail!.id,
                        rawLabel: rawLabel,
                        profileID: suggestion.profileID
                    ) {
                        loadDetail()
                    }
                } label: {
                    Label(
                        "Confirm \(suggestion.profileName) (\(String(format: "%.2f", suggestion.score)))",
                        systemImage: "brain.head.profile"
                    )
                }
                Divider()
            }

            ForEach(speakerProfiles) { profile in
                Toggle(isOn: speakerProfileSelectionBinding(rawLabel: rawLabel, profileID: profile.id)) {
                    Text(profile.displayName)
                }
            }

            Divider()

            Button {
                speakerMappingLabel = rawLabel
            } label: {
                Label("New Speaker…", systemImage: "person.badge.plus")
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(displayName)
                    .font(.cadenza(13 - 1, weight: .semibold, scale: uiScale))
                    .foregroundStyle(color)
                if mapped {
                    Image(systemName: "person.fill")
                        .font(.cadenza(7, scale: uiScale))
                        .foregroundStyle(color.opacity(0.6))
                } else if suggestionForLabel(rawLabel) != nil {
                    Image(systemName: "brain.head.profile")
                        .font(.cadenza(7, scale: uiScale))
                        .foregroundStyle(.orange.opacity(0.8))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func speakerProfileSelectionBinding(rawLabel: String, profileID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                detail?.speakerMappings.contains {
                    $0.rawLabel == rawLabel && $0.profileID == profileID
                } == true
            },
            set: { isSelected in
                guard isSelected else { return }
                appState.setSpeakerMapping(
                    recordingID: recordingID,
                    rawLabel: rawLabel,
                    profileID: profileID
                ) {
                    loadDetail()
                }
            }
        )
    }

    private func loadSpeakerProfiles() {
        appState.fetchSpeakerProfiles { profiles in
            self.speakerProfiles = profiles
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct SummarySection<Content: View>: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let title: LocalizedStringKey
    var fontSize: Double = 13
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.cadenza(13 + 3, weight: .semibold, scale: uiScale))
            content
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    @Environment(\.uiScale) private var uiScale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 8) {
            configuration.icon
                .font(.cadenza(4, scale: uiScale))
                .padding(.top, 7)
            configuration.title
        }
    }
}

// MARK: - Playback Rate Menu (isolated from time updates)

private struct PlaybackRateMenuView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let player: AudioPlayerService
    let fontSize: CGFloat

    private var playbackRateSelection: Binding<Float> {
        Binding(
            get: { player.playbackRate },
            set: { player.setRate($0) }
        )
    }

    var body: some View {
        Menu {
            Picker("", selection: playbackRateSelection) {
                ForEach(AudioPlayerService.availableRates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            Text(Self.rateLabel(player.playbackRate))
                .font(.cadenza(13, weight: .semibold, design: .monospaced, scale: uiScale))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private static func rateLabel(_ rate: Float) -> String {
        rate.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(rate))x" : "\(String(format: "%.2g", rate))x"
    }
}
