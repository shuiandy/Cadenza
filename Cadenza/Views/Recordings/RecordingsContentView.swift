import SwiftUI

enum RecordingsEmptyStateKind: Equatable {
    case loadingLibrary
    case searching
    case noSearchMatches
    case smartFolder
    case library

    static func resolve(
        isLoadingLibrary: Bool,
        isSearching: Bool,
        searchQuery: String,
        hasSmartFolder: Bool
    ) -> Self {
        if isLoadingLibrary { return .loadingLibrary }
        let hasSearch = !searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if hasSearch, isSearching { return .searching }
        if hasSearch { return .noSearchMatches }
        return hasSmartFolder ? .smartFolder : .library
    }
}
import AppKit

/// The UI action guard prevents an isolated fixture from reaching generation;
/// this second boundary prevents a future direct call from constructing an AI
/// service before the runtime policy has been checked.
enum RecordingsContentGenerationBoundary {
    static func constructService<Service>(
        startupPolicy: AppState.StartupPolicy,
        factory: () -> Service?
    ) -> Service? {
        guard startupPolicy.allowsContentGeneration else { return nil }
        return factory()
    }
}

// MARK: - Collection Performance

private enum RecordingsPerformance {
    static let cardMinimumWidth: CGFloat = 220
    /// The day-grouped grid breathes more than the waterfall: roomier cards
    /// (three to four columns at typical widths) per the concept layout.
    static let gridCardMinimumWidth: CGFloat = 300
    static let cardSpacing: CGFloat = 12
}

/// Reference-only registry for the AppKit views that back currently materialized
/// cards. Reading their frames in response to a mouse event does not mutate
/// SwiftUI state, so ordinary scrolling never feeds geometry back into layout.
@MainActor
private final class CardFrameRegistry {
    private var views: [UUID: WeakCardFrameView] = [:]

    func register(_ view: NSView, recordingID: UUID) {
        views[recordingID] = WeakCardFrameView(view)
    }

    func unregister(_ view: NSView, recordingID: UUID) {
        guard views[recordingID]?.view === view else { return }
        views.removeValue(forKey: recordingID)
    }

    func visibleFrames(relativeTo target: NSView) -> [UUID: CGRect] {
        var liveViews: [UUID: WeakCardFrameView] = [:]
        var frames: [UUID: CGRect] = [:]

        for (recordingID, box) in views {
            guard let view = box.view else { continue }
            liveViews[recordingID] = box
            guard view.window === target.window,
                  !view.isHiddenOrHasHiddenAncestor else { continue }

            let frame = target.convert(view.bounds, from: view)
            if frame.intersects(target.bounds) {
                frames[recordingID] = frame
            }
        }

        views = liveViews
        return frames
    }
}

private final class WeakCardFrameView {
    weak var view: NSView?

    init(_ view: NSView) {
        self.view = view
    }
}

private struct CardFrameReporter: NSViewRepresentable {
    let recordingID: UUID
    let registry: CardFrameRegistry

    func makeNSView(context: Context) -> CardFrameReportingNSView {
        let view = CardFrameReportingNSView()
        view.configure(recordingID: recordingID, registry: registry)
        return view
    }

    func updateNSView(_ nsView: CardFrameReportingNSView, context: Context) {
        nsView.configure(recordingID: recordingID, registry: registry)
    }
}

private final class CardFrameReportingNSView: NSView {
    private var recordingID: UUID?
    private weak var registry: CardFrameRegistry?

    // This view exists only as a geometry probe behind the SwiftUI cell. It
    // must never become the AppKit hit-test result for clicks or context menus.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(recordingID: UUID, registry: CardFrameRegistry) {
        if let oldID = self.recordingID,
           oldID != recordingID || self.registry !== registry {
            self.registry?.unregister(self, recordingID: oldID)
        }
        self.recordingID = recordingID
        self.registry = registry
        if window != nil {
            registry.register(self, recordingID: recordingID)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let recordingID, let registry else { return }
        if window == nil {
            registry.unregister(self, recordingID: recordingID)
        } else {
            registry.register(self, recordingID: recordingID)
        }
    }
}

// MARK: - Main View

struct RecordingsContentView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let recordings: [RecordingDTO]
    let smartFolder: SmartFolderDTO?
    let scrollContentTopPadding: CGFloat

    @AppStorage("contentViewMode") private var viewModeRaw: String = "waterfall"
    @Environment(AppState.self) private var appState

    private var viewMode: ContentViewMode {
        ContentViewMode(rawValue: viewModeRaw) ?? .grid
    }

    private var isShowingRecordingDetail: Bool {
        if case .recordingDetail = appState.activeDestination { return true }
        return false
    }

    // Rename
    @State private var selectedRecording: RecordingDTO?
    @State private var showRenameAlert = false
    @State private var renameText = ""

    // Selection
    @State private var selectedIDs: Set<UUID> = []
    /// Progress of a running batch re-summarize; nil when idle. Kept as counts rather
    /// than a pre-formatted string so the label stays localizable.
    @State private var resummarizeProgress: (done: Int, total: Int)?

    // Rubber band
    @State private var rubberBandRect: CGRect?
    @State private var cardFrameRegistry = CardFrameRegistry()

    // Move to folder
    private var folders: [FolderDTO] { appState.folders }

    // Export
    @State private var isExporting = false

    init(
        recordings: [RecordingDTO],
        smartFolder: SmartFolderDTO? = nil,
        scrollContentTopPadding: CGFloat = 0
    ) {
        self.recordings = recordings
        self.smartFolder = smartFolder
        self.scrollContentTopPadding = scrollContentTopPadding
    }

    var body: some View {
        let emptyState = RecordingsEmptyStateKind.resolve(
            isLoadingLibrary: appState.isLoadingRecordings,
            isSearching: appState.isSearchingRecordings,
            searchQuery: appState.searchQuery,
            hasSmartFolder: smartFolder != nil
        )
        if recordings.isEmpty && emptyState == .loadingLibrary {
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.large)
                Text("Loading recordings...")
                    .font(.cadenza(.headline, scale: uiScale))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if recordings.isEmpty && emptyState == .searching {
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.large)
                Text("Searching recordings…")
                    .font(.cadenza(.headline, scale: uiScale))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if recordings.isEmpty {
            VStack {
                Spacer(minLength: 0)
                if emptyState == .noSearchMatches {
                    ContentUnavailableView(
                        "No Matching Recordings",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search.")
                    )
                } else if let smartFolder {
                    ContentUnavailableView(
                        "No Smart Folder Matches",
                        systemImage: smartFolder.icon,
                        description: Text("Matched recordings will appear here automatically.")
                    )
                } else {
                    ContentUnavailableView(
                        "No Recordings",
                        systemImage: "waveform.circle",
                        description: Text("Your recordings will appear here after you record a meeting.")
                    )
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // The strip lives OUTSIDE the ScrollView on purpose: the
                    // marquee overlay consumes mouse-downs on the scroll document
                    // background, so an in-document button would never receive
                    // its click. As fixed chrome it also stays visible while
                    // scrolling, matching the calendar-entry concept.
                    // Isolated struct: it is the only reader of the 5 s calendar
                    // mirror and owns its own clock, so neither reaches this body.
                    TodayMeetingStrip(smartFolder: smartFolder)
                    ZStack {
                        ScrollView {
                            recordingsLayout
                                .padding(.top, scrollContentTopPadding)
                                // Keep the last row clear of the persistent AI button and,
                                // when active, the batch toolbar layered above the scroll view.
                                .padding(.bottom, selectedIDs.isEmpty ? 72 : 96)
                        }
                        .cadenzaSoftTopScrollEdgeEffect()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        // Rubber band visual overlay
                        if let rect = rubberBandRect {
                            Canvas { context, _ in
                                context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.12)))
                                context.stroke(Path(rect), with: .color(Color.accentColor.opacity(0.4)), lineWidth: 1)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        RubberBandGestureOverlay(
                            frameRegistry: cardFrameRegistry,
                            isActive: !isShowingRecordingDetail,
                            selectedIDs: $selectedIDs,
                            rubberBandRect: $rubberBandRect
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    }
                }

                // Floating batch toolbar
                if !selectedIDs.isEmpty {
                    batchToolbar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.18), value: selectedIDs.isEmpty)
            .onExitCommand {
                if !selectedIDs.isEmpty {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        selectedIDs.removeAll()
                    }
                }
            }
            .alert("Rename Recording", isPresented: $showRenameAlert) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let recording = selectedRecording, !renameText.isEmpty {
                        appState.updateRecordingTitle(recordingID: recording.id, title: renameText)
                    }
                }
            }
        }
    }

    // MARK: - Recordings Layout

    @ViewBuilder
    private var recordingsLayout: some View {
        Group {
            if viewMode == .waterfall {
                contentForSection(recordings)
                    .padding()
            } else {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: .sectionHeaders) {
                    ForEach(dayGroups, id: \.day) { group in
                        Section {
                            contentForSection(group.recordings)
                        } header: {
                            dayHeader(group)
                        }
                    }
                }
                .padding()
                .onChange(of: recordings, initial: true) { _, updated in
                    dayGroupCache = DayGroupCache(input: updated, groups: RecordingDayGrouper.group(updated))
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: viewModeRaw)
    }

    /// Date-first section header: the day carries the scan, with the
    /// per-day count and total duration as secondary context.
    private func dayHeader(_ group: RecordingDayGrouper.Group) -> some View {
        HStack(spacing: 8) {
            Text(group.day.formatted(Self.dayHeaderDateStyle))
                .font(.cadenza(13 - 1, weight: .bold, scale: uiScale))
                .foregroundStyle(.secondary)
            Text(verbatim: dayHeaderDetail(group))
                .font(.cadenza(13 - 3, scale: uiScale))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppStyle.ColorToken.softFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppStyle.ColorToken.stroke, lineWidth: 0.6)
        )
    }

    private func dayHeaderDetail(_ group: RecordingDayGrouper.Group) -> String {
        let countString = String(localized: "\(group.recordings.count) recordings")
        let durationString = Duration.seconds(group.totalDuration).formatted(
            .units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2)
        )
        guard group.totalDuration >= 60 else { return countString }
        return "\(countString) · \(durationString)"
    }

    private static let dayHeaderDateStyle = Date.FormatStyle.dateTime
        .month(.abbreviated).day().weekday(.wide)


    // MARK: - Card Click Handling

    private func handleCardClick(_ id: UUID) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        } else {
            selectedIDs = [id]
        }
    }

    // MARK: - Batch Toolbar

    private var batchToolbar: some View {
        HStack(spacing: 12) {
            Text("\(selectedIDs.count) selected")
                .font(.cadenza(12, weight: .semibold, scale: uiScale))
                .foregroundStyle(.primary)

            Divider()
                .frame(height: 14)

            Button {
                let allIDs = Set(recordings.map(\.id))
                selectedIDs = selectedIDs == allIDs ? [] : allIDs
            } label: {
                Image(systemName: selectedIDs.count == recordings.count ? "checkmark.circle.badge.xmark" : "checkmark.circle")
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.cadenzaPlain)
            .help(selectedIDs.count == recordings.count ? String(localized: "Deselect All") : String(localized: "Select All"))

            if !folders.isEmpty {
                Menu {
                    Button {
                        batchMoveToFolder(nil)
                    } label: {
                        Label("None", systemImage: "minus.circle")
                    }
                    Divider()
                    ForEach(folders) { folder in
                        Button {
                            batchMoveToFolder(folder)
                        } label: {
                            Label { Text(folder.name) } icon: { FolderIconView(icon: folder.icon, color: .secondary, size: 14) }
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.cadenza(14, weight: .medium, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Move to Folder")
            }

            batchSmartFolderActions

            // Labelled rather than icon-only like its neighbours: SF Symbols has no
            // "document + redo" glyph, so any icon here reads as "refresh the list".
            // It also overwrites summaries *and* titles across N recordings, so the
            // count is part of the affordance.
            if let progress = resummarizeProgress {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Regenerating \(progress.done)/\(progress.total)")
                        .font(.cadenza(12, weight: .medium, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            } else if selectedTranscribedCount > 0 {
                Button {
                    batchRegenerateSummaries()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Regenerate Summaries (\(selectedTranscribedCount))")
                    }
                    .font(.cadenza(12, weight: .medium, scale: uiScale))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.cadenzaPlain)
                .disabled(!appState.startupPolicy.allowsContentGeneration)
                .help("Regenerate summaries and titles from the stored transcripts")
            }

            Button {
                batchDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.cadenzaPlain)
            .help("Delete")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .appToolbarRail(cornerRadius: 18)
        .disabled(appState.isBatchMutationInProgress)
    }

    // MARK: - Batch Actions

    private func batchDelete() {
        let targetIDs = selectedIDs
        guard !targetIDs.isEmpty, !appState.isBatchMutationInProgress else { return }
        appState.deleteRecordings(recordingIDs: targetIDs) { result in
            guard result.didCommit else { return }
            selectedIDs.subtract(targetIDs)
        }
    }

    private func batchMoveToFolder(_ folder: FolderDTO?) {
        let targetIDs = selectedIDs
        guard !targetIDs.isEmpty, !appState.isBatchMutationInProgress else { return }
        appState.moveRecordingsToFolder(
            recordingIDs: targetIDs,
            folderID: folder?.id
        ) { result in
            guard result.didCommit else { return }
            selectedIDs.subtract(targetIDs)
        }
    }

    /// Selected recordings that have a transcript to summarize from — summaries are
    /// regenerated from the stored transcript, so audio is not required (imported
    /// recordings have none).
    private var selectedTranscribedCount: Int {
        recordings.filter { selectedIDs.contains($0.id) && $0.hasTranscript }.count
    }

    /// Re-run the app's own summarizer over the selected recordings' transcripts.
    /// Strictly sequential: `PostProcessingCoordinator.generateSummary` is single-flight
    /// (`guard !isGeneratingSummary`), so firing these in parallel would silently drop
    /// all but the first. Also rewrites each title, since `saveSummary` adopts the
    /// summary's title when non-empty.
    private func batchRegenerateSummaries() {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        let targets = recordings.filter { selectedIDs.contains($0.id) && $0.hasTranscript }.map(\.id)
        guard !targets.isEmpty, resummarizeProgress == nil else { return }
        let provider = UserDefaults.standard.string(forKey: "defaultAIProvider") ?? AIProvider.apple.rawValue
        let language = UserDefaults.standard.string(forKey: "summaryLanguage") ?? "auto"

        Task { @MainActor in
            for (index, id) in targets.enumerated() {
                resummarizeProgress = (done: index + 1, total: targets.count)
                await appState.coordinator.generateSummary(
                    recordingID: id, provider: provider, language: language)
            }
            resummarizeProgress = nil
            appState.refreshRecordings()
        }
    }

    @ViewBuilder
    private var batchSmartFolderActions: some View {
        if let smartFolder {
            Button {
                batchExcludeFromSmartFolder(smartFolder.id)
            } label: {
                Image(systemName: "sparkles.rectangle.stack.badge.minus")
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.cadenzaPlain)
            .help("Exclude from Smart Folder")
        } else if !appState.smartFolderTargets.isEmpty {
            Menu {
                ForEach(appState.smartFolderTargets) { target in
                    Button {
                        batchPinToSmartFolder(target.id)
                    } label: {
                        Label(target.title, systemImage: target.icon)
                    }
                }
            } label: {
                Image(systemName: "sparkles")
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pin to Smart Folder")
        }
    }

    private func batchPinToSmartFolder(_ smartFolderID: String) {
        let targetIDs = selectedIDs
        guard !targetIDs.isEmpty else { return }
        guard appState.pinRecordingsToSmartFolder(
            recordingIDs: targetIDs,
            smartFolderID: smartFolderID
        ) else { return }
        selectedIDs.subtract(targetIDs)
    }

    private func batchExcludeFromSmartFolder(_ smartFolderID: String) {
        let targetIDs = selectedIDs
        guard !targetIDs.isEmpty else { return }
        guard appState.excludeRecordingsFromSmartFolder(
            recordingIDs: targetIDs,
            smartFolderID: smartFolderID
        ) else { return }
        selectedIDs.subtract(targetIDs)
    }

    // MARK: - Content Sections

    @ViewBuilder
    private func contentForSection(_ sectionRecordings: [RecordingDTO]) -> some View {
        switch viewMode {
        case .waterfall:
            // SwiftUI's custom Layout protocol is eager: the former masonry
            // layout instantiated and measured every card below an arbitrary
            // 80-item cutoff. Keep the spacious waterfall card treatment, but
            // use a virtualized grid at every collection size. A genuinely lazy
            // masonry layout needs an NSCollectionView-backed implementation.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: RecordingsPerformance.cardMinimumWidth), spacing: RecordingsPerformance.cardSpacing)],
                spacing: RecordingsPerformance.cardSpacing
            ) {
                ForEach(sectionRecordings) { recording in
                    recordingCard(recording) {
                        RecordingCardView(
                            recording: recording,
                            viewMode: .waterfall,
                            processingPhase: appState.coordinator?.jobPhase(for: recording.id)
                        )
                    }
                }
            }
        case .grid:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: RecordingsPerformance.gridCardMinimumWidth), spacing: RecordingsPerformance.cardSpacing)],
                spacing: RecordingsPerformance.cardSpacing
            ) {
                ForEach(sectionRecordings) { recording in
                    recordingCard(recording) {
                        RecordingCardView(
                            recording: recording,
                            viewMode: .grid,
                            processingPhase: appState.coordinator?.jobPhase(for: recording.id)
                        )
                    }
                }
            }
        case .list:
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(sectionRecordings) { recording in
                    recordingCard(recording) {
                        RecordingListRow(recording: recording)
                    }
                }
            }
        }
    }

    // MARK: - Recording Card (single-click select, double-click open)

    @ViewBuilder
    private func recordingCard<Content: View>(_ recording: RecordingDTO, @ViewBuilder content: () -> Content) -> some View {
        let isSelected = selectedIDs.contains(recording.id)

        content()
            .background {
                CardFrameReporter(recordingID: recording.id, registry: cardFrameRegistry)
            }
            // Selection border
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.5)
                }
            }
            // Double-click → open detail (must be before single-click)
            .onTapGesture(count: 2) {
                appState.openRecordingDetail(recordingID: recording.id, title: recording.title)
            }
            // Single-click → select
            .onTapGesture {
                handleCardClick(recording.id)
            }
            .focusable()
            .onKeyPress(.return) {
                appState.openRecordingDetail(recordingID: recording.id, title: recording.title)
                return .handled
            }
            .onKeyPress(.space) {
                handleCardClick(recording.id)
                return .handled
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(recording.title))
            .accessibilityValue(isSelected ? Text("Selected") : Text("Not selected"))
            .accessibilityHint("Press Return to open. Press Space to select.")
            .accessibilityAction {
                appState.openRecordingDetail(recordingID: recording.id, title: recording.title)
            }
            .accessibilityAction(named: Text("Select")) {
                handleCardClick(recording.id)
            }
            .accessibilityIdentifier("recording-card-\(recording.id.uuidString)")
            .contextMenu {
                // If right-clicked recording is part of selection, actions apply to all selected.
                // The menu content is built while the card is, on every body pass of the
                // library, so the selection is resolved lazily: an O(n) filter over the
                // whole library per visible card was paid on every drag event.
                let affectsMultiple = isSelected && selectedIDs.count > 1
                let affectedCount = affectsMultiple ? selectedIDs.count : 1
                let affected: () -> [RecordingDTO] = {
                    affectsMultiple ? recordings.filter { selectedIDs.contains($0.id) } : [recording]
                }

                // Rename only makes sense for a single recording
                if !affectsMultiple {
                    Button {
                        renameText = recording.title
                        selectedRecording = recording
                        showRenameAlert = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }

                if !folders.isEmpty {
                    Menu {
                        Button {
                            let targetIDs = Set(affected().map(\.id))
                            appState.moveRecordingsToFolder(
                                recordingIDs: targetIDs,
                                folderID: nil
                            ) { result in
                                guard result.didCommit else { return }
                                selectedIDs.subtract(targetIDs)
                            }
                        } label: {
                            Label("None", systemImage: "minus.circle")
                        }
                        Divider()
                        ForEach(folders) { folder in
                            Button {
                                let targetIDs = Set(affected().map(\.id))
                                appState.moveRecordingsToFolder(
                                    recordingIDs: targetIDs,
                                    folderID: folder.id
                                ) { result in
                                    guard result.didCommit else { return }
                                    selectedIDs.subtract(targetIDs)
                                }
                            } label: {
                                Label { Text(folder.name) } icon: { FolderIconView(icon: folder.icon, color: .secondary, size: 14) }
                            }
                        }
                    } label: {
                        let count = affectedCount
                        Label(
                            count > 1 ? String(localized: "Move \(count) to Folder") : String(localized: "Move to Folder"),
                            systemImage: "folder"
                        )
                    }
                    .disabled(appState.isBatchMutationInProgress)
                }

                smartFolderContextActions(count: affectedCount, affected: affected)

                Divider()

                RecordingExportMenu(
                    affected: affected,
                    onNotion: exportToNotion,
                    onCraft: exportToCraft,
                    onLocalFolder: exportToLocalFolder
                )

                Divider()

                Button(role: .destructive) {
                    let targetIDs = Set(affected().map(\.id))
                    appState.deleteRecordings(recordingIDs: targetIDs) { result in
                        guard result.didCommit else { return }
                        selectedIDs.subtract(targetIDs)
                    }
                } label: {
                    let count = affectedCount
                    Label(
                        count > 1 ? String(localized: "Delete \(count) Recordings") : String(localized: "Delete"),
                        systemImage: "trash"
                    )
                }
                .disabled(appState.isBatchMutationInProgress)
            }
    }

    @ViewBuilder
    private func smartFolderContextActions(count affectedCount: Int, affected: @escaping () -> [RecordingDTO]) -> some View {
        if let smartFolder {
            Button {
                let targetIDs = Set(affected().map(\.id))
                guard appState.excludeRecordingsFromSmartFolder(
                    recordingIDs: targetIDs,
                    smartFolderID: smartFolder.id
                ) else { return }
                selectedIDs.subtract(targetIDs)
            } label: {
                let count = affectedCount
                Label(
                    count > 1
                    ? String(localized: "Exclude \(count) from Smart Folder")
                    : String(localized: "Exclude from Smart Folder"),
                    systemImage: "sparkles.rectangle.stack.badge.minus"
                )
            }
            .disabled(appState.isBatchMutationInProgress)
        } else if !appState.smartFolderTargets.isEmpty {
            Menu {
                ForEach(appState.smartFolderTargets) { target in
                    Button {
                        let targetIDs = Set(affected().map(\.id))
                        guard appState.pinRecordingsToSmartFolder(
                            recordingIDs: targetIDs,
                            smartFolderID: target.id
                        ) else { return }
                        selectedIDs.subtract(targetIDs)
                    } label: {
                        Label(target.title, systemImage: target.icon)
                    }
                }
            } label: {
                let count = affectedCount
                Label(
                    count > 1
                    ? String(localized: "Pin \(count) to Smart Folder")
                    : String(localized: "Pin to Smart Folder"),
                    systemImage: "sparkles"
                )
            }
            .disabled(appState.isBatchMutationInProgress)
        }
    }

    // MARK: - Export Actions

    private func exportToNotion(_ recordings: [RecordingDTO]) {
        runBulkExport(recordings, target: "Notion") { id in
            try await appState.exportToNotion(recordingID: id)
        }
    }

    private func exportToCraft(_ recordings: [RecordingDTO]) {
        runBulkExport(recordings, target: "Craft") { id in
            try await appState.exportToCraft(recordingID: id)
        }
    }

    /// 多选 → 本地文件导出。用户已同时选定录音与目标目录，跳过确认弹窗；
    /// preflight（磁盘检查）仍执行。进度可在 Settings → Export & Backup 查看，
    /// 结束后用 toast 汇总（与 Notion/Craft 批量路径一致的反馈形态）。
    private func exportToLocalFolder(_ recordings: [RecordingDTO]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let ids = recordings.map(\.id)
        Task {
            let exporter = appState.exportService.batchFileExporter
            await exporter.prepareAndRun(
                recordingIDs: ids, options: BatchExportOptions(), destination: destination
            )
            switch exporter.phase {
            case .finished(let succeeded, let failures) where failures.isEmpty:
                ToastCenter.shared.success(String(localized: "Exported \(succeeded) recordings."))
                exporter.dismissResult()
            case .finished(let succeeded, let failures):
                ToastCenter.shared.error(
                    String(localized: "Exported \(succeeded) recordings, \(failures.count) failed."),
                    subtitle: failures.first.map { "\($0.title): \($0.reason)" }
                )
            case .failed(let message):
                ToastCenter.shared.error(String(localized: "File export failed"), subtitle: message)
            default:
                break
            }
        }
    }

    /// Bulk export pipeline shared by Notion and Craft. The first
    /// failure stops the loop and surfaces an error toast carrying the
    /// envelope message; success emits a single confirmation toast at
    /// the end. Stop-on-first-failure matches the prior alert behaviour
    /// (so a transient network blip doesn't hide N pending failures
    /// behind a single dialog the user has to dismiss N times).
    private func runBulkExport(
        _ recordings: [RecordingDTO],
        target: String,
        action: @escaping (UUID) async throws -> Void
    ) {
        Task {
            var done = 0
            for recording in recordings {
                do {
                    try await action(recording.id)
                    done += 1
                } catch {
                    NSLog("[Recordings] %@ export failed: %@", target, String(describing: error))
                    let title: String
                    if recordings.count > 1 {
                        title = String(localized: "Export to \(target) failed (\(done)/\(recordings.count) done)")
                    } else {
                        title = String(localized: "Export to \(target) failed")
                    }
                    ToastCenter.shared.error(
                        title,
                        subtitle: ExportUserMessage.message(for: error)
                    )
                    return
                }
            }
            let summary: String
            if done == 1 {
                summary = String(localized: "Exported to \(target)")
            } else {
                summary = String(localized: "Exported \(done) recordings to \(target)")
            }
            ToastCenter.shared.success(summary)
        }
    }

    /// Grouping is O(n log n) and used to run on every body pass, including
    /// selection changes and every invalidation from AppState. The cache is
    /// exact: keyed by the input array itself and refreshed by `onChange`, so
    /// a stale group can never outlive the data it was built from.
    private struct DayGroupCache {
        let input: [RecordingDTO]
        let groups: [RecordingDayGrouper.Group]
    }
    @State private var dayGroupCache: DayGroupCache?

    private var dayGroups: [RecordingDayGrouper.Group] {
        if let dayGroupCache, dayGroupCache.input == recordings {
            return dayGroupCache.groups
        }
        return RecordingDayGrouper.group(recordings)
    }

}

// MARK: - Rubber Band Gesture (NSViewRepresentable)

/// Transparent NSView overlay that uses a local event monitor to intercept
/// mouse-down/drag/up on empty space for rubber-band (marquee) selection.
/// Events on cards pass through to SwiftUI tap gestures normally.
private struct RubberBandGestureOverlay: NSViewRepresentable {
    let frameRegistry: CardFrameRegistry
    let isActive: Bool
    @Binding var selectedIDs: Set<UUID>
    @Binding var rubberBandRect: CGRect?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RubberBandNSView {
        let view = RubberBandNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: RubberBandNSView, context: Context) {
        let c = context.coordinator
        c.frameRegistry = frameRegistry
        c.currentSelectedIDs = selectedIDs
        c.onSelectionChanged = { ids in
            self.selectedIDs = ids
        }
        c.onRubberBandRectChanged = { rect in
            self.rubberBandRect = rect
        }
        nsView.setActive(isActive)
    }

    @MainActor
    final class Coordinator {
        var frameRegistry: CardFrameRegistry?
        var currentSelectedIDs: Set<UUID> = []
        var baseSelection: Set<UUID> = []
        var onSelectionChanged: (@MainActor (Set<UUID>) -> Void)?
        var onRubberBandRectChanged: (@MainActor (CGRect?) -> Void)?
    }
}

/// Resolves the real AppKit target underneath the transparent marquee overlay.
/// Rubber-band selection may only begin from the scroll document background;
/// controls, scrollers, and page-level overlays must receive their events.
@MainActor
enum RubberBandHitTesting {
    static func isScrollDocumentBackgroundHit(
        in window: NSWindow,
        at locationInWindow: NSPoint
    ) -> Bool {
        guard let contentView = window.contentView else { return false }
        let pointInContentView = contentView.convert(locationInWindow, from: nil)
        return isScrollDocumentBackground(contentView.hitTest(pointInContentView))
    }

    private static func isScrollDocumentBackground(_ hitView: NSView?) -> Bool {
        guard let hitView else { return false }

        var ancestor: NSView? = hitView
        while let view = ancestor {
            if view is NSControl || view is NSScroller {
                return false
            }
            ancestor = view.superview
        }

        ancestor = hitView
        while let view = ancestor {
            if let scrollView = view as? NSScrollView,
               let documentView = scrollView.documentView {
                return hitView === documentView || hitView.isDescendant(of: documentView)
            }
            ancestor = view.superview
        }

        return false
    }
}

private final class RubberBandNSView: NSView {
    override var isFlipped: Bool { true }

    var coordinator: RubberBandGestureOverlay.Coordinator?
    nonisolated(unsafe) private var mouseMonitor: Any?
    private var isActive = true
    private var dragState: DragState = .idle
    private var dragStart: CGPoint = .zero
    private var isCommandHeld = false

    private enum DragState {
        case idle, pending, rubberBanding
    }

    // Transparent to hit testing — all events reach the ScrollView / cards normally.
    // We intercept selectively via the local event monitor.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && isActive {
            installMonitorIfNeeded()
        } else if window == nil {
            removeMonitor()
        }
    }

    func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else { return }
        self.isActive = isActive
        if isActive, window != nil {
            installMonitorIfNeeded()
        } else {
            dragState = .idle
            coordinator?.onRubberBandRectChanged?(nil)
            removeMonitor()
        }
    }

    private func installMonitorIfNeeded() {
        guard mouseMonitor == nil else { return }
        // weak self to avoid retain cycle (closure → NSView → mouseMonitor → closure)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleEvent(event) ?? event
        }
    }

    private func removeMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    deinit {
        // mouseMonitor is nonisolated(unsafe) so we can access it in deinit
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        // Only handle when this view is visible and has a real size
        guard isActive,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 0, bounds.height > 0,
              event.window == self.window
        else { return event }

        let localPoint = convert(event.locationInWindow, from: nil)

        switch event.type {
        case .leftMouseDown:
            // Only handle events within our bounds
            guard bounds.contains(localPoint) else { return event }

            // If the click is on a card, pass through to SwiftUI
            if currentCardFrames().values.contains(where: { $0.contains(localPoint) }) {
                return event
            }

            // The transparent overlay spans the whole recordings page, including
            // controls hosted above the ScrollView. Only the real scroll document
            // background is eligible to begin marquee selection.
            guard let window = event.window,
                  RubberBandHitTesting.isScrollDocumentBackgroundHit(
                    in: window,
                    at: event.locationInWindow
                  )
            else { return event }

            // Empty space → start pending rubber band
            dragState = .pending
            dragStart = localPoint
            isCommandHeld = event.modifierFlags.contains(.command)

            if isCommandHeld {
                coordinator?.baseSelection = coordinator?.currentSelectedIDs ?? []
            } else {
                coordinator?.baseSelection = []
            }
            return nil // Consume

        case .leftMouseDragged:
            guard dragState != .idle else { return event }

            if dragState == .pending {
                let dist = hypot(localPoint.x - dragStart.x, localPoint.y - dragStart.y)
                if dist > 3 {
                    dragState = .rubberBanding
                    if !isCommandHeld {
                        coordinator?.onSelectionChanged?([])
                    }
                }
            }

            if dragState == .rubberBanding {
                let rect = normalizedRect(from: dragStart, to: localPoint)
                coordinator?.onRubberBandRectChanged?(rect)
                computeIntersection(rect, cardFrames: currentCardFrames())
            }
            return nil // Consume

        case .leftMouseUp:
            guard dragState != .idle else { return event }

            if dragState == .pending && !isCommandHeld {
                // Click on empty space without drag → deselect all
                coordinator?.onSelectionChanged?([])
            }

            coordinator?.onRubberBandRectChanged?(nil)
            dragState = .idle
            return nil // Consume

        default:
            return event
        }
    }

    private func currentCardFrames() -> [UUID: CGRect] {
        coordinator?.frameRegistry?.visibleFrames(relativeTo: self) ?? [:]
    }

    private func computeIntersection(_ rect: CGRect, cardFrames: [UUID: CGRect]) {
        guard let coordinator else { return }
        var newSelection = coordinator.baseSelection
        for (id, frame) in cardFrames {
            if rect.intersects(frame) {
                newSelection.insert(id)
            }
        }
        // Every drag event lands here (60 to 120 Hz). Writing an equal set
        // into `@State` still invalidates the whole library body plus every
        // visible card's context menu, so only a changed set may propagate.
        guard newSelection != coordinator.currentSelectedIDs else { return }
        coordinator.currentSelectedIDs = newSelection
        coordinator.onSelectionChanged?(newSelection)
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(b.x - a.x), height: abs(b.y - a.y)
        )
    }
}

// MARK: - Today Strip

/// The meeting strip above the library. Isolated on purpose: it is the only
/// reader of `appState.upcomingMeetings`, which the calendar mirror rewrites
/// every 5 s, and it owns the clock for time-derived state ("In progress",
/// "in 12 min"), so the grid body never re-runs for either. The strip lives
/// OUTSIDE the ScrollView: the marquee overlay consumes mouse-downs on the
/// scroll document background, so an in-document button would never receive
/// its click. As fixed chrome it also stays visible while scrolling.
struct TodayMeetingStrip: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(AppState.self) private var appState

    let smartFolder: SmartFolderDTO?

    @State private var prepEvent: MeetingEvent?
    @AppStorage("autoRecordMeetings") private var autoRecordMeetings = false

    var body: some View {
        // Only the unfiltered library shows the strip: folder, tag, smart
        // folder and search contexts stay purely about their result set.
        if smartFolder == nil,
           appState.activeDestination == .allRecordings,
           appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let meetings = appState.upcomingMeetings
            TimelineView(MeetingBoundarySchedule(meetings: meetings)) { context in
                if let meeting = Self.upcomingMeeting(in: meetings, now: context.date) {
                    strip(meeting, now: context.date)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                }
            }
        }
    }

    /// The meeting the strip points at: an in-progress one wins, else the
    /// next not-yet-started one today; nil hides the strip entirely. The
    /// original "not started yet" filter made the strip vanish the moment
    /// the morning's first meeting began. Pure in `now` so the clock, not
    /// the wall time at body evaluation, decides.
    nonisolated static func upcomingMeeting(
        in meetings: [MeetingEventDTO],
        now: Date,
        calendar: Calendar = .current
    ) -> MeetingEventDTO? {
        let todays = meetings.filter {
            !$0.isAllDay && calendar.isDate($0.startDate, inSameDayAs: now) && $0.endDate > now
        }
        return todays.first { $0.startDate <= now && now <= $0.endDate }
            ?? todays.filter { $0.startDate > now }.min { $0.startDate < $1.startDate }
    }

    private func strip(_ meeting: MeetingEventDTO, now: Date) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Today")
                    .font(.cadenza(13 - 1, weight: .bold, scale: uiScale))
                    .foregroundStyle(.secondary)
                Text(now.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
                    .font(.cadenza(13 - 3, scale: uiScale))
                    .foregroundStyle(.tertiary)
            }

            Button {
                appState.navigate(to: .calendar)
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(meetingColor(meeting))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "\(meeting.startDate.formatted(date: .omitted, time: .shortened)) · \(meeting.title)")
                            .font(.cadenza(13 - 1, weight: .semibold, scale: uiScale))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(verbatim: subtitle(meeting, now: now))
                            .font(.cadenza(13 - 3, scale: uiScale))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.cadenzaPlain)
            .accessibilityValue(Text(verbatim: "\(meeting.startDate.formatted(date: .omitted, time: .shortened)) \(meeting.title)"))

            // Pre-meeting entry: the same event card the calendar shows,
            // meeting-prep section included.
            Button {
                prepEvent = appState.calendarManager?.upcomingMeetings
                    .first { $0.id == meeting.id }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.cadenza(13 - 3, scale: uiScale))
                    Text("Meeting Prep")
                        .font(.cadenza(13 - 2, weight: .semibold, scale: uiScale))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.75))
                .contentShape(Capsule())
            }
            .buttonStyle(.cadenzaPlain)
            .popover(item: $prepEvent, arrowEdge: .bottom) { event in
                EventDetailPopover(event: event) {
                    prepEvent = nil
                }
            }

            if autoRecordMeetings {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.cadenza(13 - 4, weight: .bold, scale: uiScale))
                        .foregroundStyle(.green)
                    Text("Auto-record on")
                        .font(.cadenza(13 - 3, scale: uiScale))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Button {
                appState.navigate(to: .calendar)
            } label: {
                HStack(spacing: 4) {
                    Text("View Calendar")
                    Image(systemName: "chevron.right")
                        .font(.cadenza(13 - 4, weight: .semibold, scale: uiScale))
                }
                .font(.cadenza(13 - 2, weight: .semibold, scale: uiScale))
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.cadenzaPlain)
            .accessibilityLabel(Text("View Calendar"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppStyle.ColorToken.softFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppStyle.ColorToken.stroke, lineWidth: 0.75)
        )
    }

    private func subtitle(_ meeting: MeetingEventDTO, now: Date) -> String {
        let app = meeting.meetingApp.flatMap { MeetingApp(rawValue: $0)?.displayName }
        let timing = (meeting.startDate <= now && now <= meeting.endDate)
            ? String(localized: "In progress")
            : Self.relativeFormatter.localizedString(for: meeting.startDate, relativeTo: now)
        return "\(app ?? meeting.calendarName) · \(timing)"
    }

    private func meetingColor(_ meeting: MeetingEventDTO) -> Color {
        meeting.defaultColorHex.isEmpty ? .accentColor : Color(hex: meeting.defaultColorHex)
    }

    private static let relativeFormatter = RelativeDateTimeFormatter()
}

/// Wakes the strip exactly when its text can change: on every minute boundary
/// (relative times) and at each meeting start and end (the "In progress"
/// flip). Replaces the 5 s tick that used to re-run the whole library.
struct MeetingBoundarySchedule: TimelineSchedule {
    let boundaries: [Date]

    init(meetings: [MeetingEventDTO]) {
        boundaries = meetings.flatMap { [$0.startDate, $0.endDate] }.sorted()
    }

    func entries(from start: Date, mode: Mode) -> AnySequence<Date> {
        Self.entries(boundaries: boundaries, from: start)
    }

    nonisolated static func entries(
        boundaries: [Date],
        from start: Date,
        calendar: Calendar = .current
    ) -> AnySequence<Date> {
        let firstMinute = calendar.nextDate(
            after: start, matching: DateComponents(second: 0), matchingPolicy: .nextTime
        ) ?? start.addingTimeInterval(60)
        let pending = boundaries.filter { $0 > start }.sorted()
        var nextMinute = firstMinute
        var index = 0
        return AnySequence(AnyIterator {
            let boundary = index < pending.count ? pending[index] : nil
            let next: Date
            if let boundary, boundary <= nextMinute {
                next = boundary
                index += 1
                if boundary == nextMinute { nextMinute = nextMinute.addingTimeInterval(60) }
            } else {
                next = nextMinute
                nextMinute = nextMinute.addingTimeInterval(60)
            }
            return next
        })
    }
}

// MARK: - Export Submenu

/// The export submenu of a card's context menu. Its `disabled` states read
/// service-level observables (Notion connection, Craft availability, the batch
/// exporter's per-file progress). Inside the card builder those reads made
/// every visible card, and with it the library body, a dependent of a
/// per-exported-file progress write. Here they are dependencies of this small
/// struct only.
private struct RecordingExportMenu: View {
    @Environment(AppState.self) private var appState

    let affected: () -> [RecordingDTO]
    let onNotion: ([RecordingDTO]) -> Void
    let onCraft: ([RecordingDTO]) -> Void
    let onLocalFolder: ([RecordingDTO]) -> Void

    var body: some View {
        Menu {
            Button {
                onNotion(affected())
            } label: {
                Label("Notion", systemImage: "arrow.up.doc")
            }
            .disabled(!appState.notionConnected)

            Button {
                onCraft(affected())
            } label: {
                Label("Craft", systemImage: "doc.richtext")
            }
            .disabled(!appState.craftIsAvailable)

            Divider()

            Button {
                onLocalFolder(affected())
            } label: {
                Label("Local Folder…", systemImage: "folder")
            }
            .disabled(appState.exportService.batchFileExporter.isBusy)
        } label: {
            Label("Export to...", systemImage: "square.and.arrow.up")
        }
    }
}
