import SwiftUI

enum ProjectDetailAdaptiveLayoutPolicy {
    static func stacksControls(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }
}

enum ProjectDetailSuggestionLocalization {
    static func text(_ key: String.LocalizationValue, locale: Locale) -> String {
        LocalizedBundle.string(key, locale: locale)
    }
}

struct ProjectDetailVerticalControlGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProjectDetailSuggestionLayout<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if ProjectDetailAdaptiveLayoutPolicy.stacksControls(for: dynamicTypeSize) {
            ProjectDetailVerticalControlGroup {
                content
            }
        } else {
            HStack(spacing: 6) {
                content
            }
        }
    }
}

struct FolderDetailView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    let folderID: UUID
    @Environment(AppState.self) private var appState

    @State private var detail: FolderDetailDTO?
    @State private var detailLoadTracker = DetailLoadTracker()
    @State private var isEditingName = false
    @State private var renameText = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var showDeleteAlert = false
    @State private var selectedTab = 0

    // AI Brief state
    @State private var briefText = ""
    @State private var isBriefLoading = false
    @State private var briefError: String?

    // Ask AI state
    @State private var aiQuery = ""
    @State private var aiMessages: [ChatMessage] = []
    @State private var aiStreamState = ChatStreamState()

    private let streamRenderInterval: TimeInterval = 0.08
    private let streamRenderCharacterStride = 80

    @AppStorage("defaultAIProvider") private var defaultProviderRaw: String = AIProvider.apple.rawValue

    var body: some View {
        Group {
            if let detail {
                detailContent(detail)
            } else if detailLoadTracker.phase == .unavailable {
                unavailableFolderView
            } else {
                VStack {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadDetail() }
        .onChange(of: appState.recordingsChangedToken) { _, _ in loadDetail() }
    }

    private func loadDetail() {
        let request = detailLoadTracker.begin(hasContent: detail != nil)
        appState.fetchFolderDetail(folderID: folderID) { result in
            guard detailLoadTracker.finish(request: request, found: result != nil) else { return }
            self.detail = result
        }
    }

    private var unavailableFolderView: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "Folder Not Found",
                systemImage: "folder.badge.questionmark",
                description: Text("This folder is no longer available.")
            )
            HStack(spacing: 8) {
                Button("Refresh") { loadDetail() }
                    .buttonStyle(.bordered)
                Button("Back to Library") { appState.navigate(to: .allRecordings) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func detailContent(_ detail: FolderDetailDTO) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            folderHeader(detail)
                .padding(.bottom, 16)

            if ProjectDetailAdaptiveLayoutPolicy.stacksControls(for: dynamicTypeSize) {
                ProjectDetailVerticalControlGroup {
                    sectionButton("Recordings (\(detail.recordings.count))", index: 0)
                    sectionButton("Action Items (\(detail.actionItems.count))", index: 1)
                    sectionButton("Decisions (\(detail.decisions.count))", index: 2)
                    sectionButton("AI Brief", index: 3)
                }
                .padding(.bottom, 12)
            } else {
                Picker("", selection: $selectedTab) {
                    Text("Recordings (\(detail.recordings.count))").tag(0)
                    Text("Action Items (\(detail.actionItems.count))").tag(1)
                    Text("Decisions (\(detail.decisions.count))").tag(2)
                    Text("AI Brief").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 12)
            }

            switch selectedTab {
            case 0:
                recordingsTab(detail.recordings)
            case 1:
                actionItemsTab(detail.actionItems)
            case 2:
                decisionsTab(detail.decisions)
            case 3:
                aiBriefTab()
            default:
                EmptyView()
            }
        }
        .padding(.top, 8)
    }

    private func sectionButton(
        _ title: LocalizedStringKey,
        index: Int
    ) -> some View {
        Button {
            selectedTab = index
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedTab == index ? "largecircle.fill.circle" : "circle")
                    .font(.cadenza(13, scale: uiScale))
                Text(title)
                    .font(.cadenza(13, weight: .medium, scale: uiScale))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.cadenzaPlain)
        .accessibilityAddTraits(selectedTab == index ? .isSelected : [])
    }

    @ViewBuilder
    private func folderHeader(_ detail: FolderDetailDTO) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if isEditingName {
                    TextField("Folder name", text: $renameText, onCommit: {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            if let folder = appState.folders.first(where: { $0.id == folderID }) {
                                appState.updateFolder(folderID: folderID, name: trimmed, icon: folder.icon, iconColor: folder.iconColor)
                            }
                        }
                        isEditingName = false
                        loadDetail()
                    })
                    .textFieldStyle(.plain)
                    .font(.cadenza(.title, weight: .bold, scale: uiScale))
                    .focused($nameFieldFocused)
                    .onExitCommand { isEditingName = false }
                } else {
                    Text(detail.name)
                        .font(.cadenza(.title, weight: .bold, scale: uiScale))
                        .onTapGesture(count: 2) {
                            renameText = detail.name
                            isEditingName = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                nameFieldFocused = true
                            }
                        }
                }

                Text("\(detail.recordings.count) recordings")
                    .font(.cadenza(.subheadline, scale: uiScale))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button {
                    renameText = detail.name
                    isEditingName = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        nameFieldFocused = true
                    }
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("Delete Folder", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.cadenza(18, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .alert("Delete Folder?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                appState.deleteFolder(folderID: folderID)
                appState.navigate(to: .allRecordings)
            }
        } message: {
            Text("Recordings will not be deleted, only unlinked from this folder.")
        }
    }

    // MARK: - Recordings Tab

    @ViewBuilder
    private func recordingsTab(_ recordings: [RecordingDTO]) -> some View {
        if recordings.isEmpty {
            emptyState(icon: "waveform", message: "No recordings in this folder yet.")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(recordings) { recording in
                        recordingRow(recording)
                    }
                }
            }
        }
    }

    private func recordingRow(_ recording: RecordingDTO) -> some View {
        let waveformFrame = CadenzaControlMetrics.squareIconFrame(
            base: 24,
            symbolPointSize: 14,
            scale: uiScale,
            padding: 0
        )
        return Button {
            appState.openRecordingDetail(recordingID: recording.id, title: recording.title)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.cadenza(14, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .frame(width: waveformFrame, height: waveformFrame)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.title)
                        .font(.cadenza(13, weight: .medium, scale: uiScale))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(recording.startDate, style: .date)
                        .font(.cadenza(11, scale: uiScale))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(formattedDuration(recording.duration))
                    .font(.cadenza(11, scale: uiScale))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.cadenzaPlain)
        .contextMenu {
            Button {
                appState.moveRecordingToFolder(recordingID: recording.id, folderID: nil)
            } label: {
                Label("Remove from Folder", systemImage: "minus.circle")
            }
        }
    }

    // MARK: - Action Items Tab

    @ViewBuilder
    private func actionItemsTab(_ items: [FolderActionItemDTO]) -> some View {
        if items.isEmpty {
            emptyState(icon: "checklist", message: "No action items from recordings in this folder.")
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: entry.item.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(entry.item.isCompleted ? .green : .secondary)
                                .font(.cadenza(14, scale: uiScale))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.item.task)
                                    .font(.cadenzaBody(13, scale: uiScale))
                                    .strikethrough(entry.item.isCompleted)
                                    .foregroundStyle(entry.item.isCompleted ? .secondary : .primary)

                                HStack(spacing: 8) {
                                    if let assignee = entry.item.assignee, !assignee.isEmpty {
                                        Label(assignee, systemImage: "person")
                                            .font(.cadenza(11, scale: uiScale))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let deadline = entry.item.deadline, !deadline.isEmpty {
                                        Label(deadline, systemImage: "calendar")
                                            .font(.cadenza(11, scale: uiScale))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Button {
                                    appState.openRecordingDetail(recordingID: entry.sourceRecordingID, title: entry.sourceRecordingTitle)
                                } label: {
                                    Label(entry.sourceRecordingTitle, systemImage: "waveform")
                                        .font(.cadenza(10, scale: uiScale))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.cadenzaPlain)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    // MARK: - Decisions Tab

    @ViewBuilder
    private func decisionsTab(_ decisions: [FolderDecisionDTO]) -> some View {
        if decisions.isEmpty {
            emptyState(icon: "lightbulb", message: "No decisions recorded in this folder yet.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(decisions) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundStyle(.blue)
                                    .font(.cadenza(12, scale: uiScale))
                                    .padding(.top, 2)

                                Text(entry.text)
                                    .font(.cadenzaBody(13, scale: uiScale))
                                    .foregroundStyle(.primary)
                            }

                            Button {
                                appState.openRecordingDetail(recordingID: entry.sourceRecordingID, title: entry.sourceRecordingTitle)
                            } label: {
                                Label(entry.sourceRecordingTitle, systemImage: "waveform")
                                    .font(.cadenza(10, scale: uiScale))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.cadenzaPlain)
                            .padding(.leading, 20)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    // MARK: - AI Brief Tab

    @ViewBuilder
    private func aiBriefTab() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Brief section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Folder Brief", systemImage: "sparkles")
                        .font(.cadenza(14, weight: .semibold, scale: uiScale))

                    Spacer()

                    Button {
                        generateBrief()
                    } label: {
                        Label(briefText.isEmpty ? String(localized: "Generate") : String(localized: "Refresh"), systemImage: "arrow.clockwise")
                            .font(.cadenza(12, scale: uiScale))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBriefLoading || !appState.startupPolicy.allowsContentGeneration)
                }

                if isBriefLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating brief...")
                            .font(.cadenza(12, scale: uiScale))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                if let error = briefError {
                    Text(error)
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.red)
                }

                if !briefText.isEmpty {
                    ScrollView {
                        Group {
                            if isBriefLoading {
                                Text(briefText)
                                    .font(.cadenzaBody(13, scale: uiScale))
                            } else {
                                MarkdownMessageView(briefText, fontSize: 13, uiScale: uiScale, compact: true)
                            }
                        }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if briefText.isEmpty && !isBriefLoading && briefError == nil {
                    emptyState(icon: "sparkles", message: "Generate an AI-powered summary of your folder's current state.")
                }
            }

            Divider()

            // Ask AI section
            VStack(alignment: .leading, spacing: 8) {
                Label("Ask about this folder", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.cadenza(14, weight: .semibold, scale: uiScale))

                // Chat messages
                if !aiMessages.isEmpty || aiStreamState.isActive {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(aiMessages) { message in
                                chatBubble(message)
                            }
                            // Isolation boundary — per-tick stream reads stay inside
                            // the section so ticks don't re-evaluate this list body.
                            FolderStreamingSection(streamState: aiStreamState, uiScale: uiScale)
                        }
                    }
                    .frame(maxHeight: 300)
                }

                // Input
                HStack(spacing: 8) {
                    TextField("e.g. What should I do next?", text: $aiQuery)
                        .textFieldStyle(.plain)
                        .font(.cadenza(13, weight: .medium, scale: uiScale))
                        .onSubmit { sendAIQuery() }
                        .disabled(!appState.startupPolicy.allowsContentGeneration)

                    if aiStreamState.isActive {
                        Button {
                            aiStreamState.stop(savePartial: true)
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.cadenza(20, scale: uiScale))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.cadenzaPlain)
                        .help("Stop response")
                    } else {
                        Button {
                            sendAIQuery()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.cadenza(20, scale: uiScale))
                                .foregroundStyle(aiQuery.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                        }
                        .buttonStyle(.cadenzaPlain)
                        .disabled(
                            aiQuery.trimmingCharacters(in: .whitespaces).isEmpty
                                || !appState.startupPolicy.allowsContentGeneration
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )

                // Quick suggestions
                if aiMessages.isEmpty {
                    ProjectDetailSuggestionLayout {
                        suggestionChip("What happened last time?")
                        suggestionChip("What should I do next?")
                        suggestionChip("What blockers are unresolved?")
                    }
                }
            }
        }
    }

    private func suggestionChip(_ key: String.LocalizationValue) -> some View {
        let localizedText = ProjectDetailSuggestionLocalization.text(key, locale: locale)
        return Button {
            aiQuery = localizedText
            sendAIQuery()
        } label: {
            Text(verbatim: localizedText)
                .font(.cadenza(11, scale: uiScale))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.fill.quaternary, in: Capsule())
        }
        .buttonStyle(.cadenzaPlain)
        .disabled(
            aiStreamState.isActive
                || !appState.startupPolicy.allowsContentGeneration
        )
    }

    @ViewBuilder
    private func chatBubble(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer()
                Text(message.content)
                    .font(.cadenza(13, scale: uiScale))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else {
            assistantBubble(message.content)
        }
    }

    private func assistantBubble(_ text: String, rendersMarkdown: Bool = true) -> some View {
        Group {
            if rendersMarkdown {
                MarkdownMessageView(text, fontSize: 13, uiScale: uiScale, compact: true)
            } else {
                Text(text)
                    .font(.cadenza(13, scale: uiScale))
            }
        }
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - AI Logic

    private func generateBrief() {
        guard appState.startupPolicy.allowsContentGeneration,
              !isBriefLoading else { return }
        isBriefLoading = true
        briefError = nil
        briefText = ""

        Task {
            guard let context = await appState.store.fetchFolderContext(folderID: folderID) else {
                briefError = String(localized: "Could not load folder data.")
                isBriefLoading = false
                return
            }

            guard context.totalRecordingCount > 0 else {
                briefError = String(localized: "No recordings in this folder yet.")
                isBriefLoading = false
                return
            }

            guard let (service, model) = resolveAIService() else {
                briefError = String(
                    localized: "No AI provider configured. Add an API key in Settings."
                )
                isBriefLoading = false
                return
            }

            let systemPrompt = ProjectMemoryService.buildBriefPrompt(context: context)
            let userMessage = "Generate a status brief for \"\(context.folderName)\"."

            let stream = service.streamChat(systemPrompt: systemPrompt, userMessage: userMessage, model: model)
            do {
                briefText = try await collectBriefStreamingResponse(stream)
            } catch {
                if briefText.isEmpty {
                    briefError = String(
                        localized: "AI response failed: \(error.localizedDescription)"
                    )
                }
            }
            isBriefLoading = false
        }
    }

    private func collectBriefStreamingResponse(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var accumulated = ""
        var pendingCharacterCount = 0
        var lastRenderDate = Date()

        do {
            for try await chunk in stream {
                accumulated += chunk
                pendingCharacterCount += chunk.utf16.count

                let now = Date()
                let shouldRender = pendingCharacterCount >= streamRenderCharacterStride
                    || now.timeIntervalSince(lastRenderDate) >= streamRenderInterval
                    || chunk.contains("\n")

                if shouldRender {
                    briefText = accumulated
                    pendingCharacterCount = 0
                    lastRenderDate = now
                    await Task.yield()
                }
            }
        } catch {
            briefText = accumulated
            throw error
        }

        briefText = accumulated
        return accumulated
    }

    private func sendAIQuery() {
        let query = aiQuery.trimmingCharacters(in: .whitespaces)
        guard appState.startupPolicy.allowsContentGeneration,
              !query.isEmpty,
              !aiStreamState.isActive else { return }
        aiQuery = ""

        aiMessages.append(ChatMessage(role: .user, content: query))

        aiStreamState.run {
            guard let context = await appState.store.fetchFolderContext(folderID: folderID) else {
                aiMessages.append(ChatMessage(
                    role: .assistant,
                    content: String(localized: "Could not load folder data.")
                ))
                return
            }

            guard let (service, model) = resolveAIService() else {
                aiMessages.append(ChatMessage(
                    role: .assistant,
                    content: String(
                        localized: "No AI provider configured. Add an API key in Settings."
                    )
                ))
                return
            }

            let systemPrompt = ProjectMemoryService.buildSystemPrompt(context: context)

            // Include conversation history
            var userMessage = query
            let previousMessages = Array(aiMessages.dropLast().suffix(10))
            if !previousMessages.isEmpty {
                var packed = "Previous conversation:\n"
                for msg in previousMessages {
                    packed += "[\(msg.role.rawValue)]: \(msg.content)\n"
                }
                packed += "\nCurrent question:\n\(query)"
                userMessage = packed
            }

            let stream = service.streamChat(systemPrompt: systemPrompt, userMessage: userMessage, model: model)
            do {
                let response = try await aiStreamState.collect(stream)
                aiMessages.append(ChatMessage(role: .assistant, content: response))
            } catch is CancellationError {
                let partial = aiStreamState.currentPartialText()
                if aiStreamState.savePartialOnCancel && !partial.isEmpty {
                    aiMessages.append(ChatMessage(role: .assistant, content: partial))
                }
            } catch {
                let partial = aiStreamState.currentPartialText()
                let errorText = partial.isEmpty
                    ? String(localized: "AI response failed: \(error.localizedDescription)")
                    : partial
                aiMessages.append(ChatMessage(role: .assistant, content: errorText))
            }
        }
    }

    private func resolveAIService() -> (AIServiceProtocol, String)? {
        guard appState.startupPolicy.allowsContentGeneration else { return nil }
        guard let provider = AIProvider(rawValue: defaultProviderRaw) else { return nil }
        let apiKey: String
        if provider.requiresAPIKey {
            guard let key = KeychainManager.shared.apiKey(for: provider), !key.isEmpty else { return nil }
            apiKey = key
        } else {
            apiKey = ""
        }
        let modelID = provider.chatModel
        return RecordingsContentGenerationBoundary.constructService(
            startupPolicy: appState.startupPolicy
        ) {
            provider.makeChatService(apiKey: apiKey).map { ($0, modelID) }
        }
    }

    // MARK: - Helpers

    private func emptyState(icon: String, message: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.cadenza(32, scale: uiScale))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.cadenza(13, scale: uiScale))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Streaming Isolation Boundary (folder chat)

private struct FolderStreamingSection: View {
    let streamState: ChatStreamState
    let uiScale: CGFloat

    var body: some View {
        if streamState.isActive {
            Group {
                if streamState.hasVisibleContent {
                    StreamingMarkdownMessageView(snapshot: streamState.snapshot, fontSize: 13, uiScale: uiScale, compact: true)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
