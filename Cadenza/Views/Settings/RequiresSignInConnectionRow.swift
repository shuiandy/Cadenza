import SwiftUI

enum ConnectionRowIcon {
    case system(String)
    case asset(String)
}

/// Generic gated-connection settings row.
///
/// Surfaces three states:
/// - signed-out: row disabled, hint pointing to account
/// - disconnected (signed in): "Connect" button visible
/// - connected: status text + provided `connectedDetail` payload
///
/// Per-integration `AuthError.integrationReauthRequired` is rendered
/// inline (orange banner inside the row), keeping account-level
/// `AuthErrorBanner` clean.
struct RequiresSignInConnectionRow<Detail: View>: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let icon: ConnectionRowIcon
    let title: String
    let subtitleConnected: String?
    let subtitleDisconnected: String
    let isSignedIn: Bool
    let isConnected: Bool
    let isConnecting: Bool
    let reauthRequiredFor: String?
    let error: AuthError?  // NEW — generic per-integration error to surface inline
    let connect: () -> Void
    let disconnect: () -> Void
    @ViewBuilder var connectedDetail: () -> Detail

    var body: some View {
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 28,
            symbolPointSize: 15,
            scale: uiScale,
            padding: 8
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                iconView
                    .frame(width: iconSize, height: iconSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.cadenza(.headline, scale: uiScale))
                    Text(subtitle)
                        .font(.cadenza(.subheadline, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                trailingControl
            }
            if let reauthRequiredFor {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    Text("Reconnect \(reauthRequiredFor) to keep using it.")
                        .font(.cadenza(.subheadline, scale: uiScale))
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.orange.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let error, !isReauth(error), let description = error.errorDescription {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(description)
                        .font(.cadenza(.subheadline, scale: uiScale))
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.red.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if isConnected {
                connectedDetail()
            }
        }
        .opacity(isSignedIn ? 1 : 0.5)
        .allowsHitTesting(isSignedIn)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.cadenza(.title3, scale: uiScale))
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .padding(2)
                .frame(width: 28, height: 28)
        }
    }

    private func isReauth(_ e: AuthError) -> Bool {
        if case .integrationReauthRequired = e { return true }
        return false
    }

    private var subtitle: String {
        if !isSignedIn { return String(localized: "Sign in to Cadenza first.") }
        if isConnected { return subtitleConnected ?? String(localized: "Connected.") }
        return subtitleDisconnected
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isConnecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        } else if isConnected {
            Button("Disconnect", role: .destructive, action: disconnect)
        } else {
            Button("Connect", action: connect)
                .disabled(!isSignedIn)
        }
    }
}
