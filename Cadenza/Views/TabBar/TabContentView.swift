import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    @AppStorage("recordingsSort") private var recordingsSort: String = "dateNewest"

    var body: some View {
        @Bindable var appState = appState

        Group {
            // Recording detail is presented by MainWindow's NavigationStack. Keep
            // the originating branch as the stable root so opening and closing a
            // recording does not destroy folder/tag/recap scroll, selection, or AI state.
            let dest = Self.rootDestination(
                for: appState.activeDestination,
                returnStack: appState.navigationReturnStack
            )
            destinationContent(for: dest)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Processing Error", isPresented: Binding(
            get: { appState.postProcessingError != nil },
            set: { if !$0 { appState.postProcessingError = nil } }
        )) {
            Button("OK") { appState.postProcessingError = nil }
        } message: {
            Text(appState.postProcessingError ?? "")
        }
    }

    static func rootDestination(
        for destination: NavigationDestination,
        returnStack: [NavigationDestination] = []
    ) -> NavigationDestination {
        guard case .recordingDetail = destination else { return destination }

        // A recording can replace another pushed recording. Walk past detail
        // entries so the NavigationStack root never becomes another detail page.
        for candidate in returnStack.reversed() {
            if case .recordingDetail = candidate { continue }
            return candidate
        }
        return .allRecordings
    }

    @ViewBuilder
    private func destinationContent(for destination: NavigationDestination) -> some View {
        switch destination {
        case .allRecordings:
            recordingsPage(filterMode: .all)

        case .folder(let id):
            layeredContent {
                FolderDetailView(folderID: id)
                    .id(id)
            }

        case .smartFolder(let id):
            recordingsPage(filterMode: .smartFolder(id))

        case .tag(let name):
            recordingsPage(filterMode: .tag(name))

        case .trash:
            TrashContentView()

        case .calendar:
            layeredContent {
                CalendarContainerView()
            }

        case .recaps:
            layeredContent {
                RecapsListView()
            }

        case .recapDetail(let recapID):
            layeredContent {
                RecapDetailView(recapID: recapID)
                    .id(recapID)
            }

        case .aiAssistant(let initialQuery):
            layeredContent {
                AIChatView(initialQuery: initialQuery)
            }

        case .settings:
            layeredContent {
                SettingsWorkspaceView()
            }

        case .recordingDetail:
            // MainWindow normalizes this destination to a non-detail return root
            // before reaching the switch and pushes RecordingDetailPage above it.
            // Keep an exhaustive fallback for future direct callers.
            recordingsPage(filterMode: .all)

        }
    }

    private func recordingsPage(filterMode: RecordingsFilterMode) -> some View {
        let recordings = applySpeakerFilter(recordingsForFilter(filterMode))
        let smartFolder: SmartFolderDTO? = if case .smartFolder(let id) = filterMode {
            appState.smartFolder(id: id)
        } else {
            nil
        }

        return RecordingsContentView(
            recordings: recordings,
            smartFolder: smartFolder,
            scrollContentTopPadding: RecordingsTopChromeMetrics.contentTopPadding
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 点空白处收起搜索框焦点：没有 contentShape 时空白区不参与 hit test，
        // 这个手势就只在"已经有内容"的地方生效，等于没做。
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .cadenzaSafeAreaBar(edge: .top, alignment: .trailing, spacing: 0) {
            RecordingsTopBar()
        }
        .onChange(of: appState.searchQuery) { _, newValue in
            let folderID: UUID? = if case .folder(let id) = filterMode { id } else { nil }
            let tagFilter: String? = if case .tag(let t) = filterMode { t } else { nil }
            appState.searchRecordings(query: newValue, sortKey: recordingsSort, folderID: folderID, tagFilter: tagFilter)
        }
        .onChange(of: recordingsSort) { _, newValue in
            guard !appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let folderID: UUID? = if case .folder(let id) = filterMode { id } else { nil }
            let tagFilter: String? = if case .tag(let t) = filterMode { t } else { nil }
            appState.searchRecordings(query: appState.searchQuery, sortKey: newValue, folderID: folderID, tagFilter: tagFilter)
        }
    }

    private func layeredContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .appWorkspacePanel(cornerRadius: AppStyle.Radius.panel)
    }

    // MARK: - Sorting & Search

    /// Top-bar person chips narrow every recordings page to one mapped
    /// speaker; a nil filter is a no-op.
    private func applySpeakerFilter(_ list: [RecordingDTO]) -> [RecordingDTO] {
        guard let person = appState.librarySpeakerFilter else { return list }
        return list.filter { $0.speakerNames?.contains(person) == true }
    }

    private func recordingsForFilter(_ mode: RecordingsFilterMode) -> [RecordingDTO] {
        if RecordingSearchDataSourcePolicy.usesSearchResults(query: appState.searchQuery) {
            if case .smartFolder(let id) = mode {
                return smartFolderRecordings(id: id, source: appState.searchResults)
            }
            return appState.searchResults
        }
        switch mode {
        case .all:
            return appState.sortedLibraryRecordings(sortKey: recordingsSort)
        case .folder(let id):
            if let folder = appState.folders.first(where: { $0.id == id }) {
                return sortedFolderRecordings(folder)
            }
            return []
        case .smartFolder(let id):
            return smartFolderRecordings(id: id, source: appState.recordings)
        case .tag(let tag):
            return appState.libraryRecordings(tag: tag, sortKey: recordingsSort)
        }
    }

    private func applySortToRecordings(_ recordings: [RecordingDTO]) -> [RecordingDTO] {
        RecordingSorting.sort(recordings, by: recordingsSort)
    }

    private func sortedFolderRecordings(_ folder: FolderDTO) -> [RecordingDTO] {
        let folderRecordings = appState.recordings.filter { $0.folderID == folder.id }
        let sortKey = UserDefaults.standard.string(forKey: ActiveProfileDefaults.key("folderSort.\(folder.id)")) ?? recordingsSort
        return RecordingSorting.sort(folderRecordings, by: sortKey)
    }

    private func smartFolderRecordings(id: String, source: [RecordingDTO]) -> [RecordingDTO] {
        guard let smartFolder = appState.smartFolder(id: id) else { return [] }
        let smartFolderIDs = Set(smartFolder.recordingIDs)
        return applySortToRecordings(source.filter { smartFolderIDs.contains($0.id) })
    }
}

enum RecordingSearchDataSourcePolicy {
    static func usesSearchResults(query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct RecordingDetailPage: View {
    let recordingID: UUID

    var body: some View {
        RecordingDetailView(recordingID: recordingID)
            .id(recordingID)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .appWorkspacePanel(cornerRadius: AppStyle.Radius.panel)
    }
}

private enum RecordingsFilterMode {
    case all
    case folder(UUID)
    case smartFolder(String)
    case tag(String)
}

private enum RecordingsTopChromeMetrics {
    static let contentTopPadding: CGFloat = 0
}

// MARK: - Recordings Top Bar

enum RecordingsTopBarLayoutMetrics {
    private static func safeScale(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 1
    }

    static func controlDimension(scale: CGFloat) -> CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 32,
            symbolPointSize: 15,
            scale: safeScale(scale)
        )
    }

    static func usesStackedLayout(scale: CGFloat) -> Bool {
        safeScale(scale) >= CadenzaTextScale.factor(.accessibility1)
    }

    static func searchWidth(isExpanded: Bool, scale: CGFloat) -> CGFloat {
        let control = controlDimension(scale: scale)
        return isExpanded ? max(220, ceil(control * 3)) : control
    }
}

struct RecordingsTopBar: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(AppState.self) private var appState
    @AppStorage("contentViewMode") private var contentViewModeRaw: String = "waterfall"
    @AppStorage("recordingsSort") private var recordingsSort: String = "dateNewest"

    @FocusState private var isSearchFocused: Bool
    @State private var isSearchHovered = false
    @State private var showTagsPopover = false

    private var controlSize: CGFloat {
        RecordingsTopBarLayoutMetrics.controlDimension(scale: uiScale)
    }

    var body: some View {
        Group {
            if RecordingsTopBarLayoutMetrics.usesStackedLayout(scale: uiScale) {
                VStack(alignment: .trailing, spacing: 6) {
                    modeAndSortControls
                    searchControl
                }
            } else {
                // Full-width context bar: search and filters lead, the view
                // and sort controls trail. Each control keeps its own glass
                // capsule; there is no full-width material slab behind them.
                HStack(spacing: 6) {
                    searchControl
                    personFilterChips
                    tagMenuChip
                    Spacer(minLength: 6)
                    modeAndSortControls
                }
            }
        }
        // Match the collection's own horizontal padding so the search field's
        // left edge and the sort control's right edge line up with the cards.
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Person & Tag Filters

    /// Most-recurring mapped speakers across the library; the chips filter
    /// every recordings page down to one person.
    private var topSpeakers: [String] {
        appState.libraryTopSpeakers(limit: 3)
    }

    /// One standalone capsule per person, matching the concept's chip row.
    @ViewBuilder
    private var personFilterChips: some View {
        ForEach(topSpeakers, id: \.self) { name in
            personChip(name)
        }
    }

    private func personChip(_ name: String) -> some View {
        let isSelected = appState.librarySpeakerFilter == name
        return Button {
            appState.librarySpeakerFilter = isSelected ? nil : name
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(RecordingCardView.tagColor(for: name).opacity(0.22))
                    Text(verbatim: String(name.prefix(1)).uppercased())
                        .font(.cadenza(8, weight: .bold, scale: uiScale))
                        .foregroundStyle(RecordingCardView.tagColor(for: name))
                }
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
                Text(name)
                    .font(.cadenza(11, weight: isSelected ? .semibold : .regular, scale: uiScale))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.15) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.cadenzaPlain)
        .cadenzaGlass(in: Capsule(), interactive: true)
        .overlay(
            Capsule()
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.4 : 0), lineWidth: 1)
        )
        .help("Show only this speaker")
        .accessibilityValue(isSelected ? Text("Selected") : Text("Not selected"))
    }

    private var allTags: [String] {
        appState.libraryTagsByFrequency
    }

    /// Button + popover, never `Menu`: a borderless menu's label is laid out
    /// inside AppKit's own button box, which both offsets the clickable area
    /// and drops the glass background entirely (same quirk the calendar-link
    /// row documents). A plain Button renders and hit-tests like every other
    /// chip in this bar.
    @ViewBuilder
    private var tagMenuChip: some View {
        let tags = allTags
        if !tags.isEmpty {
            Button {
                showTagsPopover = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "tag")
                        .font(.cadenza(11, scale: uiScale))
                    Text("Tags")
                        .font(.cadenza(11, scale: uiScale))
                    Image(systemName: "chevron.down")
                        .font(.cadenza(8, weight: .semibold, scale: uiScale))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
            }
            .buttonStyle(.cadenzaPlain)
            .cadenzaGlass(in: Capsule(), interactive: true)
            .popover(isPresented: $showTagsPopover, arrowEdge: .bottom) {
                tagListPopover(tags)
            }
            .accessibilityLabel(Text("Tags"))
        }
    }

    private func tagListPopover(_ tags: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tags, id: \.self) { tag in
                    Button {
                        showTagsPopover = false
                        appState.navigate(to: .tag(tag))
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(RecordingCardView.tagColor(for: tag))
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text(tag)
                                .font(.cadenza(12, scale: uiScale))
                                .lineLimit(1)
                            Spacer(minLength: 12)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.cadenzaPlain)
                }
            }
            .padding(6)
        }
        .frame(width: 220)
        .frame(maxHeight: 360)
    }

    private var modeAndSortControls: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                viewModeButton("rectangle.grid.2x2", mode: .waterfall, help: "Waterfall")
                viewModeButton("square.grid.2x2", mode: .grid, help: "Grid")
                viewModeButton("list.bullet", mode: .list, help: "List")
            }
            .padding(4)
            .cadenzaGlass(in: Capsule(), interactive: true)

            sortButton
                .help("Sort")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .cadenzaGlass(in: Capsule(), interactive: true)
        }
    }

    private var searchControl: some View {
        // Persistent search: the field is always visible, so searching is a
        // single click (or keystroke) instead of hiding behind an icon.
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.cadenza(15, weight: .regular, scale: uiScale))
                .foregroundStyle(isSearchFocused || isSearchHovered ? .primary : .secondary)
                .accessibilityHidden(true)

            TextField("Search title, transcript, summary", text: Binding(
                get: { appState.searchQuery },
                set: { appState.searchQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.cadenza(12, scale: uiScale))
            .focused($isSearchFocused)
            .onExitCommand { clearSearch() }
            .accessibilityLabel("Search")
            .background {
                // Invisible ⌘K target; the visible hint is the chip below.
                Button("") { isSearchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .hidden()
            }

            if appState.searchQuery.isEmpty && !isSearchFocused {
                Text(verbatim: "⌘K")
                    .font(.cadenza(9, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
                    .accessibilityHidden(true)
            }

            if !appState.searchQuery.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.cadenza(12, weight: .regular, scale: uiScale))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.cadenzaPlain)
                .accessibilityLabel("Clear")
            }
        }
        .frame(
            // Wider floor than the expand-on-demand era: the persistent field
            // carries the full "title, transcript, summary" placeholder.
            width: max(280, RecordingsTopBarLayoutMetrics.searchWidth(
                isExpanded: true,
                scale: uiScale
            )),
            height: controlSize
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .cadenzaGlass(in: Capsule(), interactive: true)
        .contentShape(Rectangle())
        .onHover { isSearchHovered = $0 }
    }

    private func clearSearch() {
        appState.searchQuery = ""
        isSearchFocused = false
    }

    @State private var isSortHovered = false

    private var sortButton: some View {
        Menu {
            Picker("", selection: $recordingsSort) {
                Text("Date (Newest)").tag("dateNewest")
                Text("Date (Oldest)").tag("dateOldest")
                Text("Recently Accessed").tag("recentlyAccessed")
                Divider()
                Text("Name (A→Z)").tag("nameAZ")
                Text("Name (Z→A)").tag("nameZA")
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.cadenza(15, weight: .regular, scale: uiScale))
                .foregroundStyle(isSortHovered ? .secondary : .tertiary)
                .frame(width: controlSize, height: controlSize)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSortHovered ? Color.primary.opacity(0.06) : .clear)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: controlSize, height: controlSize)
        .onHover { isSortHovered = $0 }
        .accessibilityLabel("Sort")
    }

    private func viewModeButton(
        _ icon: String,
        mode: ContentViewMode,
        help: LocalizedStringKey
    ) -> some View {
        GlassIconButton(
            icon: icon,
            isSelected: contentViewModeRaw == mode.rawValue
        ) {
            contentViewModeRaw = mode.rawValue
        }
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityValue(contentViewModeRaw == mode.rawValue ? Text("Selected") : Text("Not selected"))
    }
}

// MARK: - Processing Toast

enum ProcessingToastPhase: Equatable {
    case transcribing
    case summarizing
    case complete
    case discarded(String)

    var title: String {
        switch self {
        case .transcribing: String(localized: "Transcribing...")
        case .summarizing: String(localized: "Generating summary...")
        case .complete: String(localized: "Processing complete")
        case .discarded(let reason): reason
        }
    }

    var symbol: String {
        switch self {
        case .transcribing: "waveform"
        case .summarizing: "sparkles"
        case .complete: "checkmark.circle.fill"
        case .discarded: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .complete: .green
        case .discarded: .orange
        default: .secondary
        }
    }

    var showsSpinner: Bool {
        switch self {
        case .complete, .discarded: false
        default: true
        }
    }
}


// MARK: - Glass Icon Button

private struct GlassIconButton: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var controlSize: CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 32,
            symbolPointSize: 15,
            scale: uiScale
        )
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.cadenza(15, weight: .regular, scale: uiScale))
                .foregroundStyle(isSelected ? .primary : (isHovered ? .secondary : .tertiary))
                .frame(width: controlSize, height: controlSize)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.primary.opacity(0.12) : (isHovered ? Color.primary.opacity(0.06) : .clear))
                )
        }
        .buttonStyle(.cadenzaPlain)
        .onHover { isHovered = $0 }
    }
}
