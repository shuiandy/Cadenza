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
        let recordings = recordingsForFilter(filterMode)
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

    private func recordingsForFilter(_ mode: RecordingsFilterMode) -> [RecordingDTO] {
        if RecordingSearchDataSourcePolicy.usesSearchResults(query: appState.searchQuery) {
            if case .smartFolder(let id) = mode {
                return smartFolderRecordings(id: id, source: appState.searchResults)
            }
            return appState.searchResults
        }
        switch mode {
        case .all:
            return applySortToRecordings(appState.recordings)
        case .folder(let id):
            if let folder = appState.folders.first(where: { $0.id == id }) {
                return sortedFolderRecordings(folder)
            }
            return []
        case .smartFolder(let id):
            return smartFolderRecordings(id: id, source: appState.recordings)
        case .tag(let tag):
            let key = TagNormalizer.formatKey(tag)
            let filtered = appState.recordings.filter { rec in rec.tags.contains { TagNormalizer.formatKey($0) == key } }
            return applySortToRecordings(filtered)
        }
    }

    private func applySortToRecordings(_ recordings: [RecordingDTO]) -> [RecordingDTO] {
        switch recordingsSort {
        case "dateOldest":
            return recordings.sorted { $0.startDate < $1.startDate }
        case "recentlyAccessed":
            return recordings.sorted { ($0.lastAccessedDate ?? .distantPast) > ($1.lastAccessedDate ?? .distantPast) }
        case "nameAZ":
            return recordings.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "nameZA":
            return recordings.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        default:
            return recordings.sorted { $0.startDate > $1.startDate }
        }
    }

    private func sortedFolderRecordings(_ folder: FolderDTO) -> [RecordingDTO] {
        let folderRecordings = appState.recordings.filter { $0.folderID == folder.id }
        let sortKey = UserDefaults.standard.string(forKey: ActiveProfileDefaults.key("folderSort.\(folder.id)")) ?? recordingsSort
        switch sortKey {
        case "dateOldest":
            return folderRecordings.sorted { $0.startDate < $1.startDate }
        case "recentlyAccessed":
            return folderRecordings.sorted { ($0.lastAccessedDate ?? .distantPast) > ($1.lastAccessedDate ?? .distantPast) }
        case "nameAZ":
            return folderRecordings.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "nameZA":
            return folderRecordings.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        default:
            return folderRecordings.sorted { $0.startDate > $1.startDate }
        }
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

    @State private var isSearchExpanded = false
    @FocusState private var isSearchFocused: Bool
    @State private var isSearchHovered = false

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
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    modeAndSortControls
                    searchControl
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
        // Search: capsule button that expands into text field.
        HStack(spacing: 5) {
            if isSearchExpanded {
                Image(systemName: "magnifyingglass")
                    .font(.cadenza(15, weight: .regular, scale: uiScale))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)

                TextField("Search", text: Binding(
                    get: { appState.searchQuery },
                    set: { appState.searchQuery = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.cadenza(12, scale: uiScale))
                .focused($isSearchFocused)
                .onExitCommand { collapseSearch() }
            } else {
                Button {
                    expandSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.cadenza(15, weight: .regular, scale: uiScale))
                        .foregroundStyle(isSearchHovered ? .primary : .secondary)
                        .frame(width: controlSize, height: controlSize)
                }
                .buttonStyle(.cadenzaPlain)
                .accessibilityLabel("Search")
            }
        }
        .frame(
            width: RecordingsTopBarLayoutMetrics.searchWidth(
                isExpanded: isSearchExpanded,
                scale: uiScale
            ),
            height: controlSize
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .cadenzaGlass(in: Capsule(), interactive: true)
        .contentShape(Rectangle())
        .onHover { isSearchHovered = $0 }
        .onChange(of: isSearchFocused) { _, focused in
            if !focused && isSearchExpanded && appState.searchQuery.isEmpty {
                collapseSearch()
            }
        }
    }

    private func expandSearch() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            isSearchExpanded = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isSearchFocused = true
        }
    }

    private func collapseSearch() {
        appState.searchQuery = ""
        isSearchFocused = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            isSearchExpanded = false
        }
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
