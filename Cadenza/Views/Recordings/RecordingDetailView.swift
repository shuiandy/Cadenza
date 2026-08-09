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
    @State private var selectedTab = 0
    @State private var audioPlayer = AudioPlayerService()
    @State private var detailLoadTracker = DetailLoadTracker()

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
                if Self.playerNeedsReload(loaded: loadedAudioURL, resolved: resolved),
                   let resolved {
                    audioPlayer.load(url: resolved)
                    loadedAudioURL = resolved
                }
                appState.recordingDetailTitle = dto.title
                loadLinkedEvent()
                loadSpeakerProfiles()

                // Lazily generate chapters when user views a recording with summary but no chapters
                if dto.summary != nil && (dto.summary?.chapters.isEmpty ?? true) {
                    appState.coordinator?.generateChaptersIfNeeded(recordingID: recordingID)
                }
            } else {
                detail = nil
            }
        }
    }

    private func closeDetailTab() {
        appState.closeDetail()
    }

    // MARK: - Detail Content

    @State private var isPlayerScrolledOut = false
    private let playerBottomAnchor: CGFloat = 120

    @ViewBuilder
    private func detailContent(_ detail: RecordingDetailDTO) -> some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection(detail)
                    Divider()

                    if let audioFile = detail.audioFile {
                        if let url = Self.resolvedAudioURL(audioFile),
                           FileManager.default.fileExists(atPath: url.path) {
                            audioPlayerSection
                            // A playable legacyAbsolute row is still an
                            // un-converged M1 residue; the repair stays
                            // available without an alarming warning.
                            if audioFile.isLegacy {
                                legacyRelinkSection(audioFile, style: .residualLocation)
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
                            .padding(.vertical, 8)
                        }
                        Divider()
                    }

                    // Tab bar
                    tabBar
                        .padding(.bottom, 4)

                    // Per-tab toolbar
                    if selectedTab == 0 {
                        summaryToolbar(detail)
                    } else if selectedTab == 2 {
                        transcriptToolbar(detail)
                    }

                    if selectedTab != 1 {
                        Divider()
                    }

                    // Content
                    Group {
                        switch selectedTab {
                        case 0: summaryContent(detail)
                        case 1: actionItemsContent(detail)
                        case 2: transcriptContent(detail)
                        default: EmptyView()
                        }
                    }
                    .transition(reduceMotion ? .identity : .opacity)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y > playerBottomAnchor + 20
            } action: { _, scrolledOut in
                isPlayerScrolledOut = scrolledOut
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

            // Sticky compact player
            if detail.audioFile != nil && isPlayerScrolledOut {
                compactPlayerBar
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isPlayerScrolledOut)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var compactPlayerBar: some View {
        HStack(spacing: 12) {
            Button {
                audioPlayer.toggle()
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.cadenza(14, weight: .semibold, scale: uiScale))
            }
            .buttonStyle(.cadenzaPlain)

            Text(formatTime(audioPlayer.currentTime))
                .font(.cadenza(13, design: .monospaced, scale: uiScale))
                .fixedSize()

            Slider(
                value: Binding(
                    get: { audioPlayer.currentTime },
                    set: { audioPlayer.seek(to: $0) }
                ),
                in: 0...max(audioPlayer.duration, 0.01)
            )
            .controlSize(.small)

            Text(formatTime(audioPlayer.duration))
                .font(.cadenza(13, design: .monospaced, scale: uiScale))
                .fixedSize()
                .foregroundStyle(.secondary)

            PlaybackRateMenuView(player: audioPlayer, fontSize: 13)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: - Tab Bar

    @ViewBuilder
    private var tabBar: some View {
        RecordingDetailTabBarLayout {
            tabButton("Summary", icon: "sparkles", index: 0)
            tabButton("Action Items", icon: "checklist", index: 1)
            tabButton("Transcript", icon: "text.bubble", index: 2)
        }
    }

    private func tabButton(_ title: LocalizedStringKey, icon: String, index: Int) -> some View {
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
                }
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .foregroundStyle(selectedTab == index ? .primary : .secondary)
                .contentShape(Rectangle())

                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .opacity(selectedTab == index ? 1 : 0)
            }
        }
        .buttonStyle(.cadenzaPlain)
    }

    // MARK: - Transcript Toolbar

    @ViewBuilder
    private func transcriptToolbar(_ detail: RecordingDetailDTO) -> some View {
        RecordingDetailToolbarLayout {
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
        } actions: {
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
    }

    // MARK: - Summary Toolbar

    @ViewBuilder
    private func summaryToolbar(_ detail: RecordingDetailDTO) -> some View {
        RecordingDetailToolbarLayout {
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
        } actions: {
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
                .font(.cadenza(13, scale: uiScale))
        }
        .menuStyle(.borderlessButton)
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
    private func headerSection(_ detail: RecordingDetailDTO) -> some View {
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
            if !detail.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(detail.tags, id: \.self) { tag in
                        HStack(spacing: 3) {
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

                calendarLinkRow(detail)
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
    private func calendarLinkRow(_ detail: RecordingDetailDTO) -> some View {
        Button {
            isPickingCalendarEvent = true
        } label: {
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
                            appState.linkCalendarEvent(recordingID: recordingID, calendarEventID: event.id)
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
    private var audioPlayerSection: some View {
        HStack(spacing: 12) {
            Button {
                audioPlayer.toggle()
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.cadenza(.title, scale: uiScale))
            }
            .buttonStyle(.cadenzaPlain)

            Text(formatTime(audioPlayer.currentTime))
                .font(.cadenza(13, design: .monospaced, scale: uiScale))
                .fixedSize()
                .frame(minWidth: 40, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { audioPlayer.currentTime },
                    set: { audioPlayer.seek(to: $0) }
                ),
                in: 0...max(audioPlayer.duration, 0.01)
            )

            Text(formatTime(audioPlayer.duration))
                .font(.cadenza(13, design: .monospaced, scale: uiScale))
                .fixedSize()
                .frame(minWidth: 40, alignment: .leading)

            playbackRateMenu
        }
        .padding(.vertical, 4)
    }

    private var playbackRateMenu: some View {
        PlaybackRateMenuView(player: audioPlayer, fontSize: 13)
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
            let displayEntries = displayTranscriptEntries(for: transcript, duration: detail.duration)
            let timeline = SpeakerTimelineBuilder.build(
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
                    if let timeline {
                        SpeakerTimelineView(data: timeline, formatTime: formatTime)
                            .padding(.bottom, 8)
                    }

                    ScrollViewReader { proxy in
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(displayEntries) { entry in
                                let isActive = audioPlayer.isPlaying
                                    && audioPlayer.currentTime >= entry.startTime
                                    && audioPlayer.currentTime < entry.endTime
                                TranscriptSegmentRow(
                                    entry: entry,
                                    isActive: isActive,
                                    fontSize: 13,
                                    formatTime: formatTime,
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

                                if entry.id != displayEntries.last?.id {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }
                        .onChange(of: activeTranscriptEntryID(entries: displayEntries)) { _, newID in
                            if let newID, audioPlayer.isPlaying {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                                    proxy.scrollTo(newID, anchor: .center)
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
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
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
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
        }
    }

    private struct TranscriptDisplayEntry: Identifiable {
        let id: UUID
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
        let speaker: String?
    }

    private struct SpeakerTimelineView: View {
        @Environment(\.uiScale) private var uiScale: CGFloat

        let data: SpeakerTimelineData
        let formatTime: (TimeInterval) -> String

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
                        SpeakerShareChip(
                            speaker: speaker,
                            color: speakerTimelineColor(for: speaker.colorIndex),
                            percentString: percentString(speaker.fraction)
                        )
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

        private struct SpeakerShareChip: View {
            @Environment(\.uiScale) private var uiScale: CGFloat

            let speaker: SpeakerTimelineData.SpeakerSummary
            let color: Color
            let percentString: String

            var body: some View {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color)
                        .frame(width: 4, height: 18)
                    Text(speaker.speakerName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(percentString)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                }
                .font(.cadenza(13 - 1, scale: uiScale))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(color.opacity(0.26), lineWidth: 1)
                )
            }
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

    private struct TranscriptSegmentRow<SpeakerView: View>: View {
        @Environment(\.uiScale) private var uiScale: CGFloat

        let entry: TranscriptDisplayEntry
        let isActive: Bool
        let fontSize: Double
        let formatTime: (TimeInterval) -> String
        @ViewBuilder let speakerLabel: (String) -> SpeakerView
        let onTap: () -> Void

        @State private var isHovered = false

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Copy button — visible on hover, placed next to timestamp
                CopySegmentButton(text: entry.text, isRowHovered: isHovered)

                // Timestamp
                Text(formatTime(entry.startTime))
                    .font(.cadenza(13 - 2, design: .monospaced, scale: uiScale))
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 38, alignment: .trailing)

                // Speaker + text
                VStack(alignment: .leading, spacing: 3) {
                    if let speaker = entry.speaker {
                        speakerLabel(speaker)
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

    private func activeTranscriptEntryID(entries: [TranscriptDisplayEntry]) -> UUID? {
        guard audioPlayer.isPlaying else { return nil }
        let t = audioPlayer.currentTime
        return entries.first(where: { t >= $0.startTime && t < $0.endTime })?.id
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

                if !quickResult.actionItems.isEmpty {
                    SummarySection(title: "Action Items", fontSize: 13) {
                        ForEach(quickResult.actionItems, id: \.task) { item in
                            HStack {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(item.task)
                                        .font(.cadenzaBody(13, scale: uiScale))
                                    if let assignee = item.assignee {
                                        Text(assignee)
                                            .font(.cadenza(13, scale: uiScale))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                yourTasksSection(quickResult.yourTasks)

                // Enrich spinner
                if appState.isEnrichingSummary(for: recordingID) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Enriching decisions & follow-ups...")
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
                if !summary.chapters.isEmpty {
                    SummarySection(title: "Chapters", fontSize: 13) {
                        ForEach(summary.chapters, id: \.title) { chapter in
                            HStack(alignment: .top, spacing: 8) {
                                Text(formatTime(chapter.startSeconds))
                                    .font(.cadenza(13 - 2, design: .monospaced, scale: uiScale))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .frame(minWidth: 50, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chapter.title)
                                        .font(.cadenza(13, weight: .medium, scale: uiScale))
                                    if !chapter.summary.isEmpty {
                                        Text(chapter.summary)
                                            .font(.cadenzaBody(13 - 1, scale: uiScale))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                audioPlayer.seek(to: chapter.startSeconds)
                                if !audioPlayer.isPlaying {
                                    audioPlayer.play()
                                }
                            }
                        }
                    }
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

                if !summary.actionItems.isEmpty {
                    SummarySection(title: "Action Items", fontSize: 13) {
                        ForEach(summary.actionItems) { item in
                            HStack {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(item.task)
                                        .font(.cadenzaBody(13, scale: uiScale))
                                    if let assignee = item.assignee {
                                        Text(assignee)
                                            .font(.cadenza(13, scale: uiScale))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
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
