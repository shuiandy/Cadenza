import AppKit
import SwiftUI

enum ExportBackupAdaptiveLayoutPolicy {
    static func stacksControls(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize.isAccessibilitySize
    }
}

struct ExportBackupAdaptiveRow<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let leading: Leading
    private let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    @ViewBuilder
    var body: some View {
        if ExportBackupAdaptiveLayoutPolicy.stacksControls(for: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: 8) {
                leading
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: 12) {
                leading
                Spacer(minLength: 12)
                trailing
            }
        }
    }
}

struct ExportBackupAdaptiveControls<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let regularSpacing: CGFloat
    private let content: Content

    init(
        regularSpacing: CGFloat = 8,
        @ViewBuilder content: () -> Content
    ) {
        self.regularSpacing = regularSpacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if ExportBackupAdaptiveLayoutPolicy.stacksControls(for: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: regularSpacing) {
                content
            }
        }
    }
}

/// Selected-state pill for the export format toggles (concept J): a checked
/// accent capsule reads as "will be written", the plain outline as "won't".
struct ExportFormatPillToggleStyle: ToggleStyle {
    let uiScale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                if configuration.isOn {
                    Image(systemName: "checkmark")
                        .font(.cadenza(8, weight: .bold, scale: uiScale))
                }
                configuration.label
                    .font(.cadenza(11.5, weight: configuration.isOn ? .semibold : .regular, scale: uiScale))
            }
            .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 22)
            .background(
                configuration.isOn ? Color.accentColor.opacity(0.1) : Color.clear,
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    configuration.isOn ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.16),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.cadenzaPlain(in: Capsule()))
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// Settings → General → "Export & Backup": local batch export of
/// transcripts / summaries / audio into one directory per recording.
/// Observes the shared BatchFileExporter on ExportService so progress
/// survives leaving the Settings page (same pattern as BulkExportRow).
struct ExportBackupSection: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppState.self) private var appState

    @State private var folders: [FolderDTO] = []
    @State private var scopeFolderID: UUID?
    @State private var options = BatchExportOptions()
    @State private var includeVoiceEmbeddings = false
    @State private var showsClearAutomaticBackupsConfirmation = false

    private var exporter: BatchFileExporter { appState.exportService.batchFileExporter }
    private var archiver: PortableArchiveExporter { appState.exportService.archiveExporter }

    var body: some View {
        SettingsSectionCard(title: "Export & Backup") {
            VStack(alignment: .leading, spacing: 10) {
                ExportBackupAdaptiveRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Export recordings to files")
                            .font(.cadenza(14, scale: uiScale))
                        Text("Write transcripts, summaries and audio into one folder per recording.")
                            .font(.cadenza(.subheadline, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } trailing: {
                    trailing
                }

                Picker(selection: $scopeFolderID) {
                    Text("All recordings").tag(UUID?.none)
                    ForEach(folders) { folder in
                        Text(folder.name).tag(Optional(folder.id))
                    }
                } label: {
                    Text("Scope")
                        .font(.cadenza(13, scale: uiScale))
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(exporter.isBusy)

                ExportBackupAdaptiveControls(regularSpacing: 6) {
                    Toggle("Transcript (.txt)", isOn: $options.transcriptTxt)
                    Toggle("Subtitles (.srt)", isOn: $options.transcriptSRT)
                    Toggle("Transcript (.md)", isOn: $options.transcriptMarkdown)
                    Toggle("Summary", isOn: $options.summaryMarkdown)
                    Toggle("Audio", isOn: $options.audio)
                }
                .toggleStyle(ExportFormatPillToggleStyle(uiScale: uiScale))
                .disabled(exporter.isBusy)

                resultLine

                Divider()

                ExportBackupAdaptiveRow {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Export all data (Portable Archive)")
                            .font(.cadenza(14, scale: uiScale))
                        Text("A verifiable export of every recording, transcript, summary and chat — audio included. Cadenza cannot currently import this archive. Never contains API keys or account tokens.")
                            .font(.cadenza(.subheadline, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } trailing: {
                    archiveTrailing
                }

                HStack(spacing: 12) {
                    Text("Include voice embeddings (speaker recognition data)")
                        .font(.cadenza(12, scale: uiScale))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Toggle("Include voice embeddings (speaker recognition data)", isOn: $includeVoiceEmbeddings)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(archiver.isBusy)
                        .accessibilityLabel(Text("Include voice embeddings (speaker recognition data)"))
                }

                archiveResultLine

                if appState.canClearAutomaticBackups {
                    Divider()

                    automaticBackupsRow
                }
            }
            .padding(.vertical, 4)
        }
        .task { folders = await appState.store.fetchFolders() }
        .alert(
            String(localized: "Export recordings to files?"),
            isPresented: confirmBinding
        ) {
            Button(String(localized: "Export \(confirmCount)")) {
                exporter.beginConfirmedRun()
            }
            Button("Cancel", role: .cancel) { exporter.dismissConfirmation() }
        } message: {
            Text("About \(confirmSizeText) will be written to the chosen folder.")
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var trailing: some View {
        switch exporter.phase {
        case .preparing:
            ProgressView().controlSize(.small)
        case .running(let done, let total):
            ExportBackupAdaptiveControls {
                ProgressView().controlSize(.small)
                Text(verbatim: "\(done)/\(total)")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel") { exporter.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        default:
            Button {
                startExport()
            } label: {
                Text("Choose Folder…")
                    .font(.cadenza(13, scale: uiScale))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!options.wantsAnything || exporter.isBusy)
        }
    }

    @ViewBuilder
    private var resultLine: some View {
        switch exporter.phase {
        case .finished(let succeeded, let failures):
            resultRow(
                text: failures.isEmpty
                    ? String(localized: "Exported \(succeeded) recordings.")
                    : String(localized: "Exported \(succeeded) recordings, \(failures.count) failed."),
                failures: failures,
                isError: !failures.isEmpty
            )
        case .cancelled(let exported, let failures):
            resultRow(
                text: String(localized: "Cancelled — \(exported) recordings were exported."),
                failures: failures,
                isError: false
            )
        case .failed(let message):
            resultRow(text: message, failures: [], isError: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func resultRow(text: String, failures: [BatchExportFailure], isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ExportBackupAdaptiveRow {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(isError ? Color.orange : Color.green)
                    Text(text)
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Button("Dismiss") { exporter.dismissResult() }
                    .buttonStyle(.cadenzaPlain)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            ForEach(failures.prefix(5)) { failure in
                Text(verbatim: "• \(failure.title): \(failure.reason)")
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            if failures.count > 5 {
                Text("…and \(failures.count - 5) more")
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var archiveTrailing: some View {
        switch archiver.phase {
        case .running(let done, let total):
            ExportBackupAdaptiveControls {
                ProgressView().controlSize(.small)
                Text(total > 0 ? "\(done)/\(total)" : "…")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel") { archiver.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .verifying(let done, let total):
            ExportBackupAdaptiveControls {
                ProgressView().controlSize(.small)
                Text("Verifying \(done)/\(total)")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel") { archiver.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        default:
            Button {
                startArchive()
            } label: {
                Text("Export Archive…")
                    .font(.cadenza(13, scale: uiScale))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(archiver.isBusy || exporter.isBusy)
        }
    }

    @ViewBuilder
    private var archiveResultLine: some View {
        switch archiver.phase {
        case .finished(let path, let recordings, let failures):
            ExportBackupAdaptiveRow {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: failures == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(failures == 0 ? Color.green : Color.orange)
                    Text(failures == 0
                        ? String(localized: "Archived \(recordings) recordings.")
                        : String(localized: "Archived \(recordings) recordings, \(failures) failed — see manifest.json."))
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                ExportBackupAdaptiveControls {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.cadenzaPlain)
                    .font(.cadenza(12, scale: uiScale))
                    Button("Dismiss") { archiver.dismissResult() }
                        .buttonStyle(.cadenzaPlain)
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        case .failed(let message):
            ExportBackupAdaptiveRow {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange)
                    Text(message)
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Button("Dismiss") { archiver.dismissResult() }
                    .buttonStyle(.cadenzaPlain)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        case .cancelled:
            ExportBackupAdaptiveRow {
                Text("Archive export cancelled.")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                Button("Dismiss") { archiver.dismissResult() }
                    .buttonStyle(.cadenzaPlain)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        default:
            EmptyView()
        }
    }

    private var automaticBackupsRow: some View {
        ExportBackupAdaptiveRow {
            VStack(alignment: .leading, spacing: 3) {
                Text("Automatic recovery backups")
                    .font(.cadenza(14, scale: uiScale))
                Text("Cadenza keeps up to three startup recovery copies. This action clears copies for the current profile and from earlier versions without changing your active library.")
                    .font(.cadenza(.subheadline, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            if appState.isClearingAutomaticBackups {
                ExportBackupAdaptiveControls {
                    ProgressView()
                        .controlSize(.small)
                    Text("Clearing…")
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Clear Backups…") {
                    showsClearAutomaticBackupsConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!appState.canClearAutomaticBackups)
            }
        }
        .alert(
            String(localized: "Clear all automatic recovery backups?"),
            isPresented: $showsClearAutomaticBackupsConfirmation
        ) {
            Button("Clear Backups", role: .destructive) {
                Task { await appState.clearAllAutomaticBackups() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes Cadenza's startup recovery copies for this profile, including backups from earlier versions. Your active library is not deleted.")
        }
    }

    // MARK: - Actions

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: {
                if case .confirming = exporter.phase { return true }
                return false
            },
            set: { presented in
                if !presented { exporter.dismissConfirmation() }
            }
        )
    }

    private var confirmCount: Int {
        if case .confirming(let pending, _) = exporter.phase { return pending }
        return 0
    }

    private var confirmSizeText: String {
        if case .confirming(_, let bytes) = exporter.phase {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return ""
    }

    private func startExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let folderID = scopeFolderID
        let selectedOptions = options
        Task {
            let ids = await appState.store.fetchRecordingDTOs(
                sortKey: "dateOldest", folderID: folderID, tagFilter: nil
            ).map(\.id)
            guard !ids.isEmpty else {
                ToastCenter.shared.error(String(localized: "No recordings to export"))
                return
            }
            await exporter.prepare(recordingIDs: ids, options: selectedOptions, destination: destination)
        }
    }

    private func startArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Export Here")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let includeEmbeddings = includeVoiceEmbeddings
        Task {
            await archiver.export(toParent: destination, includeVoiceEmbeddings: includeEmbeddings)
        }
    }
}
