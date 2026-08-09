import SwiftUI

/// "Export all recordings" inline row, mounted inside the Notion connected
/// detail and the Craft available section. Observes the shared
/// BulkExportCoordinator on ExportService, so progress survives leaving
/// the Settings page. The two destinations share one coordinator and are
/// mutually exclusive (isBusy disables both buttons).
struct BulkExportRow: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(AppState.self) private var appState

    let destination: BulkExportCoordinator.Destination

    private var coordinator: BulkExportCoordinator { appState.exportService.bulkExporter }

    private var destinationName: String {
        destination == .notion ? "Notion" : "Craft"
    }

    private var subtitle: String {
        switch destination {
        case .notion:
            return String(localized: "Push every recording that isn't in Notion yet.")
        case .craft:
            return String(localized: "Create a Craft document for every recording not yet exported.")
        }
    }

    /// Notion additionally requires a selected database (same gate as the
    /// existing per-recording export).
    private var exportBlocked: Bool {
        destination == .notion && appState.notionDatabaseID.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Export all recordings")
                        .font(.cadenza(14, scale: uiScale))
                    Text(subtitle)
                        .font(.cadenza(.subheadline, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.vertical, 8)

            resultLine
        }
        .alert(
            String(localized: "Export to \(destinationName)?"),
            isPresented: confirmBinding
        ) {
            Button(String(localized: "Export \(confirmCount)")) {
                coordinator.beginConfirmedRun()
            }
            Button("Cancel", role: .cancel) { coordinator.dismissConfirmation() }
        } message: {
            if destination == .craft {
                Text("This creates \(confirmCount) new documents. Craft will open repeatedly while they are created.")
            } else {
                Text("\(confirmCount) recordings are not in Notion yet.")
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var trailing: some View {
        switch coordinator.phase {
        case .preparing(let d) where d == destination:
            ProgressView().controlSize(.small)
        case .running(let d, let done, let total) where d == destination:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: "\(done) / \(total)")
                    .font(.cadenza(12, design: .monospaced, scale: uiScale))
                    .foregroundStyle(.secondary)
                Button("Cancel") { coordinator.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        default:
            Button("Export All") {
                Task { await coordinator.prepare(destination) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(coordinator.isBusy || exportBlocked)
            .help(exportBlocked
                  ? String(localized: "Select a Notion database first")
                  : String(localized: "Export every recording that hasn't been exported yet"))
        }
    }

    @ViewBuilder
    private var resultLine: some View {
        switch coordinator.phase {
        case .upToDate(let d) where d == destination:
            resultText(String(localized: "All recordings already exported."), color: .secondary)
        case .finished(let d, let succeeded, let failed) where d == destination:
            if failed == 0 {
                resultText(String(localized: "✓ \(succeeded) exported"), color: .green)
            } else {
                resultText(String(localized: "\(succeeded) exported, \(failed) failed — Export All retries the failed ones."), color: .orange)
            }
        case .cancelled(let d, let exported) where d == destination:
            resultText(String(localized: "Cancelled — \(exported) exported before stopping."), color: .secondary)
        case .failed(let d, let message) where d == destination:
            resultText(message, color: .red)
        default:
            EmptyView()
        }
    }

    private func resultText(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.cadenza(.subheadline, scale: uiScale))
                .foregroundStyle(color)
            Button {
                coordinator.dismissResult()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.cadenza(11, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.cadenzaPlain)
            .help("Dismiss")
        }
        .padding(.bottom, 6)
    }

    // MARK: - Alert plumbing

    private var confirmCount: Int {
        if case .confirming(let d, let pending) = coordinator.phase, d == destination {
            return pending
        }
        return 0
    }

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: {
                if case .confirming(let d, _) = coordinator.phase, d == destination { return true }
                return false
            },
            set: { presented in
                if !presented { coordinator.dismissConfirmation() }
            })
    }
}
