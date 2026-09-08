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
        // Concept N: one plan row with a lifecycle capsule, then scannable
        // usage tiles instead of five label:value prose lines.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // The plan id is opaque deployment data, shown exactly as received.
                Text(verbatim: limits.plan)
                    .font(.cadenza(13, weight: .semibold))
                    .monospaced()
                SettingsStatusCapsule(
                    kind: lifecycleCapsuleKind(limits.lifecycle),
                    verbatimLabel: EntitlementsCopy.lifecycle(limits.lifecycle)
                )
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                statTile(EntitlementsCopy.textSyncLabel(), EntitlementsCopy.textUsage(limits))
                statTile(EntitlementsCopy.audioStorageLabel(), EntitlementsCopy.storageUsage(limits))
                statTile(
                    EntitlementsCopy.audioUploadLabel(),
                    EntitlementsCopy.audioEntitlement(limits.audioUploadEntitled),
                    positive: limits.audioUploadEntitled
                )
            }
        }
    }

    private func lifecycleCapsuleKind(
        _ lifecycle: EntitlementsPresentation.Known<EntitlementsPresentation.Lifecycle>
    ) -> SettingsStatusCapsule.Kind {
        if case .defined(.active) = lifecycle { return .connected }
        return .attention
    }

    @ViewBuilder
    private func statTile(_ label: String, _ value: String, positive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label)
                .font(.cadenza(10))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.cadenza(12, weight: .medium))
                .foregroundStyle(positive ? Color.green : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            positive ? Color.green.opacity(0.07) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    positive ? Color.green.opacity(0.2) : Color.primary.opacity(0.09),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .combine)
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
