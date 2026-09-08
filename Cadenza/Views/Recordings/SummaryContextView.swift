import SwiftUI
import AppKit

/// Detail-only view. Private context is never loaded by recording list projections.
struct SummaryContextView: View {
    @Environment(AppState.self) private var appState
    let detail: RecordingDetailDTO
    let event: MeetingEventDTO?
    @AppStorage(ActiveProfileDefaults.key("userName")) private var userName = ""
    @AppStorage(ActiveProfileDefaults.key("userJobTitle")) private var jobTitle = ""
    @AppStorage(ActiveProfileDefaults.key("summaryFocus")) private var defaultFocus = ""
    @State private var loadedRevision: String?
    @State private var input = SummaryContextInput()
    @State private var result: PersonalRelevance?
    @State private var candidates: [RecordingDTO] = []
    @State private var editing = false
    @State private var generating = false
    @State private var error: String?
    @State private var generationTask: Task<Void, Never>?

    private var refreshKey: String {
        "\(appState.recordingsChangedToken)|\(detail.summary?.id.uuidString ?? "")|\(detail.updatedAt?.timeIntervalSince1970 ?? 0)|\(userName)|\(jobTitle)|\(defaultFocus)|\(SummaryContextSnapshot.digest(event))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { editing = true } label: { Label("Meeting context", systemImage: "slider.horizontal.3") }
                    .disabled(generating)
                if generating { ProgressView().controlSize(.small); Button("Cancel") { generationTask?.cancel() } }
                Spacer()
                if result != nil { Button("Copy personal notes") { copyNotes() } }
            }
            .controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if let result {
                if !result.relevant.isEmpty {
                    Text("Related to you").font(.headline)
                    ForEach(result.relevant) { item in
                        Text("• \(item.text)")
                            .help(referenceText(item.references, source: result.source))
                    }
                }
                if !result.suggestions.isEmpty {
                    Text("Optional follow-up ideas").font(.headline)
                    ForEach(result.suggestions) { item in Text("• \(item.text)").help(referenceText(item.references, source: result.source)) }
                }
                if !result.progress.isEmpty {
                    Text("Progress since related meetings").font(.headline)
                    ForEach(result.progress) { item in
                        if let prior = result.source.history.first(where: { $0.recordingID == item.recordingID }) {
                            VStack(alignment: .leading, spacing: 3) {
                                if let title = prior.title { Text(title).font(.caption.bold()) }
                                Text(prior.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                if item.currentReferences.isEmpty {
                                    Text(prior.facts.first(where: { $0.id == item.previousReference })?.text ?? "")
                                    Text("Not updated in this meeting").foregroundStyle(.secondary)
                                } else { Text(item.text) }
                            }
                        }
                    }
                }
                DisclosureGroup("Context used") {
                    Text([result.source.userName, result.source.jobTitle, result.source.focus].filter { !$0.isEmpty }.joined(separator: " · ")).textSelection(.enabled)
                    if !result.source.background.isEmpty { Text(result.source.background).textSelection(.enabled) }
                    if let calendar = result.source.calendar { Text(calendar).font(.caption).textSelection(.enabled) }
                    ForEach(result.source.history, id: \.recordingID) { prior in
                        HStack { Text(prior.title ?? ""); Text(prior.date, style: .date) }.font(.caption)
                    }
                    Text(result.createdAt, style: .date).font(.caption)
                }
            }
        }
        .task(id: refreshKey) { await load() }
        .onDisappear { generationTask?.cancel() }
        .sheet(isPresented: $editing) {
            editor.task {
                candidates = await appState.store.fetchSummaryHistoryCandidates(currentID: detail.id, before: detail.startDate)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Meeting context").font(.title2.bold())
            Text("Optional context helps select personal notes. It does not change the meeting record. Your selected AI provider receives this context when you update personal notes.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Focus for this meeting", text: $input.focus).textFieldStyle(.roundedBorder)
            TextField("Background for this meeting", text: $input.background, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder)
            if !defaultFocus.isEmpty { Text(defaultFocus).font(.caption).foregroundStyle(.secondary) }
            Toggle("Include linked calendar background", isOn: $input.includeCalendar)
                .disabled(event == nil && !input.includeCalendar)
            if let event, input.includeCalendar {
                Text(event.title).font(.caption)
                Text(event.notes ?? "").font(.caption).lineLimit(5)
            }
            Toggle("Use selected related meetings", isOn: $input.includeHistory)
            if input.includeHistory {
                Text("Select up to three earlier meetings from the last 90 days.").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(candidates) { candidate in
                            Toggle(isOn: Binding(get: { input.historyIDs.contains(candidate.id) }, set: { selected in
                                if selected && input.historyIDs.count < 3 { input.historyIDs.append(candidate.id) }
                                else if !selected { input.historyIDs.removeAll { $0 == candidate.id } }
                            })) {
                                HStack { Text(candidate.title); Spacer(); Text(candidate.startDate, style: .date).foregroundStyle(.secondary) }
                            }
                            .disabled(input.historyIDs.count >= 3 && !input.historyIDs.contains(candidate.id))
                        }
                    }
                }.frame(maxHeight: 150)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { editing = false; Task { await load(force: true) } }
                Spacer()
                Button("Save context") { generationTask = Task { await saveInput(); editing = false } }
                Button("Update personal notes") {
                    editing = false
                    generationTask = Task { await update() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(generating || detail.summary == nil || detail.summary?.generationMetadata?.sourceChanged == true || !appState.startupPolicy.allowsContentGeneration)
            }
        }
        .padding(24).frame(width: 540)
    }

    @MainActor private func snapshot() async -> SummaryContextSnapshot? {
        guard let current = await appState.store.fetchSummaryContextDetail(recordingID: detail.id) else { return nil }
        let history = input.includeHistory
            ? await MeetingPrepContextBuilder.confirmedHistory(store: appState.store, ids: input.historyIDs, currentID: current.id, before: current.startDate) : []
        let linked: MeetingEventDTO?
        if input.includeCalendar, let eventID = current.linkedCalendarEventID {
            linked = appState.fetchLinkedCalendarEvent(calendarEventID: eventID, around: current.startDate, endDate: current.endDate)
        } else { linked = nil }
        return SummaryContextSnapshot.build(detail: current, input: input, userName: userName, jobTitle: jobTitle,
            defaultFocus: defaultFocus, event: linked, history: history)
    }
    @MainActor private func load(force: Bool = false) async {
        guard !editing else { return }
        let revision = await appState.store.summaryContextRevision(recordingID: detail.id)
            + "|\(userName)|\(jobTitle)|\(defaultFocus)|\(SummaryContextSnapshot.digest(event))"
        guard !Task.isCancelled, !editing, force || revision != loadedRevision else { return }
        let saved = await appState.store.fetchSummaryContext(recordingID: detail.id)
        guard !Task.isCancelled, !editing else { return }
        input = saved.0
        let current = saved.1 != nil ? await snapshot() : nil
        guard !Task.isCancelled, !editing else { return }
        result = saved.1?.contextFingerprint == current?.fingerprint ? saved.1 : nil
        loadedRevision = revision
    }

    @MainActor @discardableResult private func saveInput() async -> Bool {
        let saved = await appState.store.saveSummaryContext(recordingID: detail.id, input: input)
        if saved { result = nil; error = nil } else { error = String(localized: "Personal notes could not be saved.") }
        return saved
    }
    @MainActor private func update() async {
        guard !generating, appState.startupPolicy.allowsContentGeneration else { return }
        generating = true; error = nil
        defer { generating = false }
        guard await saveInput(), let snapshot = await snapshot(), !Task.isCancelled else { return }
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "defaultAIProvider") ?? "") ?? .apple
        let model = provider.summaryModel
        guard let key = provider.requiresAPIKey ? KeychainManager.shared.apiKey(for: provider) : "" else {
            error = AIServiceError.noAPIKey.localizedDescription; return
        }
        do {
            let output = try await PersonalRelevanceGenerator.generate(snapshot: snapshot, provider: provider, apiKey: key,
                model: model, language: detail.summary?.language ?? "en")
            guard !Task.isCancelled, await self.snapshot()?.fingerprint == snapshot.fingerprint else { return }
            if await appState.store.savePersonalRelevance(recordingID: detail.id, result: output) { result = output }
            else { error = String(localized: "Personal notes could not be saved.") }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    private func referenceText(_ references: [String], source: SummaryContextSnapshot) -> String {
        references.compactMap { id in source.facts.first(where: { $0.id == id })?.text }.joined(separator: "\n")
    }
    private func copyNotes() {
        guard let result else { return }
        let progress = result.progress.compactMap { item -> String? in
            guard let prior = result.source.history.first(where: { $0.recordingID == item.recordingID }) else { return nil }
            let content = item.currentReferences.isEmpty
                ? (prior.facts.first(where: { $0.id == item.previousReference })?.text ?? "") + " — " + String(localized: "Not updated in this meeting")
                : item.text
            return "\(prior.title ?? "") (\(prior.date.formatted(date: .abbreviated, time: .omitted))): \(content)"
        }
        let text = ([String(localized: "Related to you")] + result.relevant.map(\.text)
            + [String(localized: "Optional follow-up ideas")] + result.suggestions.map(\.text)
            + [String(localized: "Progress since related meetings")] + progress).joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
