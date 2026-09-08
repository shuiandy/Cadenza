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
        // Concept P: a status capsule states configured-ness, choosing the
        // folder is THE primary action while unconfigured, and the dependent
        // options ride a rail that only lights up once a folder exists.
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.cadenza(16, scale: uiScale))
                    .frame(width: iconSize, height: iconSize)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("Markdown mirror")
                            .font(.cadenza(14, weight: .medium, scale: uiScale))
                        SettingsStatusCapsule(
                            kind: displayPath == nil ? .disconnected : .connected,
                            label: displayPath == nil ? "Not configured" : "Ready"
                        )
                    }
                    Text(displayPath ?? String(localized: "No folder selected"))
                        .font(.cadenza(12, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if displayPath == nil {
                    Button("Choose folder…") { chooseFolder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
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

            SettingsDependentRow {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Include full transcript")
                            .font(.cadenza(12.5, scale: uiScale))
                        Spacer()
                        Toggle("Include full transcript", isOn: $includeTranscript)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(!enabled)
                            .accessibilityLabel(Text("Include full transcript"))
                            .onChange(of: includeTranscript) { _, _ in
                                if enabled { rebuild() }
                            }
                    }
                    .padding(.vertical, 6)

                    Divider().opacity(0.5)

                    HStack(spacing: 8) {
                        if displayPath != nil {
                            Button("Change folder…") { chooseFolder() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Disconnect", role: .destructive) {
                                MarkdownMirrorLocationManager.clearDirectory()
                                displayPath = nil
                                status = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        if isRebuilding { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Rebuild now") { rebuild() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(displayPath == nil || isRebuilding)
                    }
                    .padding(.vertical, 6)

                    if let status {
                        Text(status)
                            .font(.cadenza(11, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                    }
                }
            }
            .opacity(displayPath == nil ? 0.5 : 1)
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
