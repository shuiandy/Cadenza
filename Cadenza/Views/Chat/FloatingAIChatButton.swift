import SwiftUI

/// A floating pill button at bottom-trailing that opens the in-window AI chat sidebar.
///
/// The capsule lives in the main window's detail overlay (low-frequency, not a hang source).
/// Tapping it sets `AppState.floatingChatController.isExpanded`, which makes `MainWorkspaceView`
/// slide in `FloatingChatPanelRoot` as a right-side sidebar. See `FloatingChatPanel.swift`.
struct FloatingAIChatButton: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(AppState.self) private var appState

    var placeholder: String = String(localized: "Ask about your recordings...")
    var expandOnHover: Bool = false
    var isProminent: Bool = false

    private var controller: FloatingChatPanelController { appState.floatingChatController }

    var body: some View {
        collapsedPill
            // The capsule is removed when navigating to the full-page AI Assistant (MainWindow
            // hides it via `!isOnAIAssistantPage`). Collapse the sidebar so it doesn't linger.
            .onDisappear { controller.collapse() }
    }

    // MARK: - Collapsed Pill

    private var collapsedPill: some View {
        let iconSize: CGFloat = isProminent ? 15 : 12
        let textSize: CGFloat = isProminent ? 14 : 12
        let horizontalPadding: CGFloat = isProminent ? 20 : 14
        let verticalPadding: CGFloat = isProminent ? 11 : 8
        // Wrapped in a `Button` rather than relying on `.onTapGesture` on a
        // bare HStack: on macOS 26 the interactive cadenzaGlass branch
        // layer pairs with Button's press semantics and the codebase's
        // other interactive-glass surfaces all use this pattern.
        return Button {
            controller.expand(appState: appState)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.cadenza(iconSize, weight: .semibold, scale: uiScale))
                Text("AI Assistant")
                    .font(.cadenza(textSize, weight: .semibold, scale: uiScale))
            }
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
        .buttonStyle(.cadenzaPlain(in: Capsule()))
        .cadenzaGlass(in: .capsule, interactive: true)
        .onHover { hovering in
            if expandOnHover && hovering {
                controller.expand(appState: appState)
            }
        }
        // Hide the capsule while the panel is up (matches the old in-place expand swap).
        .opacity(controller.isExpanded ? 0 : 1)
        .allowsHitTesting(!controller.isExpanded)
        .animation(.easeOut(duration: 0.18), value: controller.isExpanded)
    }
}

/// The expanded AI chat content, shown as an in-window right-side sidebar (a `NavigationSplitView`
/// sibling in `MainWorkspaceView`, NOT a `ContentView` overlay) so its streaming-time re-layout
/// stays off the recordings grid's `overlayPreferenceValue` chain. Closing the sidebar unmounts
/// this view (local messages/input end); completed turns persist to `appState.chatHistory`.
struct FloatingChatPanelRoot: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    /// Owning controller — `collapse()` dismisses the panel (close button / Esc / full-page handoff).
    let controller: FloatingChatPanelController

    var placeholder: String = String(localized: "Ask about your recordings...")

    // Chat state
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var streamState = ChatStreamState()
    @State private var lastContextInfo: String?

    // Model selection
    @State private var selectedProvider = AIChatModelCatalog.configuredProvider()
    @State private var selectedModel: String = ""

    // @ mention
    @State private var showMentionPicker = false
    @State private var mentionFilter = ""
    @State private var mentionedRecordings: [RecordingDTO] = []
    /// Accumulated recording IDs mentioned across the entire session (not just current message).
    @State private var sessionScopeRecordingIDs: Set<UUID> = []

    // History
    @State private var currentSessionID: UUID?
    @State private var showHistory = false

    // All recordings for @ picking (when scoped to a single recording we still allow mentioning others)
    @Environment(AppState.self) private var appState
    private var allRecordings: [RecordingDTO] { appState.recordings }

    private var availableChatProviders: [AIProvider] {
        guard appState.startupPolicy.allowsContentGeneration else { return [] }
        var providers: [AIProvider] = []
        if AppleFoundationModelFactory.isAvailable {
            providers.append(.apple)
        }
        providers.append(contentsOf: AIProvider.allCases.filter { provider in
            provider.requiresAPIKey && provider.makeChatService(apiKey: "") != nil && KeychainManager.shared.hasAPIKey(for: provider)
        })
        return providers
    }

    private let assembler = AIContextAssembler()

    private var headerBrandSize: CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 28,
            symbolPointSize: 13,
            scale: uiScale,
            padding: 11
        )
    }

    private var headerControlSize: CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 28,
            symbolPointSize: 12,
            scale: uiScale,
            padding: 12
        )
    }

    private var messageIconSize: CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 18,
            symbolPointSize: 10,
            scale: uiScale,
            padding: 5
        )
    }

    private var mentionControlSize: CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 30,
            symbolPointSize: 13,
            scale: uiScale,
            padding: 13
        )
    }

    private var sendControlSize: CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 28,
            symbolPointSize: 13,
            scale: uiScale,
            padding: 11
        )
    }

    var body: some View {
        // In-window right-side sidebar: fixed width, fills available height. The show/hide
        // animation is the parent's `.transition(.move(edge:.trailing))` in MainWorkspaceView,
        // so there's no content-level scale/opacity here.
        expandedPanel
            .frame(width: 400)
            .frame(maxHeight: .infinity)
            .onAppear {
                initializeModel()
                syncSelectedProvider()
                autoMentionCurrentRecording(currentRecordingID)
            }
            .onChange(of: currentRecordingID) { _, newID in
                autoMentionCurrentRecording(newID)
            }
            // Cancels any in-flight stream when the sidebar leaves the tree.
            .onDisappear {
                stopStreaming(savePartial: false)
            }
            // Esc collapses the sidebar.
            .onExitCommand {
                controller.collapse()
            }
    }

    /// The recording ID from the current detail page, if any.
    private var currentRecordingID: UUID? {
        if case .recordingDetail(let id) = appState.activeDestination { return id }
        return nil
    }

    /// Describes current scope for UI display.
    private var scopeLabel: String {
        if !mentionedRecordings.isEmpty {
            return mentionedRecordings.count == 1 ? mentionedRecordings[0].title : String(localized: "\(mentionedRecordings.count) recordings")
        }
        if !sessionScopeRecordingIDs.isEmpty {
            if sessionScopeRecordingIDs.count == 1,
               let rec = allRecordings.first(where: { sessionScopeRecordingIDs.contains($0.id) }) {
                return rec.title
            }
            return String(localized: "\(sessionScopeRecordingIDs.count) recordings")
        }
        return String(localized: "All recordings")
    }

    /// Auto-add the current recording as a mention when navigating to its detail page.
    private func autoMentionCurrentRecording(_ recordingID: UUID?) {
        guard let recordingID else {
            if messages.isEmpty {
                mentionedRecordings.removeAll()
                sessionScopeRecordingIDs.removeAll()
            }
            return
        }
        guard !mentionedRecordings.contains(where: { $0.id == recordingID }) else { return }
        if let recording = allRecordings.first(where: { $0.id == recordingID }) {
            withAnimation(.easeOut(duration: 0.15)) {
                mentionedRecordings = [recording]
            }
            sessionScopeRecordingIDs.insert(recordingID)
        }
    }

    private func initializeModel() {
        if selectedModel.isEmpty {
            selectedModel = AIChatModelCatalog.configuredModel(for: selectedProvider)
        }
    }

    private func syncSelectedProvider() {
        guard !availableChatProviders.contains(selectedProvider),
              let fallback = AIChatModelCatalog.preferredAvailableProvider(
                  from: availableChatProviders
              ) else { return }
        selectedProvider = fallback
        selectedModel = AIChatModelCatalog.configuredModel(for: fallback)
    }

    // MARK: - Expanded Panel

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            panelHeader

            if messages.isEmpty && !streamState.isActive {
                suggestionsView
            } else {
                messagesArea
            }

            // Mention chips + input
            VStack(spacing: 0) {
                Divider().opacity(0.32)

                if !mentionedRecordings.isEmpty {
                    mentionChips
                }

                if showMentionPicker {
                    mentionPickerView
                }

                panelInputBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cadenzaGlass(in: RoundedRectangle(cornerRadius: AppStyle.Radius.panel))
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.panel))
    }

    // MARK: - Header

    private var panelHeader: some View {
        FloatingChatHeaderLayout {
            panelIdentity
        } actions: {
            panelHeaderActions
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var panelIdentity: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(AppStyle.ColorToken.controlFillActive)
                    .frame(width: headerBrandSize, height: headerBrandSize)
                Image(systemName: "sparkles")
                    .font(.cadenza(13, weight: .semibold, scale: uiScale))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("AI Assistant")
                    .font(.cadenza(14, weight: .semibold, scale: uiScale))
                    .lineLimit(1)
                Text(scopeLabel)
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var panelHeaderActions: some View {
        HStack(spacing: 10) {
            Button {
                showHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .frame(width: headerControlSize, height: headerControlSize)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.cadenzaPlain(in: Circle()))
            .help("Chat History")
            .popover(isPresented: $showHistory) {
                historyPopover
            }

            Button {
                expandToFullPage()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .frame(width: headerControlSize, height: headerControlSize)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.cadenzaPlain(in: Circle()))
            .help("Open in AI Assistant")
            // Disable while streaming — in-flight Task can't be transplanted, only completed messages can.
            .disabled(messages.isEmpty || streamState.isActive)

            Button {
                resetChat()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .frame(width: headerControlSize, height: headerControlSize)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.cadenzaPlain(in: Circle()))
            .help("New Chat")
            .disabled(messages.isEmpty && !streamState.isActive)

            Button {
                controller.collapse()
            } label: {
                Image(systemName: "xmark")
                    .font(.cadenza(12, weight: .bold, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .frame(width: headerControlSize, height: headerControlSize)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.cadenzaPlain(in: Circle()))
        }
    }

    // MARK: - History Popover

    private var historyPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat History")
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
                Spacer()
                if !appState.chatHistory.sessions.isEmpty {
                    Button("Clear All") {
                        appState.chatHistory.deleteAll()
                    }
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.red)
                    .buttonStyle(.cadenzaPlain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.3)

            if appState.chatHistory.sessions.isEmpty {
                Text("No chat history")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.chatHistory.sessions) { session in
                            Button {
                                restoreSession(session)
                                showHistory = false
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title)
                                            .font(.cadenza(12, weight: .medium, scale: uiScale))
                                            .lineLimit(1)
                                        HStack(spacing: 4) {
                                            Text(session.updatedAt.formatted(.relative(presentation: .named)))
                                                .font(.cadenza(10, scale: uiScale))
                                                .foregroundStyle(.tertiary)
                                            Text("\u{00B7}")
                                                .foregroundStyle(.quaternary)
                                            Text("\(session.messages.count) messages")
                                                .font(.cadenza(10, scale: uiScale))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()

                                    Button {
                                        appState.chatHistory.delete(id: session.id)
                                        if currentSessionID == session.id {
                                            currentSessionID = nil
                                        }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.cadenza(10, scale: uiScale))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.cadenzaPlain)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(SuggestionButtonStyle())
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 280)
    }

    private func restoreSession(_ session: ChatSession) {
        stopStreaming(savePartial: false)
        saveCurrentSessionIfNeeded()
        messages = session.messages
        currentSessionID = session.id
        let restoredProviderIsAvailable: Bool
        if let provider = AIProvider(rawValue: session.provider) {
            selectedProvider = provider
            selectedModel = session.model
            restoredProviderIsAvailable = availableChatProviders.contains(provider)
        } else {
            // Legacy provider (e.g. removed qwenLocal). Migrate to .apple to match the
            // startup-time UserDefaults migration; syncSelectedProvider() handles
            // availability fallback if Apple FM isn't on this machine.
            selectedProvider = .apple
            selectedModel = AIChatModelCatalog.configuredModel(for: .apple)
            restoredProviderIsAvailable = false
        }
        syncSelectedProvider()
        if restoredProviderIsAvailable {
            AIChatModelCatalog.persist(provider: selectedProvider)
            AIChatModelCatalog.persist(modelID: selectedModel, for: selectedProvider)
        }
        inputText = ""
        mentionedRecordings = []
        sessionScopeRecordingIDs = []
        showMentionPicker = false
        mentionFilter = ""
    }

    private var modelMenu: some View {
        AIChatModelMenu(
            availableProviders: availableChatProviders,
            selectedProvider: $selectedProvider,
            selectedModel: $selectedModel,
            labelKind: .providerIcon(iconSize: 16, frameSize: 30, cornerRadius: 8)
        )
        .help("Choose model")
    }

    // MARK: - Suggestions

    private var suggestionsView: some View {
        // `bubble.left.and.bubble.right` is 24pt wide at a nominal 14pt
        // font and 71pt wide at Cadenza's supported 3.105x maximum.
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 24,
            symbolPointSize: 18,
            scale: uiScale,
            padding: 0
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Suggestions")
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                ForEach(suggestedQuestions, id: \.text) { q in
                    Button {
                        startStreamingMessage(q.text)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: q.icon)
                                .font(.cadenza(14, scale: uiScale))
                                .foregroundStyle(.secondary)
                                .frame(width: iconSize, height: iconSize)
                            Text(q.text)
                                .font(.cadenza(15, scale: uiScale))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.cadenza(9, weight: .semibold, scale: uiScale))
                                .foregroundStyle(.quaternary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SuggestionButtonStyle())
                    .disabled(!appState.startupPolicy.allowsContentGeneration)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var suggestedQuestions: [(icon: String, text: String)] {
        if allRecordings.count == 1 {
            return [
                ("list.bullet", String(localized: "What are the key takeaways?")),
                ("checkmark.circle", String(localized: "List the action items")),
                ("arrow.triangle.branch", String(localized: "What decisions were made?")),
                ("text.magnifyingglass", String(localized: "Summarize in 3 sentences"))
            ]
        } else {
            return [
                ("checkmark.circle", String(localized: "Action items from my last meeting")),
                ("text.magnifyingglass", String(localized: "Summarize key decisions this week")),
                ("bubble.left.and.bubble.right", String(localized: "Which meetings discussed a topic?")),
                ("arrow.uturn.forward", String(localized: "What follow-ups are pending?"))
            ]
        }
    }

    // MARK: - Messages

    private var messagesArea: some View {
        // ZERO-FEEDBACK scroll design. Nine hangs (2026-06-11/12) traced to the
        // hand-rolled trio of ScrollViewReader.scrollTo + onScrollGeometryChange
        // + a pinned-to-bottom @State: every member both OBSERVES layout and
        // MUTATES it, so each fix surfaced the next oscillation. This panel now
        // uses the system's declarative bottom anchor: content growth keeps the
        // view pinned, user scroll-away releases it, scrolling back re-engages —
        // all inside AppKit's scroll machinery, with no state writes and no
        // imperative scrolls for layout to feed back into. (The full-page
        // assistant never hung and keeps its richer jump-button UX.)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(messages) { message in
                    compactBubble(message)
                        .id(message.id)
                }
                ChatStreamingSection(
                    streamState: streamState,
                    contextInfo: lastContextInfo,
                    uiScale: uiScale
                )
            }
            .padding(12)
        }
        .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder
    private func compactBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if message.role == .user { Spacer(minLength: 50) }

            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.cadenza(10, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .frame(width: messageIconSize, height: messageIconSize)
                    .padding(.top, 3)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
                Group {
                    if message.role == .assistant {
                        MarkdownMessageView(message.content, fontSize: 14, uiScale: uiScale, compact: true)
                    } else {
                        Text(message.content)
                            .font(.cadenza(14, scale: uiScale))
                    }
                }
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: AppStyle.Radius.bubble)
                            .fill(message.role == .user
                                  ? Color.accentColor.opacity(0.85)
                                  : AppStyle.ColorToken.assistantBubble)
                    )
                    .foregroundStyle(message.role == .user ? .white : .primary)

                if !message.mentionedRecordingIDs.isEmpty {
                    let names = message.mentionedRecordingIDs.compactMap { id in
                        allRecordings.first { $0.id == id }?.title
                    }
                    if !names.isEmpty {
                        Text(names.map { "@\($0)" }.joined(separator: " "))
                            .font(.cadenza(10, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
            }

            if message.role == .assistant { Spacer(minLength: 50) }
        }
    }

    // MARK: - @ Mention Chips

    private var mentionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(mentionedRecordings, id: \.id) { recording in
                    HStack(spacing: 4) {
                        Text("@\(recording.title)")
                            .font(.cadenza(11, weight: .medium, scale: uiScale))
                            .lineLimit(1)
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                mentionedRecordings.removeAll { $0.id == recording.id }
                                sessionScopeRecordingIDs.remove(recording.id)
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.cadenza(8, weight: .bold, scale: uiScale))
                        }
                        .buttonStyle(.cadenzaPlain)
                    }
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(AppStyle.ColorToken.chipFill)
                    )
                    .overlay(Capsule().strokeBorder(AppStyle.ColorToken.chipBorder, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    // MARK: - @ Mention Picker

    private var mentionPickerView: some View {
        let filtered = allRecordings.filter { rec in
            !mentionedRecordings.contains(where: { $0.id == rec.id })
            && (mentionFilter.isEmpty || rec.title.localizedCaseInsensitiveContains(mentionFilter))
        }

        return VStack(spacing: 0) {
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered.prefix(6)) { recording in
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                mentionedRecordings.append(recording)
                                // Remove @filter from input
                                removeAtToken()
                                showMentionPicker = false
                                mentionFilter = ""
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "waveform.circle")
                                    .font(.cadenza(12, scale: uiScale))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(recording.title)
                                        .font(.cadenza(12, weight: .medium, scale: uiScale))
                                        .lineLimit(1)
                                    Text(recording.startDate.formatted(date: .abbreviated, time: .omitted))
                                        .font(.cadenza(10, scale: uiScale))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SuggestionButtonStyle())
                    }

                    if filtered.isEmpty {
                        Text("No recordings found")
                            .font(.cadenza(12, scale: uiScale))
                            .foregroundStyle(.tertiary)
                            .padding(10)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    private func removeAtToken() {
        // Remove the last @... token from input
        if let atRange = inputText.range(of: "@", options: .backwards) {
            inputText = String(inputText[inputText.startIndex..<atRange.lowerBound])
        }
    }

    // MARK: - Input Bar

    private var panelInputBar: some View {
        Group {
            if uiScale >= CadenzaTextScale.factor(.accessibility1) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        mentionButton
                        modelMenu
                    }
                    composerField
                }
            } else {
                HStack(spacing: 8) {
                    mentionButton
                    modelMenu
                    composerField
                }
            }
        }
        .padding(8)
        .cadenzaGlass(in: RoundedRectangle(cornerRadius: AppStyle.Radius.card + 1, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var mentionButton: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    showMentionPicker.toggle()
                    if showMentionPicker {
                        mentionFilter = ""
                    }
                }
            } label: {
                Image(systemName: "at")
                    .font(.cadenza(13, weight: .medium, scale: uiScale))
                    .foregroundStyle(showMentionPicker ? Color.accentColor : .primary.opacity(0.7))
                    .frame(width: mentionControlSize, height: mentionControlSize)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(showMentionPicker ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                showMentionPicker ? Color.accentColor.opacity(0.32) : AppStyle.ColorToken.stroke,
                                lineWidth: 0.5
                            )
                    )
            }
            .buttonStyle(.cadenzaPlain(in: RoundedRectangle(cornerRadius: 8)))
            .help("Mention a recording")
        }
    }

    private var composerField: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $inputText)
                .font(.cadenza(14, weight: .medium, scale: uiScale))
                .textFieldStyle(.plain)
                .onSubmit(submitInput)
                .disabled(streamState.isActive || !appState.startupPolicy.allowsContentGeneration)
                .onChange(of: inputText) { _, newValue in
                    handleInputChange(newValue)
                }

            if streamState.isActive {
                Button {
                    stopStreaming(savePartial: true)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.cadenza(12, weight: .bold, scale: uiScale))
                        .foregroundStyle(.white)
                        .frame(width: sendControlSize, height: sendControlSize)
                        .background(Circle().fill(Color.secondary.opacity(0.75)))
                }
                .buttonStyle(.cadenzaPlain)
                .help("Stop response")
            } else if appState.startupPolicy.allowsContentGeneration
                        && (!inputText.trimmingCharacters(in: .whitespaces).isEmpty
                            || !mentionedRecordings.isEmpty) {
                Button(action: submitInput) {
                    Image(systemName: "arrow.up")
                        .font(.cadenza(13, weight: .bold, scale: uiScale))
                        .foregroundStyle(.white)
                        .frame(width: sendControlSize, height: sendControlSize)
                        .background(Circle().fill(Color.accentColor.opacity(0.85)))
                }
                .buttonStyle(.cadenzaPlain)
                .disabled(streamState.isActive || !appState.startupPolicy.allowsContentGeneration)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cadenzaGlass(in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous))
    }

    private func handleInputChange(_ text: String) {
        // Detect @-trigger
        if let atIdx = text.lastIndex(of: "@") {
            let after = String(text[text.index(after: atIdx)...])
            // Show picker if @ is at end or has a partial filter (no space after @)
            if !after.contains(" ") {
                mentionFilter = after
                if !showMentionPicker {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showMentionPicker = true
                    }
                }
                return
            }
        }
        if showMentionPicker && !text.contains("@") {
            withAnimation(.easeOut(duration: 0.15)) {
                showMentionPicker = false
                mentionFilter = ""
            }
        }
    }

    private func submitInput() {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard (text.isEmpty == false || !mentionedRecordings.isEmpty), !streamState.isActive else { return }
        let query = text.isEmpty ? "Tell me about the mentioned recording(s)" : text
        inputText = ""
        showMentionPicker = false
        mentionFilter = ""
        let mentioned = mentionedRecordings
        mentionedRecordings = []
        startStreamingMessage(query, mentioning: mentioned)
    }

    private func resetChat() {
        stopStreaming(savePartial: false)
        saveCurrentSessionIfNeeded()
        messages = []
        currentSessionID = nil
        sessionScopeRecordingIDs = []
        inputText = ""
        mentionedRecordings = []
        showMentionPicker = false
        mentionFilter = ""
    }

    /// Hand the in-progress chat off to the full-page AI Assistant and reset local state.
    private func expandToFullPage() {
        stopStreaming(savePartial: false)
        saveCurrentSessionIfNeeded()
        appState.aiChatMessages = messages
        appState.aiChatScopeIDs = sessionScopeRecordingIDs
        appState.aiChatHandoff = AIChatHandoff(
            provider: selectedProvider,
            model: selectedModel,
            sessionID: currentSessionID
        )
        // present 而非 navigate：全页助手是从当前页展开的，关掉要能回到原地。
        appState.present(.aiAssistant())

        // Dismiss the floating panel; the full-page assistant now owns the conversation.
        controller.collapse()

        // Local state was migrated; start fresh next time the panel opens.
        messages = []
        currentSessionID = nil
        sessionScopeRecordingIDs = []
        inputText = ""
        mentionedRecordings = []
        showMentionPicker = false
        mentionFilter = ""
    }

    // MARK: - Session Persistence

    private func saveCurrentSessionIfNeeded() {
        guard !messages.isEmpty else { return }
        let title = messages.first(where: { $0.role == .user })?.content.prefix(50).description ?? "Chat"
        let id = currentSessionID ?? UUID()
        var session = ChatSession(
            id: id,
            title: title,
            messages: messages,
            provider: selectedProvider.rawValue,
            model: selectedModel
        )
        if let existing = appState.chatHistory.load(id: id) {
            session = ChatSession(
                id: existing.id,
                title: title,
                messages: messages,
                provider: selectedProvider.rawValue,
                model: selectedModel
            )
        }
        session.updatedAt = Date()
        appState.chatHistory.save(session)
        currentSessionID = id
    }

    // MARK: - AI Integration

    private func startStreamingMessage(_ text: String, mentioning: [RecordingDTO] = []) {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        guard !streamState.isActive else { return }
        streamState.run { await sendMessage(text, mentioning: mentioning) }
    }

    private func stopStreaming(savePartial: Bool) {
        streamState.stop(savePartial: savePartial)
    }

    private func sendMessage(_ text: String, mentioning: [RecordingDTO] = []) async {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        var msg = ChatMessage(role: .user, content: text)
        msg.mentionedRecordingIDs = mentioning.map(\.id)
        messages.append(msg)

        guard let (service, modelID) = resolveAIService() else {
            messages.append(ChatMessage(
                role: .assistant,
                content: String(
                    localized: "No AI provider configured. Please add an API key in Settings."
                )
            ))
            saveCurrentSessionIfNeeded()
            return
        }

        guard let store = appState.store else {
            messages.append(ChatMessage(
                role: .assistant,
                content: String(localized: "Database not available.")
            ))
            return
        }

        // Accumulate this message's mentions into session scope
        for id in mentioning.map(\.id) {
            sessionScopeRecordingIDs.insert(id)
        }

        let packet = await assembler.buildContext(
            question: text,
            history: Array(messages.dropLast()),
            mentionedRecordingIDs: Array(sessionScopeRecordingIDs),
            provider: selectedProvider,
            store: store
        )

        if let index = messages.firstIndex(where: { $0.id == msg.id }) {
            messages[index].contextRecordingIDs = packet.resolvedRecordingIDs
        }

        if Task.isCancelled { return }

        // Update context info for UI
        lastContextInfo = AIContextAssembler.formatContextInfo(packet.metadata)

        let stream = service.streamChat(
            systemPrompt: packet.systemPrompt,
            history: packet.messages,
            model: modelID
        )

        do {
            let response = try await streamState.collect(stream)
            messages.append(ChatMessage(role: .assistant, content: response))
        } catch is CancellationError {
            let partial = streamState.currentPartialText()
            if streamState.savePartialOnCancel && !partial.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: partial))
            }
        } catch {
            let partial = streamState.currentPartialText()
            let content = partial.isEmpty
                ? String(localized: "AI response failed: \(error.localizedDescription)")
                : partial
            messages.append(ChatMessage(role: .assistant, content: content))
        }

        saveCurrentSessionIfNeeded()
    }

    private func resolveAIService() -> (AIServiceProtocol, String)? {
        guard appState.startupPolicy.allowsContentGeneration else { return nil }
        let apiKey: String
        if selectedProvider.requiresAPIKey {
            guard let key = KeychainManager.shared.apiKey(for: selectedProvider), !key.isEmpty else { return nil }
            apiKey = key
        } else {
            apiKey = ""
        }
        guard let service = selectedProvider.makeChatService(apiKey: apiKey) else { return nil }
        return (service, selectedModel)
    }

    // MARK: - Helpers

}

// MARK: - Accessibility Layout

/// Keeps the fixed-width floating sidebar usable when Cadenza's text scale
/// makes the identity and four header controls wider than a single 400pt row.
struct FloatingChatHeaderLayout<Identity: View, Actions: View>: View {
    let identity: Identity
    let actions: Actions

    init(
        @ViewBuilder identity: () -> Identity,
        @ViewBuilder actions: () -> Actions
    ) {
        self.identity = identity()
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                identity
                Spacer(minLength: 8)
                actions
            }

            VStack(alignment: .leading, spacing: 10) {
                identity
                HStack {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
    }
}

// MARK: - Suggestion Button Style

private struct SuggestionButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? AppStyle.ColorToken.softFill : .clear)
            )
            .onHover { isHovered = $0 }
    }
}

// MARK: - Streaming Isolation Boundary

/// The ONLY view in the floating panel that reads `streamState`'s per-tick
/// observable state (`isActive` / `snapshot` / `hasVisibleContent`) and the
/// scroll signal (`renderRevision`). Fencing those reads in this small struct
/// keeps every streaming tick from re-evaluating the messages list body:
/// history bubbles keep stable identity, SwiftUI's size caches stay valid,
/// and long flattened history Texts are never re-typeset mid-stream — the
/// 2026-06-12 sixth hang sampled exactly that (full-list ChatMessage diffing
/// plus TextKit re-typesetting at snapshot cadence).
private struct ChatStreamingSection: View {
    let streamState: ChatStreamState
    let contextInfo: String?
    let uiScale: CGFloat

    var body: some View {
        Group {
            if streamState.isActive {
                if let contextInfo {
                    Text(contextInfo)
                        .font(.cadenza(10, scale: uiScale))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
                bubble
                    .id("streaming")
            }
        }
    }

    private var bubble: some View {
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 18,
            symbolPointSize: 10,
            scale: uiScale,
            padding: 5
        )
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.cadenza(10, scale: uiScale))
                .foregroundStyle(.secondary)
                .frame(width: iconSize, height: iconSize)
                .padding(.top, 3)

            if !streamState.hasVisibleContent {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(.secondary.opacity(0.4))
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: AppStyle.Radius.bubble)
                        .fill(AppStyle.ColorToken.assistantBubble)
                )
            } else {
                StreamingMarkdownMessageView(snapshot: streamState.snapshot, fontSize: 14, uiScale: uiScale, compact: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: AppStyle.Radius.bubble)
                            .fill(AppStyle.ColorToken.assistantBubble)
                    )
            }

            Spacer(minLength: 50)
        }
    }
}
