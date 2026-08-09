import SwiftUI

/// Profiles pane: the active profile's account state and session actions,
/// the historical-sync consent, and the relaunch-based switcher.
struct ProfilesSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var document: ProfileRegistryDocument?
    @State private var loginCoordinator: ProfileLoginCoordinator?
    @State private var lockOnSignOut = false
    @State private var consent: HistoricalSyncConsent = .undecided
    @State private var showSignOutConfirmation = false

    private var activeProfile: Profile? { appState.profileBootContext?.profile }

    var body: some View {
        @Bindable var appState = appState
        SettingsPageLayout(
            title: SettingsCategory.profiles.title,
            subtitle: String(localized: "Accounts, switching, and history sync consent")
        ) {
            if let profile = activeProfile {
                currentProfileCard(profile)
                if profile.boundAccount != nil {
                    SubscriptionSection()
                    historicalConsentCard(profile)
                }
                switcherCard(profile)
            } else {
                SettingsSectionCard(title: String(localized: "Profiles")) {
                    Text("Profiles are unavailable until the storage upgrade completes.")
                        .font(.cadenza(13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { refresh() }
        .sheet(item: sheetBinding) { coordinator in
            ProfileLoginSheet(coordinator: coordinator) {
                loginCoordinator = nil
                refresh()
            }
        }
        .alert(
            String(localized: "Profile action failed"),
            isPresented: Binding(
                get: { appState.profileActionError != nil },
                set: { if !$0 { appState.profileActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { appState.profileActionError = nil }
        } message: {
            Text(appState.profileActionError ?? "")
        }
        .confirmationDialog(
            String(localized: "Sign out of this profile?"),
            isPresented: $showSignOutConfirmation
        ) {
            Button(String(localized: "Sign Out"), role: .destructive) {
                Task { await appState.signOutFromProfile() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Recordings stay on this Mac. Cadenza switches back to the Local profile and restarts.")
        }
    }

    private var sheetBinding: Binding<ProfileLoginCoordinator?> {
        Binding(get: { loginCoordinator }, set: { loginCoordinator = $0 })
    }

    private func refresh() {
        document = appState.loadProfileDocument()
        lockOnSignOut = activeProfile?.lockOnSignOut ?? false
        consent = HistoricalSyncConsent.readActiveProfile()
    }

    // MARK: - Current profile

    @ViewBuilder
    private func currentProfileCard(_ profile: Profile) -> some View {
        SettingsSectionCard(title: String(localized: "Current Profile")) {
            HStack(spacing: 12) {
                Image(systemName: profile.kind == .system
                    ? "internaldrive" : "person.crop.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.cadenza(14, weight: .semibold))
                    Text(sessionSubtitle(profile))
                        .font(.cadenza(12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                sessionActions(profile)
            }

            if profile.boundAccount != nil {
                Divider()
                SettingsToggleRow(
                    "Lock on sign out",
                    subtitle: "Ask for this account's sign-in before opening the profile again",
                    isOn: Binding(
                        get: { lockOnSignOut },
                        set: { newValue in
                            // Reflects the value durably in effect.
                            lockOnSignOut = appState.setLockOnSignOut(newValue)
                        }
                    )
                )
            }
        }
    }

    private func sessionSubtitle(_ profile: Profile) -> String {
        guard let bound = profile.boundAccount else {
            return String(localized: "Not linked to an account")
        }
        // Identity and backend render as one dynamic value, so the same
        // email on two backends stays distinguishable on the card too.
        let presentation = AccountIdentityPresenter.present(bound)
        let identity = "\(presentation.identity) · \(presentation.backend)"
        switch appState.cadenzaAuth.sessionState {
        case .signedIn:
            return String(localized: "Signed in as \(identity)")
        case .expired:
            return String(localized: "\(identity) — session expired, sign in to resume sync")
        case .signingIn:
            return String(localized: "Signing in…")
        case .signedOut:
            return String(localized: "\(identity) — signed out")
        }
    }

    @ViewBuilder
    private func sessionActions(_ profile: Profile) -> some View {
        if profile.boundAccount == nil {
            Button(String(localized: "Sign In…")) {
                guard let coordinator = appState.makeProfileLoginCoordinator() else { return }
                loginCoordinator = coordinator
                Task { await coordinator.begin() }
            }
        } else {
            switch appState.cadenzaAuth.sessionState {
            case .expired, .signedOut:
                Button(String(localized: "Sign In Again")) {
                    Task { await appState.signInToCadenza() }
                }
                Button(String(localized: "Sign Out…")) {
                    showSignOutConfirmation = true
                }
                .disabled(appState.profileTransitionBlockReason != nil)
            case .signedIn:
                Button(String(localized: "Sign Out…")) {
                    showSignOutConfirmation = true
                }
                .disabled(appState.profileTransitionBlockReason != nil)
            case .signingIn:
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Historical consent (spec 6.6)

    @ViewBuilder
    private func historicalConsentCard(_ profile: Profile) -> some View {
        SettingsSectionCard(title: String(localized: "History Sync")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recordings made before this profile was linked sync only with your explicit consent.")
                    .font(.cadenza(12))
                    .foregroundStyle(.secondary)
                Picker(String(localized: "Sync recordings made before linking"), selection: Binding(
                    get: { consent },
                    set: { newValue in
                        consent = newValue
                        appState.webSync?.updateHistoricalConsent(newValue)
                    }
                )) {
                    Text("Don't sync them").tag(HistoricalSyncConsent.undecided)
                    Text("Transcripts and summaries only").tag(HistoricalSyncConsent.textOnly)
                    Text("Include audio").tag(HistoricalSyncConsent.withAudio)
                }
                .pickerStyle(.menu)
                if consent == .withAudio {
                    Text("Audio uploads also require the audio upload switch in Integrations.")
                        .font(.cadenza(11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Switcher (spec 7)

    @ViewBuilder
    private func switcherCard(_ active: Profile) -> some View {
        SettingsSectionCard(title: String(localized: "All Profiles")) {
            if let document {
                if let blockReason = appState.profileTransitionBlockReason {
                    Text(blockReason)
                        .font(.cadenza(11))
                        .foregroundStyle(.orange)
                        .padding(.bottom, 4)
                }
                ForEach(document.profiles, id: \.id) { profile in
                    profileRow(profile, isActive: profile.id == active.id)
                    if profile.id != document.profiles.last?.id {
                        Divider()
                    }
                }
                // Honest add-or-switch entry from a bound active profile;
                // the unbound card's own Sign In action already covers the
                // unbound case, so no competing duplicate is shown there.
                if active.boundAccount != nil {
                    Divider()
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Add or switch account")
                                .font(.cadenza(13, weight: .medium))
                            Text("Sign in with another account. It gets its own profile, or Cadenza switches to its existing one.")
                                .font(.cadenza(11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "Sign In with Another Account…")) {
                            guard let coordinator = appState.makeProfileLoginCoordinator() else {
                                return
                            }
                            loginCoordinator = coordinator
                            Task { await coordinator.begin() }
                        }
                        .disabled(appState.profileTransitionBlockReason != nil)
                        .help(appState.profileTransitionBlockReason ?? String(
                            localized: "Adds a new account profile or switches to that account's existing profile."
                        ))
                    }
                    .padding(.vertical, 2)
                }
                Text("Switching restarts Cadenza. Sign in from a profile to link an account; signing in with an account that already has a profile switches to it.")
                    .font(.cadenza(11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                Text("The profile list is unavailable.")
                    .font(.cadenza(12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: Profile, isActive: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: profile.kind == .system
                ? "internaldrive" : "person.crop.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.cadenza(13, weight: isActive ? .semibold : .regular))
                if let bound = profile.boundAccount {
                    // Identity and backend together keep two same-email
                    // accounts on different origins distinguishable —
                    // locked rows included.
                    let presentation = AccountIdentityPresenter.present(bound)
                    Text(verbatim: "\(presentation.identity) · \(presentation.backend)")
                        .font(.cadenza(11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isActive {
                Text("Active")
                    .font(.cadenza(11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if profile.isLocked {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Sign In to Unlock…")) {
                        guard let coordinator = appState.makeProfileLoginCoordinator() else {
                            return
                        }
                        loginCoordinator = coordinator
                        Task { await coordinator.beginUnlock(of: profile.id) }
                    }
                    .disabled(appState.profileTransitionBlockReason != nil)
                    .help(appState.profileTransitionBlockReason ?? String(
                        localized: "Sign in with this profile's account to unlock and switch to it."
                    ))
                }
            } else {
                Button(String(localized: "Switch")) {
                    Task { await appState.switchProfile(to: profile.id) }
                }
                .disabled(appState.profileTransitionBlockReason != nil)
                .help(appState.profileTransitionBlockReason ?? String(localized: "Switching restarts Cadenza."))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Login sheet (spec 5.5)

extension ProfileLoginCoordinator: Identifiable {}

private struct ProfileLoginSheet: View {
    let coordinator: ProfileLoginCoordinator
    let dismiss: () -> Void
    @State private var confirmingMove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch coordinator.step {
            case .idle, .authorizing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser sign-in…")
                        .font(.cadenza(13))
                }
                Button(String(localized: "Cancel")) { dismiss() }

            case .accountAlreadyBound(_, let profileName):
                Text("This account already has the profile “\(profileName)”.")
                    .font(.cadenza(14, weight: .semibold))
                Text("Cadenza will switch to that profile and restart.")
                    .font(.cadenza(12))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "Cancel")) {
                        coordinator.reset()
                        dismiss()
                    }
                    Spacer()
                    Button(String(localized: "Switch and Restart")) {
                        Task { await coordinator.switchToExistingProfile() }
                    }
                    .keyboardShortcut(.defaultAction)
                }

            case .alreadyActiveAccount(let profileName):
                Text("You're already signed in with this account.")
                    .font(.cadenza(14, weight: .semibold))
                Text("“\(profileName)” is the active profile, so nothing changed.")
                    .font(.cadenza(12))
                    .foregroundStyle(.secondary)
                Button(String(localized: "Close")) {
                    coordinator.reset()
                    dismiss()
                }

            case .chooseTarget(let canBindCurrent, let accountName):
                Text("Link \(accountName)")
                    .font(.cadenza(14, weight: .semibold))
                if canBindCurrent {
                    Text("Link this profile's recordings to the account, or keep them separate in a new profile.")
                        .font(.cadenza(12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("The Local profile stays account-free. The account gets its own new profile.")
                        .font(.cadenza(12))
                        .foregroundStyle(.secondary)
                }
                ProfileLoginActionLayout {
                    Button(String(localized: "Cancel")) {
                        coordinator.reset()
                        dismiss()
                    }
                } actions: {
                    if canBindCurrent {
                        Button(String(localized: "Link This Profile")) {
                            Task { await coordinator.bindCurrentProfile() }
                        }
                    }
                    Button(String(localized: "Create Account Profile")) {
                        Task { await coordinator.createAccountProfile() }
                    }
                    .keyboardShortcut(.defaultAction)
                }

            case .consent:
                Text("Sync existing recordings?")
                    .font(.cadenza(14, weight: .semibold))
                Text("Linking never uploads existing recordings by itself. Choose what may sync — you can change this later in Settings.")
                    .font(.cadenza(12))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Button(String(localized: "Not now")) {
                        Task { await coordinator.finishWithConsent(nil) }
                    }
                    Button(String(localized: "Sync transcripts and summaries")) {
                        Task { await coordinator.finishWithConsent(.textOnly) }
                    }
                    Button(String(localized: "Sync with audio")) {
                        Task { await coordinator.finishWithConsent(.withAudio) }
                    }
                }

            case .transferChoice:
                Text("What about your Local recordings?")
                    .font(.cadenza(14, weight: .semibold))
                Text("The new profile starts empty. You can bring your Local recordings along, or keep them where they are.")
                    .font(.cadenza(12))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Button(String(localized: "Keep Local Separate")) {
                        Task { await coordinator.finishTransferChoice(.keepSeparate) }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button(String(localized: "Copy Local Recordings")) {
                        Task { await coordinator.finishTransferChoice(.copy) }
                    }
                    Button(String(localized: "Move Local Recordings…")) {
                        confirmingMove = true
                    }
                }
                if let blocked = coordinator.blockedReason {
                    Text(blocked)
                        .font(.cadenza(12))
                        .foregroundStyle(.orange)
                }

            case .relaunching:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Restarting…")
                        .font(.cadenza(13))
                }

            case .failed(let message):
                Text("Sign-in didn't finish")
                    .font(.cadenza(14, weight: .semibold))
                Text(message)
                    .font(.cadenza(12))
                    .foregroundStyle(.secondary)
                Button(String(localized: "Close")) {
                    coordinator.reset()
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .confirmationDialog(
            String(localized: "Move recordings out of Local?"),
            isPresented: $confirmingMove
        ) {
            Button(String(localized: "Move to New Profile"), role: .destructive) {
                Task { await coordinator.finishTransferChoice(.move) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Your recordings move into the account profile and Local starts over empty. Nothing is uploaded by this step.")
        }
    }
}

/// Keeps localized profile actions readable inside the login sheet's 372pt
/// content column. English fits on one line; longer locales reflow without
/// widening every sheet state or truncating a button label.
struct ProfileLoginActionLayout<Leading: View, Actions: View>: View {
    let leading: Leading
    let actions: Actions

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder actions: () -> Actions
    ) {
        self.leading = leading()
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                leading
                Spacer()
                actions
            }

            VStack(alignment: .leading, spacing: 8) {
                leading
                actions
            }
        }
    }
}
