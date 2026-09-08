import SwiftUI

/// Connection cards for Apple Calendar, Google Calendar, and Zoom.
struct ConnectionsSection: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendar Connections")
                .font(.cadenza(.title3, weight: .bold, scale: uiScale))

            Text("Connect your calendars to see all your meetings in one place.")
                .font(.cadenza(.caption, scale: uiScale))
                .foregroundStyle(.secondary)

            // Apple Calendar
            ConnectionCard(
                title: String(localized: "Apple Calendar"),
                icon: "calendar",
                iconColor: .red,
                status: appState.hasCalendarPermission ? .connected : .disconnected,
                statusText: appState.hasCalendarPermission ? String(localized: "Connected via EventKit") : String(localized: "Not authorized"),
                connectLabel: appState.calendarPermissionStatus == .denied
                    ? "Open Settings"
                    : "Connect",
                connectAction: {
                    guard appState.startupPolicy.externalAccessEnabled else { return }
                    Task {
                        let granted = await Permissions.requestOrRecoverCalendarAccess(
                            currentStatus: appState.calendarPermissionStatus
                        )
                        await appState.applyCalendarAccessRequestOutcome(granted: granted)
                    }
                },
                disconnectAction: nil
            )

            // Google Calendar
            GoogleCalendarCard()

            // Zoom
            ZoomCard()
        }
        .disabled(!appState.startupPolicy.externalAccessEnabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Connection Card

private struct ConnectionCard: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let title: String
    let icon: String
    let iconColor: Color
    let status: ConnectionStatus
    let statusText: String
    let connectLabel: LocalizedStringKey
    let connectAction: (() -> Void)?
    let disconnectAction: (() -> Void)?

    enum ConnectionStatus {
        case connected, disconnected, connecting, error
    }

    var body: some View {
        let iconSize = CadenzaControlMetrics.squareIconFrame(
            base: 32,
            symbolPointSize: 17,
            scale: uiScale,
            padding: 9
        )
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.cadenza(.title2, scale: uiScale))
                .foregroundStyle(iconColor)
                .frame(width: iconSize, height: iconSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cadenza(.headline, scale: uiScale))
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            switch status {
            case .connected:
                if let disconnect = disconnectAction {
                    Button("Disconnect") { disconnect() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            case .disconnected:
                if let connect = connectAction {
                    Button(connectLabel) { connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            case .connecting:
                ProgressView()
                    .controlSize(.small)
            case .error:
                if let disconnect = disconnectAction {
                    Button("Retry Disconnect", role: .destructive) { disconnect() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if let connect = connectAction {
                    Button(connectLabel) { connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch status {
        case .connected: .green
        case .connecting: .orange
        case .error: .red
        case .disconnected: .secondary
        }
    }
}

// MARK: - Google Calendar Card

private struct GoogleCalendarCard: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState
    @State private var isExpanded = false
    @State private var clientID = ""
    @State private var clientSecret = ""

    private var presentation: GoogleCalendarConnectionPresentation {
        .make(
            isConnected: appState.googleCalendarConnected,
            isConnecting: appState.googleCalendarConnecting,
            error: appState.googleCalendarError
        )
    }

    private var connectionStatus: ConnectionCard.ConnectionStatus {
        switch presentation.phase {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnected: return .disconnected
        case .error: return .error
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConnectionCard(
                title: String(localized: "Google Calendar"),
                icon: "g.circle",
                iconColor: .blue,
                status: connectionStatus,
                statusText: presentation.statusText,
                connectLabel: "Connect",
                connectAction: appState.googleCalendarConnected ? nil : {
                    if clientID.isEmpty {
                        isExpanded = true
                    } else {
                        appState.connectGoogleCalendar()
                    }
                },
                disconnectAction: appState.googleCalendarConnected ? { appState.disconnectGoogleCalendar() } : nil
            )

            if isExpanded && !appState.googleCalendarConnected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google OAuth2 Credentials")
                        .font(.cadenza(.caption, weight: .bold, scale: uiScale))
                    TextField("Client ID", text: $clientID)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Client Secret (optional for PKCE)", text: $clientSecret)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save & Connect") {
                            if saveAndConnect() {
                                isExpanded = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(clientID.isEmpty)

                        Button("Cancel") { isExpanded = false }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, -4)
            }
        }
        .onAppear {
            let credentials = appState.googleCalendarCredentials()
            clientID = credentials.clientID
            clientSecret = credentials.clientSecret
        }
    }

    @discardableResult
    private func saveAndConnect() -> Bool {
        guard appState.saveGoogleCalendarCredentials(
            clientID: clientID,
            clientSecret: clientSecret
        ) else { return false }
        appState.connectGoogleCalendar()
        return true
    }
}

// MARK: - Zoom Card

private struct ZoomCard: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    private var presentation: GoogleCalendarConnectionPresentation {
        .make(
            isConnected: appState.zoomConnected,
            isConnecting: appState.zoomConnecting,
            error: appState.zoomError
        )
    }

    private var connectionStatus: ConnectionCard.ConnectionStatus {
        switch presentation.phase {
        case .connected: .connected
        case .connecting: .connecting
        case .disconnected: .disconnected
        case .error: .error
        }
    }

    var body: some View {
        // Cadenza is a Zoom Marketplace public PKCE OAuth app — no secret to
        // configure. One tap opens zoom.us/oauth/authorize in the browser.
        ConnectionCard(
            title: "Zoom",
            icon: "video",
            iconColor: .indigo,
            status: connectionStatus,
            statusText: presentation.statusText,
            connectLabel: "Connect",
            connectAction: appState.zoomConnected ? nil : { appState.connectZoom() },
            disconnectAction: appState.zoomConnected ? { appState.disconnectZoom() } : nil
        )
    }
}

// MARK: - Preview

#Preview {
    ConnectionsSection()
        .environment(AppState())
        .frame(width: 550, height: 400)
        .padding()
}
