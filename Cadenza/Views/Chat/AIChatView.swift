import SwiftUI

struct AIChatView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let initialQuery: String?

    @Environment(AppState.self) private var appState

    @State private var inputText = ""
    @State private var streamState = ChatStreamState()
    @State private var lastContextInfo: String?
    @State private var hasSentInitialQuery = false
    @State private var followUpSuggestions: [String] = []

    private let assembler = AIContextAssembler()
    private let messageColumnMaxWidth: CGFloat = 1_120
    private let userBubbleMaxWidth: CGFloat = 720

    @State private var selectedProvider = AIChatModelCatalog.configuredProvider()
    @State private var selectedModel: String = ""

    // History
    @State private var currentSessionID: UUID?
    @State private var showHistory = false

    private var messages: [ChatMessage] {
        appState.aiChatMessages
    }

    private var recordingsCount: Int {
        appState.recordings.count
    }

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

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.bottom, 10)

            if let label = scopeLabel {
                scopeBanner(label)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            if messages.isEmpty && !streamState.isActive {
                placeholderView
            } else {
                messagesView
            }

            if !followUpSuggestions.isEmpty && !streamState.isActive {
                followUpView
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .bottom)),
                        removal: .opacity
                    ))
            }

            inputBar
        }
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.35, bounce: 0.22), value: followUpSuggestions)
        .onAppear {
            // Adopt a one-shot handoff from FloatingAIChatButton, if any.
            if let handoff = appState.aiChatHandoff {
                selectedProvider = handoff.provider
                selectedModel = handoff.model
                currentSessionID = handoff.sessionID
                appState.aiChatHandoff = nil
            }
            if selectedModel.isEmpty {
                selectedModel = AIChatModelCatalog.configuredModel(for: selectedProvider)
            }
            syncSelectedProvider()
        }
        .task(id: initialQuery) {
            guard appState.startupPolicy.allowsContentGeneration else { return }
            guard let query = initialQuery, !query.isEmpty, !hasSentInitialQuery else { return }
            hasSentInitialQuery = true
            startStreamingMessage(query)
        }
        .onDisappear {
            stopStreaming(savePartial: false)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 10)

            topBarButton("plus", help: "New Chat") {
                stopStreaming(savePartial: false)
                saveCurrentSessionIfNeeded()
                appState.aiChatMessages.removeAll()
                appState.aiChatScopeIDs.removeAll()
                currentSessionID = nil
                followUpSuggestions.removeAll()
            }
            .disabled(messages.isEmpty && !streamState.isActive)

            topBarButton("clock.arrow.circlepath", help: "History") {
                showHistory.toggle()
            }
            .popover(isPresented: $showHistory) {
                chatHistoryPopover
            }
        }
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Scope Banner

    private var scopeLabel: String? {
        let ids = appState.aiChatScopeIDs
        guard !ids.isEmpty else { return nil }
        if ids.count == 1, let rec = appState.recordings.first(where: { ids.contains($0.id) }) {
            return rec.title
        }
        if ids.count == 1 {
            return String(localized: "1 recording")
        }
        return String(localized: "\(ids.count) recordings")
    }

    private func scopeBanner(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "at")
                .font(.cadenza(10, weight: .semibold, scale: uiScale))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.cadenza(11, scale: uiScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                appState.aiChatScopeIDs.removeAll()
            } label: {
                Image(systemName: "xmark")
                    .font(.cadenza(9, weight: .bold, scale: uiScale))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.cadenzaPlain)
            .help("Clear scope")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .cadenzaGlass(in: Capsule())
    }

    private func topBarButton(
        _ icon: String,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.cadenza(11, weight: .semibold, scale: uiScale))
                Text(help)
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.cadenzaPlain)
        .cadenzaGlass(in: Capsule(), interactive: true)
        .accessibilityLabel(Text(help))
        .help(Text(help))
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.cadenza(26, scale: uiScale))
                        .foregroundStyle(Color.accentColor.opacity(0.75))

                    Text("Ask your \(recordingsCount) recordings")
                        .font(.cadenza(18, weight: .bold, scale: uiScale))

                    Text("Ask across meetings, find decisions, track follow-ups")
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 14)

                suggestionCardsGrid

                if !appState.chatHistory.sessions.isEmpty {
                    recentChatsSection
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Suggestion Scenario Cards

    private var suggestionCardsGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 10),
                count: usesAccessibleLayout ? 1 : 2
            ),
            spacing: 10
        ) {
            ForEach(suggestedQuestions, id: \.title) { scenario in
                Button {
                    startStreamingMessage(scenario.title)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: scenario.icon)
                            .font(.cadenza(13, weight: .semibold, scale: uiScale))
                            .foregroundStyle(scenario.tint)
                            .frame(width: 30, height: 30)
                            .background(
                                scenario.tint.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 1) {
                            Text(scenario.title)
                                .font(.cadenza(13, weight: .semibold, scale: uiScale))
                            Text(scenario.subtitle)
                                .font(.cadenza(11, scale: uiScale))
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.leading)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.cadenzaPlain)
                .disabled(!appState.startupPolicy.allowsContentGeneration)
                .cadenzaGlass(
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                    interactive: true
                )
            }
        }
    }

    // MARK: - Recent Chats Section

    private var recentChatsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent Chats")
                    .font(.cadenza(12, weight: .bold, scale: uiScale))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showHistory = true
                } label: {
                    Text("See All")
                        .font(.cadenza(11, weight: .semibold, scale: uiScale))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.cadenzaPlain)
                .popover(isPresented: $showHistory) {
                    chatHistoryPopover
                }
            }

            ForEach(recentChatSessions) { session in
                Button {
                    restoreSession(session)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "bubble.left")
                            .font(.cadenza(12, scale: uiScale))
                            .foregroundStyle(.tertiary)

                        if usesAccessibleLayout {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                    .font(.cadenza(13, weight: .medium, scale: uiScale))
                                    .lineLimit(2)
                                sessionMetaLine(session)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(session.title)
                                .font(.cadenza(13, weight: .medium, scale: uiScale))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            sessionMetaLine(session)
                                .fixedSize()
                        }

                        Image(systemName: "chevron.right")
                            .font(.cadenza(10, weight: .medium, scale: uiScale))
                            .foregroundStyle(.quaternary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.cadenzaPlain)
                .cadenzaGlass(
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                    interactive: true
                )
            }
        }
    }

    /// Retrying the same question leaves near-identical sessions back to back;
    /// the shortlist keeps only the most recent session per title. The full
    /// history popover still lists every session.
    private var recentChatSessions: [ChatSession] {
        var seenTitles = Set<String>()
        var result: [ChatSession] = []
        for session in appState.chatHistory.sessions {
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seenTitles.insert(title).inserted else { continue }
            result.append(session)
            if result.count == 5 { break }
        }
        return result
    }

    private func sessionMetaLine(_ session: ChatSession) -> some View {
        HStack(spacing: 4) {
            Text(session.updatedAt.formatted(.relative(presentation: .named)))
                .font(.cadenza(10.5, scale: uiScale))
                .foregroundStyle(.tertiary)
            Text("\u{00B7}")
                .foregroundStyle(.quaternary)
            Text("\(session.messages.count) messages")
                .font(.cadenza(10.5, scale: uiScale))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - History Popover

    private var chatHistoryPopover: some View {
        VStack(spacing: 0) {
            AIChatHistoryHeaderLayout {
                Text("Chat History")
                    .font(.cadenza(13, weight: .semibold, scale: uiScale))
            } actions: {
                if !appState.chatHistory.sessions.isEmpty {
                    Button("Clear All") {
                        appState.chatHistory.deleteAll()
                        if currentSessionID != nil {
                            currentSessionID = nil
                        }
                    }
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.red)
                    .buttonStyle(.cadenzaPlain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.3)

            if appState.chatHistory.sessions.isEmpty {
                Text("No chat history")
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.chatHistory.sessions) { session in
                            Button {
                                restoreSession(session)
                                showHistory = false
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title)
                                            .font(.cadenza(13, weight: .medium, scale: uiScale))
                                            .lineLimit(usesAccessibleLayout ? nil : 1)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if usesAccessibleLayout {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(session.updatedAt.formatted(.relative(presentation: .named)))
                                                    .font(.cadenza(11, scale: uiScale))
                                                    .foregroundStyle(.tertiary)
                                                Text("\(session.messages.count) messages")
                                                    .font(.cadenza(11, scale: uiScale))
                                                    .foregroundStyle(.tertiary)
                                            }
                                        } else {
                                            HStack(spacing: 4) {
                                            Text(session.updatedAt.formatted(.relative(presentation: .named)))
                                                .font(.cadenza(11, scale: uiScale))
                                                .foregroundStyle(.tertiary)
                                            Text("\u{00B7}")
                                                .foregroundStyle(.quaternary)
                                            Text("\(session.messages.count) messages")
                                                .font(.cadenza(11, scale: uiScale))
                                                .foregroundStyle(.tertiary)
                                            }
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
                                            .font(.cadenza(11, scale: uiScale))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.cadenzaPlain)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.cadenzaPlain)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: usesAccessibleLayout ? 640 : 320)
    }

    private func restoreSession(_ session: ChatSession) {
        stopStreaming(savePartial: false)
        saveCurrentSessionIfNeeded()
        appState.aiChatMessages = session.messages
        // Restored sessions don't carry scope; treat as global.
        appState.aiChatScopeIDs.removeAll()
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
        followUpSuggestions.removeAll()
    }

    private struct SuggestedScenario {
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
    }

    private var suggestedQuestions: [SuggestedScenario] {
        [
            SuggestedScenario(
                icon: "checklist",
                tint: .blue,
                title: String(localized: "Action items from my last meeting"),
                subtitle: String(localized: "Pull action items from your most recent meeting")
            ),
            SuggestedScenario(
                icon: "checkmark.seal",
                tint: .green,
                title: String(localized: "Key decisions this week"),
                subtitle: String(localized: "Roll up what got decided in the last 7 days")
            ),
            SuggestedScenario(
                icon: "magnifyingglass",
                tint: .purple,
                title: String(localized: "Find meetings by topic"),
                subtitle: String(localized: "Search every transcript by theme")
            ),
            SuggestedScenario(
                icon: "tray.and.arrow.down",
                tint: .orange,
                title: String(localized: "Open follow-ups"),
                subtitle: String(localized: "Commitments that never closed out")
            )
        ]
    }

    // MARK: - Messages

    private var messagesView: some View {
        // Zero-feedback scroll design: no ScrollViewReader.scrollTo and no
        // onScrollGeometryChange state writes. Live samples showed that pair
        // can self-sustain LazyVStack layout work during streaming.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(messages) { message in
                    messageBubble(message)
                        .id(message.id)
                }

                // Isolation boundary: per-tick streamState reads live inside
                // FullPageStreamingSection so a streaming tick never re-evaluates
                // this list body (stable history identity -> hot size caches; see
                // the 2026-06-12 hang postmortem in ARCHITECTURE.md §12.2).
                FullPageStreamingSection(
                    streamState: streamState,
                    contextInfo: lastContextInfo,
                    uiScale: uiScale,
                    messageColumnMaxWidth: messageColumnMaxWidth
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .assistant:
            assistantMessage(message.content)
        case .user:
            userMessage(message.content)
        }
    }

    private func assistantMessage(_ content: String) -> some View {
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 22,
            symbolPointSize: 14,
            scale: uiScale,
            padding: 3
        )
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.cadenza(14, scale: uiScale))
                .foregroundStyle(.secondary)
                .frame(width: iconSize, height: iconSize)
                .padding(.top, 1)

            MarkdownMessageView(content, fontSize: 15, uiScale: uiScale)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: messageColumnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func userMessage(_ content: String) -> some View {
        HStack {
            Spacer(minLength: 80)

            Text(content)
                .font(.cadenza(16, scale: uiScale))
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: userBubbleMaxWidth, alignment: .leading)
                .background(
                    Color.accentColor.opacity(0.24),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.7)
                )
        }
        .frame(maxWidth: messageColumnMaxWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Follow-up Suggestions

    private var followUpView: some View {
        AIChatSuggestionLayout(stacked: usesAccessibleLayout, spacing: 8) {
            ForEach(followUpSuggestions, id: \.self) { suggestion in
                Button {
                    followUpSuggestions.removeAll()
                    startStreamingMessage(suggestion)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.cadenza(11, weight: .medium, scale: uiScale))
                            .foregroundStyle(.tertiary)
                        Text(suggestion)
                            .font(.cadenza(13, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(usesAccessibleLayout ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cadenzaGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.cadenzaPlain)
                .disabled(!appState.startupPolicy.allowsContentGeneration)
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Ask about your recordings...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.cadenza(15, weight: .medium, scale: uiScale))
                .lineLimit(1...6)
                .onSubmit(submitInput)
                .disabled(streamState.isActive || !appState.startupPolicy.allowsContentGeneration)
                .frame(minHeight: 44, alignment: .topLeading)
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                modelMenu
                    .font(.cadenza(11.5, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 24)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                Spacer()

                if streamState.isActive {
                    Button {
                        stopStreaming(savePartial: true)
                    } label: {
                        sendCircle(icon: "stop.fill", active: true)
                    }
                    .buttonStyle(.cadenzaPlain)
                    .help("Stop response")
                } else {
                    Button {
                        submitInput()
                    } label: {
                        sendCircle(icon: "arrow.up", active: canSend)
                    }
                    .buttonStyle(.cadenzaPlain)
                    .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .cadenzaGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
    }

    private func sendCircle(icon: String, active: Bool) -> some View {
        Image(systemName: icon)
            .font(.cadenza(12, weight: .bold, scale: uiScale))
            .foregroundStyle(active ? Color.white : Color.secondary)
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(active ? Color.accentColor : Color.primary.opacity(0.1))
            )
            .contentShape(Circle())
    }

    private var canSend: Bool {
        appState.startupPolicy.allowsContentGeneration
            && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !streamState.isActive
    }

    private var modelMenu: some View {
        AIChatModelMenu(
            availableProviders: availableChatProviders,
            selectedProvider: $selectedProvider,
            selectedModel: $selectedModel,
            labelKind: .title
        )
    }

    private func syncSelectedProvider() {
        guard !availableChatProviders.contains(selectedProvider),
              let fallback = AIChatModelCatalog.preferredAvailableProvider(
                  from: availableChatProviders
              ) else { return }
        selectedProvider = fallback
        selectedModel = AIChatModelCatalog.configuredModel(for: fallback)
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
        session.updatedAt = Date()
        appState.chatHistory.save(session)
        currentSessionID = id
    }

    // MARK: - AI Integration

    private func submitInput() {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streamState.isActive else { return }
        inputText = ""
        followUpSuggestions.removeAll()
        startStreamingMessage(text)
    }

    private func startStreamingMessage(_ text: String) {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        guard !streamState.isActive else { return }
        streamState.run { await sendMessage(text) }
    }

    private func stopStreaming(savePartial: Bool) {
        streamState.stop(savePartial: savePartial)
    }

    private func sendMessage(_ text: String) async {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        let userMessage = ChatMessage(role: .user, content: text)
        appState.aiChatMessages.append(userMessage)

        guard let (service, modelID) = resolveAIService() else {
            appState.aiChatMessages.append(ChatMessage(
                role: .assistant,
                content: String(
                    localized: "No AI provider configured. Add an API key in Settings."
                )
            ))
            saveCurrentSessionIfNeeded()
            return
        }

        guard let store = appState.store else {
            appState.aiChatMessages.append(ChatMessage(
                role: .assistant,
                content: String(localized: "Database not available.")
            ))
            return
        }

        let packet = await assembler.buildContext(
            question: text,
            history: Array(messages.dropLast()),
            mentionedRecordingIDs: Array(appState.aiChatScopeIDs),
            provider: selectedProvider,
            store: store
        )

        if let index = appState.aiChatMessages.firstIndex(where: { $0.id == userMessage.id }) {
            appState.aiChatMessages[index].contextRecordingIDs = packet.resolvedRecordingIDs
        }

        if Task.isCancelled { return }

        lastContextInfo = AIContextAssembler.formatContextInfo(packet.metadata)

        let stream = service.streamChat(
            systemPrompt: packet.systemPrompt,
            history: packet.messages,
            model: modelID
        )

        do {
            let response = try await streamState.collect(stream)
            appState.aiChatMessages.append(ChatMessage(role: .assistant, content: response))
        } catch is CancellationError {
            let partial = streamState.currentPartialText()
            if streamState.savePartialOnCancel && !partial.isEmpty {
                appState.aiChatMessages.append(ChatMessage(role: .assistant, content: partial))
            }
        } catch {
            let partial = streamState.currentPartialText()
            let content = partial.isEmpty
                ? String(localized: "AI response failed: \(error.localizedDescription)")
                : partial
            appState.aiChatMessages.append(ChatMessage(role: .assistant, content: content))
        }

        saveCurrentSessionIfNeeded()
        if !Task.isCancelled {
            generateFollowUps()
        }
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

    // MARK: - Follow-up Generation

    private func generateFollowUps() {
        guard let lastAssistant = messages.last, lastAssistant.role == .assistant else { return }
        let lastUser = messages.last(where: { $0.role == .user })

        let content = lastAssistant.content.lowercased()
        let question = lastUser?.content.lowercased() ?? ""

        var suggestions: [String] = []

        if content.contains("action item") || question.contains("action item") {
            suggestions.append(String(localized: "Who is responsible for each action item?"))
            suggestions.append(String(localized: "What are the deadlines for these action items?"))
        } else if content.contains("decision") || question.contains("decision") {
            suggestions.append(String(localized: "What context led to these decisions?"))
            suggestions.append(String(localized: "Were there any objections or alternatives discussed?"))
        } else if content.contains("summary") || content.contains("summarize") || question.contains("summarize") {
            suggestions.append(String(localized: "What were the key action items?"))
            suggestions.append(String(localized: "Were there any unresolved issues?"))
        } else if content.contains("follow-up") || content.contains("follow up") || question.contains("follow") {
            suggestions.append(String(localized: "Which follow-ups are most urgent?"))
            suggestions.append(String(localized: "Who owns each follow-up?"))
        } else {
            suggestions.append(String(localized: "Can you go into more detail?"))
            suggestions.append(String(localized: "What action items came from this?"))
        }

        if recordingsCount > 1 {
            suggestions.append(String(localized: "Compare this with other recent meetings"))
        }

        withAnimation(.easeOut(duration: 0.25)) {
            followUpSuggestions = Array(suggestions.prefix(3))
        }
    }

    private var usesAccessibleLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
            || uiScale >= CadenzaTextScale.factor(.accessibility1)
    }

}

// MARK: - Adaptive Chat Layouts

/// Preserves the compact horizontal suggestion strip while allowing every
/// localized label to use its natural height at accessibility text sizes.
struct AIChatSuggestionLayout<Content: View>: View {
    let stacked: Bool
    let spacing: CGFloat
    let accessibleColumns: Int
    private let content: Content

    init(
        stacked: Bool,
        spacing: CGFloat,
        accessibleColumns: Int = 1,
        @ViewBuilder content: () -> Content
    ) {
        self.stacked = stacked
        self.spacing = spacing
        self.accessibleColumns = max(1, accessibleColumns)
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if stacked, accessibleColumns > 1 {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: spacing),
                    count: accessibleColumns
                ),
                alignment: .leading,
                spacing: spacing
            ) {
                content
            }
        } else {
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
                : AnyLayout(HStackLayout(spacing: spacing))
            layout {
                content
            }
        }
    }
}

/// The longest supported history actions exceed the legacy 320pt popover at
/// maximum text scale. `ViewThatFits` keeps the compact row where possible and
/// moves the action below the title when its real fitting width is larger.
struct AIChatHistoryHeaderLayout<Title: View, Actions: View>: View {
    private let title: Title
    private let actions: Actions

    init(
        @ViewBuilder title: () -> Title,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title()
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                title
                Spacer(minLength: 12)
                actions
            }

            VStack(alignment: .leading, spacing: 8) {
                title
                actions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

// MARK: - Streaming Isolation Boundary (full-page)

/// Same isolation pattern as the floating panel's ChatStreamingSection: the
/// only view here that reads streamState's per-tick state, so streaming never
/// re-evaluates the full-page message list body.
private struct FullPageStreamingSection: View {
    let streamState: ChatStreamState
    let contextInfo: String?
    let uiScale: CGFloat
    let messageColumnMaxWidth: CGFloat

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
            base: 22,
            symbolPointSize: 14,
            scale: uiScale,
            padding: 3
        )
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.cadenza(14, scale: uiScale))
                .foregroundStyle(.secondary)
                .frame(width: iconSize, height: iconSize)
                .padding(.top, 1)

            if !streamState.hasVisibleContent {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
            } else {
                StreamingMarkdownMessageView(snapshot: streamState.snapshot, fontSize: 15, uiScale: uiScale)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: messageColumnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
