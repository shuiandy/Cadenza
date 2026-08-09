import SwiftUI

/// Subscription and quota card for the account the active profile is bound to.
///
/// Values come from the presentation model and wording from the copy provider,
/// so this view holds neither policy nor strings of its own.
struct SubscriptionSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsSectionCard(
            title: EntitlementsCopy.cardTitle(),
            subtitle: EntitlementsCopy.cardSubtitle()
        ) {
            if let presentation = EntitlementsPresentation.current(appState.webSync) {
                VStack(alignment: .leading, spacing: 12) {
                    stateContent(presentation)
                    warnings(presentation)
                    audioNote(presentation)
                    actions(presentation)
                }
            } else {
                Text(verbatim: EntitlementsCopy.syncUnavailable())
                    .font(.cadenza(13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stateContent(_ presentation: EntitlementsPresentation) -> some View {
        switch presentation.state {
        case .unavailable:
            titled(EntitlementsCopy.unavailableTitle(), EntitlementsCopy.unavailableDetail())
        case .selfHostManaged:
            titled(EntitlementsCopy.selfHostTitle(), EntitlementsCopy.selfHostDetail())
        case .limits(let limits):
            limitsContent(limits)
        }
    }

    @ViewBuilder
    private func titled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.cadenza(13, weight: .semibold))
            Text(verbatim: detail).font(.cadenza(12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func limitsContent(_ limits: EntitlementsPresentation.Limits) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The plan id is opaque deployment data, shown exactly as received.
            field(EntitlementsCopy.planLabel(), limits.plan, monospaced: true)
            field(EntitlementsCopy.statusLabel(), EntitlementsCopy.lifecycle(limits.lifecycle))
            field(EntitlementsCopy.textSyncLabel(), EntitlementsCopy.textUsage(limits))
            field(EntitlementsCopy.audioStorageLabel(), EntitlementsCopy.storageUsage(limits))
            field(
                EntitlementsCopy.audioUploadLabel(),
                EntitlementsCopy.audioEntitlement(limits.audioUploadEntitled)
            )
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent {
            Text(verbatim: value)
                .font(.cadenza(13))
                .monospaced(monospaced)
        } label: {
            Text(verbatim: label).font(.cadenza(12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func warnings(_ presentation: EntitlementsPresentation) -> some View {
        if !presentation.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(presentation.warnings, id: \.self) { warning in
                    Text(verbatim: EntitlementsCopy.warning(warning))
                        .font(.cadenza(12))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func audioNote(_ presentation: EntitlementsPresentation) -> some View {
        if presentation.audioPreferenceEnabled, !presentation.audioUploadEffective {
            // The preference is deliberately left alone so a later grant
            // resumes uploads without the user re-enabling anything.
            Text(verbatim: EntitlementsCopy.audioPausedNote())
                .font(.cadenza(12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actions(_ presentation: EntitlementsPresentation) -> some View {
        HStack(spacing: 8) {
            // Without a bound authority there is nothing to fetch, so the
            // action is not offered rather than offered and inert.
            if presentation.canRefresh {
                Button(EntitlementsCopy.refresh()) {
                    appState.webSync?.refreshEntitlements()
                }
            }
            if let url = presentation.managementURL {
                Link(EntitlementsCopy.manageSubscription(), destination: url)
            }
        }
    }
}
