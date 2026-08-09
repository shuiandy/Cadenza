import AppKit
import SwiftUI

struct MarkdownMirrorSettingsView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(AppState.self) private var appState

    @AppStorage(MarkdownMirrorLocationManager.enabledDefaultsKey) private var enabled = false
    @AppStorage(MarkdownMirrorLocationManager.includeTranscriptDefaultsKey) private var includeTranscript = false
    @State private var displayPath = MarkdownMirrorLocationManager.displayPath
    @State private var isRebuilding = false
    @State private var status: String?

    var body: some View {
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 34,
            symbolPointSize: 16,
            scale: uiScale,
            padding: 13
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.cadenza(16, scale: uiScale))
                    .frame(width: iconSize, height: iconSize)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Markdown mirror")
                        .font(.cadenza(14, weight: .medium, scale: uiScale))
                    Text(displayPath ?? String(localized: "No folder selected"))
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(displayPath == nil)
                    .onChange(of: enabled) { _, value in
                        if value { rebuild() }
                    }
            }

            Text("Keeps one conflict-safe Markdown note per recording. Cadenza skips files you edited instead of overwriting them.")
                .font(.cadenza(12, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Include full transcript", isOn: $includeTranscript)
                .controlSize(.small)
                .disabled(!enabled)
                .onChange(of: includeTranscript) { _, _ in
                    if enabled { rebuild() }
                }

            HStack {
                Button(displayPath == nil ? "Choose folder…" : "Change folder…") { chooseFolder() }
                    .controlSize(.small)
                Button("Rebuild now") { rebuild() }
                    .controlSize(.small)
                    .disabled(displayPath == nil || isRebuilding)
                if displayPath != nil {
                    Button("Disconnect", role: .destructive) {
                        MarkdownMirrorLocationManager.clearDirectory()
                        displayPath = nil
                        status = nil
                    }
                    .controlSize(.small)
                }
                if isRebuilding { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let status {
                Text(status)
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MarkdownMirrorLocationManager.setDirectory(url)
            displayPath = MarkdownMirrorLocationManager.displayPath
            enabled = true
            rebuild()
        } catch {
            status = String.localizedStringWithFormat(
                String(localized: "Could not save folder access: %@"),
                error.localizedDescription
            )
        }
    }

    private func rebuild() {
        guard !isRebuilding else { return }
        isRebuilding = true
        Task {
            let result = await appState.rebuildMarkdownMirror()
            status = String.localizedStringWithFormat(
                String(localized: "Mirror complete: %lld written, %lld unchanged, %lld conflicts, %lld failed."),
                result.written,
                result.unchanged,
                result.conflicts,
                result.failed
            )
            isRebuilding = false
        }
    }
}
