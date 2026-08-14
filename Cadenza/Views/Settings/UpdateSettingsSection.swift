import AppKit
import SwiftUI

struct UpdateSettingsSection: View {
    private static let table = "Onboarding"

    @Environment(AppUpdateController.self) private var updateController
    @Environment(\.uiScale) private var uiScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        SettingsSectionCard(title: text("Updates")) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(text("Automatically check for updates"))
                        .font(.cadenza(14, scale: uiScale))
                    Text(text("Check GitHub Releases once a day and notify you when a newer version is available."))
                        .font(.cadenza(.subheadline, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityHidden(true)

                Spacer(minLength: 12)

                Toggle(
                    text("Automatically check for updates"),
                    isOn: Binding(
                        get: { updateController.automaticallyChecksForUpdates },
                        set: { updateController.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                .labelsHidden()
                .accessibilityLabel(text("Automatically check for updates"))
                .accessibilityHint(
                    text("Check GitHub Releases once a day and notify you when a newer version is available.")
                )
            }
            .padding(.vertical, 8)

            Divider()

            updateActionRow
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var updateActionRow: some View {
        if CadenzaTextScale.isAccessibilitySize(dynamicTypeSize) {
            VStack(alignment: .leading, spacing: 12) {
                status
                actionButtons
            }
        } else {
            HStack(spacing: 12) {
                status
                Spacer(minLength: 12)
                actionButtons
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if case .updateAvailable = updateController.state,
               let releaseURL = updateController.availableReleaseURL {
                Button(text("View Release")) {
                    NSWorkspace.shared.open(releaseURL)
                }
            }

            Button(text("Check Now")) {
                Task { await updateController.checkManually() }
            }
            .disabled(isChecking)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updateController.state {
        case .idle:
            statusLabel(
                text("No update check has run yet."),
                symbol: "clock",
                color: .secondary
            )
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text("Checking for a newer release…"))
                    .font(.cadenza(.subheadline, scale: uiScale))
                    .foregroundStyle(.secondary)
            }
        case .updateAvailable:
            statusLabel(
                availableVersionText,
                symbol: "arrow.down.circle.fill",
                color: .accentColor
            )
        case .upToDate:
            statusLabel(
                text("Cadenza is up to date."),
                symbol: "checkmark.circle.fill",
                color: .green
            )
        case .failed:
            statusLabel(
                text("Could not reach GitHub Releases. Check your connection and try again."),
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )
        }
    }

    private var availableVersionText: String {
        guard let release = updateController.availableRelease else {
            return text("A new Cadenza version is available.")
        }
        return text("Version \(release.version) is available.")
    }

    private var isChecking: Bool {
        if case .checking = updateController.state { return true }
        return false
    }

    private func statusLabel(_ value: String, symbol: String, color: Color) -> some View {
        Label {
            Text(value)
                .font(.cadenza(.subheadline, scale: uiScale))
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: Self.table)
    }
}
