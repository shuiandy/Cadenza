import AppKit
import SwiftUI

enum FirstLaunchOnboarding {
    static let completionVersionKey = "onboardingCompletedVersion"
    static let startedVersionKey = "onboardingStartedVersion"
    static let currentVersion = 1

    static func shouldPresent(
        completedVersion: Int,
        startedVersion: Int,
        allowsOnboarding: Bool
    ) -> Bool {
        allowsOnboarding
            && completedVersion < currentVersion
            && startedVersion >= currentVersion
    }

    /// This decision runs before profile bootstrap mutates disk. Existing
    /// installations therefore cannot be mistaken for a new install merely
    /// because their migration journal has the same durable "fresh" shape.
    static func shouldRecordStartedVersion(
        completedVersion: Int,
        startedVersion: Int,
        hasPriorInstallationEvidence: Bool
    ) -> Bool {
        completedVersion < currentVersion
            && startedVersion < currentVersion
            && !hasPriorInstallationEvidence
    }
}

struct OnboardingChoices: Equatable, Sendable {
    let meetingDetectionEnabled: Bool
    let captureMicrophoneEnabled: Bool
    let wantsAccount: Bool
}

struct FirstLaunchOnboardingView: View {
    private enum Step: Int, CaseIterable {
        case welcome
        case recordingPermissions
        case meetingTools
        case ready
    }

    private enum PermissionAction: Equatable {
        case microphone
        case systemAudio
        case screenRecording
        case accessibility
    }

    private static let table = "Onboarding"

#if DEBUG
    private static let previewOverrideKey = "CADENZA_PREVIEW_ONBOARDING"
#endif

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.uiScale) private var environmentUIScale

    @AppStorage("uiScale") private var uiScalePreset: UIScalePreset = .default
    @AppStorage("appIconVariant") private var appIconVariant: AppIconVariant = .classic

    @State private var step: Step = .welcome
    @State private var meetingDetectionEnabled: Bool
    @State private var captureMicrophoneEnabled: Bool
    @State private var microphoneStatus: PermissionStatus = .notDetermined
    @State private var screenRecordingStatus: PermissionStatus = .notDetermined
    @State private var accessibilityStatus: PermissionStatus = .notDetermined
    @State private var activePermissionAction: PermissionAction?
    @State private var screenRecordingRequestAttempted = false
    @State private var accessibilityRequestAttempted = false
    @State private var permissionError: String?
    @State private var hasRevealedBrand = false
    @AccessibilityFocusState private var pageTitleIsFocused: Bool

    let accountIsConfigured: Bool
    let onComplete: @MainActor (OnboardingChoices) -> Void

    init(
        meetingDetectionEnabled: Bool,
        captureMicrophoneEnabled: Bool,
        accountIsConfigured: Bool,
        onComplete: @escaping @MainActor (OnboardingChoices) -> Void
    ) {
        _meetingDetectionEnabled = State(initialValue: meetingDetectionEnabled)
        _captureMicrophoneEnabled = State(initialValue: captureMicrophoneEnabled)
        self.accountIsConfigured = accountIsConfigured
        self.onComplete = onComplete
    }

    private var uiScale: CGFloat {
        max(environmentUIScale, CadenzaTextScale.combined(
            uiScale: uiScalePreset.scaleFactor,
            dynamicTypeSize: dynamicTypeSize
        ))
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header

                pageColumn
                    .padding(.horizontal, 30)
                    .padding(.top, 22)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: 840, maxHeight: 600)
            .modifier(OnboardingPanelStyle(reduceTransparency: reduceTransparency))
            .padding(20)
        }
        .environment(\.uiScale, uiScale)
        .accessibilityIdentifier("onboarding.root")
        .task {
            refreshPermissionStatuses()
            if appState.startupPolicy.checksPermissions {
                await appState.checkPermissions()
                refreshPermissionStatuses()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { @MainActor in
                if appState.startupPolicy.checksPermissions {
                    await appState.checkPermissions()
                }
                refreshPermissionStatuses()
            }
        }
        .alert(
            text("Setup needs attention"),
            isPresented: Binding(
                get: { permissionError != nil },
                set: { if !$0 { permissionError = nil } }
            )
        ) {
            if appState.recordingErrorOffersSystemAudioSettings {
                Button(text("Open System Settings")) {
                    Permissions.openSystemAudioRecordingSettings()
                    appState.dismissRecordingError()
                }
            }
            Button(text("OK"), role: .cancel) {
                appState.dismissRecordingError()
            }
        } message: {
            Text(permissionError ?? "")
        }
    }

    private var pageColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScrollView {
                page
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.trailing, 4)
            }
            .id(step)
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            navigation
        }
    }

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.2), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 620
            )
            RadialGradient(
                colors: [Color.orange.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                OnboardingBrandReveal(
                    variant: appIconVariant,
                    isRevealed: $hasRevealedBrand
                )
                Spacer(minLength: 16)
                stepProgress
            }

            VStack(alignment: .leading, spacing: 10) {
                OnboardingBrandReveal(
                    variant: appIconVariant,
                    isRevealed: $hasRevealedBrand
                )
                HStack {
                    Spacer()
                    stepProgress
                }
            }
        }
        .environment(\.uiScale, uiScale)
        .padding(.horizontal, 30)
        .padding(.vertical, 14)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.thinMaterial)
            }
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }

    private var stepProgress: some View {
        HStack(spacing: 10) {
            if !CadenzaTextScale.isAccessibilitySize(dynamicTypeSize) {
                HStack(spacing: 7) {
                    ForEach(Step.allCases, id: \.rawValue) { item in
                        Capsule()
                            .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.22))
                            .frame(width: item == step ? 24 : 7, height: 7)
                            .accessibilityHidden(true)
                    }
                }
            }

            Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                .font(.cadenza(.caption, scale: uiScale).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    text("Setup step \(step.rawValue + 1) of \(Step.allCases.count)")
                )
        }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            welcomePage.transition(pageTransition)
        case .recordingPermissions:
            recordingPermissionsPage.transition(pageTransition)
        case .meetingTools:
            meetingToolsPage.transition(pageTransition)
        case .ready:
            readyPage.transition(pageTransition)
        }
    }

    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            pageTitle(
                eyebrow: "WELCOME",
                title: "Your meetings, remembered.",
                subtitle: "A short setup prepares Cadenza to capture clear audio and recognize meetings reliably."
            )

            VStack(spacing: 10) {
                featureRow(
                    symbol: "record.circle",
                    title: "Record the conversation",
                    detail: "Capture meeting audio and, if you choose, your microphone."
                )
                featureRow(
                    symbol: "text.bubble",
                    title: "Turn speech into useful notes",
                    detail: "Cadenza creates a transcript, summary, and action items after you stop."
                )
                featureRow(
                    symbol: "magnifyingglass",
                    title: "Find every decision later",
                    detail: "Search recordings, review notes, and ask follow-up questions from one place."
                )
            }
        }
    }

    private var recordingPermissionsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageTitle(
                eyebrow: "RECORDING ACCESS",
                title: "Prepare clear meeting audio",
                subtitle: "System Audio captures the meeting. Microphone access adds your side of the conversation."
            )

            OnboardingPermissionRow(
                symbol: "waveform",
                title: text("System Audio"),
                detail: text("Captures audio playing on your Mac, including people and media from meeting apps. Setup briefly tests a private audio tap and creates no recording."),
                status: appState.hasPreparedSystemAudioCapture
                    ? text("Set up")
                    : text("Needs setup"),
                visualState: appState.isPreparingSystemAudioCapture
                    ? .working
                    : (appState.hasPreparedSystemAudioCapture ? .ready : .pending)
            ) {
                Button {
                    prepareSystemAudio()
                } label: {
                    permissionButtonLabel(
                        title: appState.isPreparingSystemAudioCapture
                            ? text("Setting up…")
                            : text("Set Up"),
                        symbol: "waveform"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(activePermissionAction != nil || appState.isPreparingSystemAudioCapture)
                .accessibilityIdentifier("onboarding.systemAudio")
            }

            OnboardingPermissionRow(
                symbol: "mic",
                title: text("Microphone"),
                badge: text("OPTIONAL"),
                detail: text("Adds your voice to recordings. Granting access also turns on Include my microphone."),
                status: permissionStatusText(microphoneStatus),
                visualState: microphoneStatus == .granted
                    ? .ready
                    : (captureMicrophoneEnabled ? .pending : .optional)
            ) {
                microphoneAction
            }

            Text(text("You can continue without a microphone and record System Audio only."))
                .font(.cadenza(.caption, scale: uiScale))
                .foregroundStyle(.secondary)
        }
    }

    private var meetingToolsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageTitle(
                eyebrow: "MEETING TOOLS",
                title: "Make meeting capture effortless",
                subtitle: "These optional tools improve meeting prompts and let shortcuts work while another app is active."
            )

            choiceCard(
                symbol: "person.wave.2",
                title: "Turn on Meeting Detection",
                detail: "Watch supported meeting apps and offer a recording prompt. Automatic recording remains a separate choice in Settings.",
                isOn: $meetingDetectionEnabled,
                accessibilityIdentifier: "onboarding.meetingDetection"
            )

            OnboardingPermissionRow(
                symbol: "rectangle.on.rectangle",
                title: text("Screen Recording"),
                badge: text("OPTIONAL"),
                detail: text("Lets Cadenza read meeting window information for more reliable Teams start and stop detection. No screen image is recorded."),
                status: permissionStatusText(screenRecordingStatus),
                visualState: screenRecordingStatus == .granted ? .ready : .optional
            ) {
                Button {
                    requestScreenRecording()
                } label: {
                    permissionButtonLabel(
                        title: screenRecordingStatus == .granted
                            ? text("Open Settings")
                            : (screenRecordingRequestAttempted
                                ? text("Open Settings")
                                : text("Allow")),
                        symbol: screenRecordingStatus == .granted || screenRecordingRequestAttempted
                            ? "gearshape"
                            : "rectangle.on.rectangle"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(activePermissionAction != nil)
                .accessibilityIdentifier("onboarding.screenRecording")
            }

            OnboardingPermissionRow(
                symbol: "keyboard",
                title: text("Accessibility"),
                badge: text("OPTIONAL"),
                detail: text("Lets Command-Shift-R and Command-Shift-P control recording while another app is active."),
                status: permissionStatusText(accessibilityStatus),
                visualState: accessibilityStatus == .granted ? .ready : .optional
            ) {
                Button {
                    requestAccessibility()
                } label: {
                    permissionButtonLabel(
                        title: accessibilityStatus == .granted
                            ? text("Open Settings")
                            : (accessibilityRequestAttempted
                                ? text("Open Settings")
                                : text("Allow")),
                        symbol: accessibilityStatus == .granted || accessibilityRequestAttempted
                            ? "gearshape"
                            : "accessibility"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(activePermissionAction != nil)
                .accessibilityIdentifier("onboarding.accessibility")
            }
        }
    }

    private var readyPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageTitle(
                eyebrow: "READY",
                title: "Ready when you are",
                subtitle: "Finish with a Local profile, or sign in to create an account profile and review sync choices."
            )

            permissionSummary

            if accountIsConfigured {
                accountPrivacyNote

                Button {
                    finish(wantsAccount: false)
                } label: {
                    Text(text("Finish Setup"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.finish")
            } else {
                VStack(spacing: 10) {
                    Button {
                        finish(wantsAccount: false)
                    } label: {
                        Text(text("Continue without an account"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.continueLocal")

                    Button {
                        finish(wantsAccount: true)
                    } label: {
                        Label(
                            text("Sign in or create an account"),
                            systemImage: "person.crop.circle.badge.plus"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding.createAccount")
                }

                accountPrivacyNote
            }
        }
    }

    private var permissionSummary: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130, maximum: 220), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            summaryChip(
                text("System Audio"),
                ready: appState.hasPreparedSystemAudioCapture
            )
            summaryChip(
                text("Microphone"),
                ready: microphoneStatus == .granted && captureMicrophoneEnabled
            )
            summaryChip(
                text("Meeting Detection"),
                ready: meetingDetectionEnabled
            )
            summaryChip(
                text("Screen Recording"),
                ready: screenRecordingStatus == .granted
            )
            summaryChip(
                text("Global Shortcuts"),
                ready: accessibilityStatus == .granted
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var accountPrivacyNote: some View {
        Label {
            Text(text("Sign-in opens sync choices. Existing recordings stay local unless you include them, and uploading audio is a separate opt-in."))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
        }
        .font(.cadenza(.caption, scale: uiScale))
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var navigation: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button(text("Back")) {
                    move(to: step.rawValue - 1)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            }

            Spacer()

            if step != .ready {
                Button(step == .welcome ? text("Set Up Recording") : text("Continue")) {
                    move(to: step.rawValue + 1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.continue")
            }
        }
        .disabled(activePermissionAction != nil)
    }

    private func move(to rawValue: Int) {
        guard let next = Step(rawValue: rawValue) else { return }
        pageTitleIsFocused = false
        if reduceMotion {
            step = next
        } else {
            withAnimation(.snappy(duration: 0.3)) {
                step = next
            }
        }
        Task { @MainActor in
            await Task.yield()
            pageTitleIsFocused = true
        }
    }

    private func pageTitle(
        eyebrow: String.LocalizationValue,
        title: String.LocalizationValue,
        subtitle: String.LocalizationValue
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text(eyebrow))
                .font(.cadenza(.caption, weight: .semibold, scale: uiScale))
                .tracking(1.2)
                .foregroundStyle(.tint)

            Text(text(title))
                .font(.cadenza(30, weight: .bold, scale: uiScale))
                .fixedSize(horizontal: false, vertical: true)

            Text(text(subtitle))
                .font(.cadenza(15, scale: uiScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityFocused($pageTitleIsFocused)
    }

    private func featureRow(
        symbol: String,
        title: String.LocalizationValue,
        detail: String.LocalizationValue
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.cadenza(17, weight: .semibold, scale: uiScale))
                .foregroundStyle(.tint)
                .frame(width: CadenzaControlMetrics.squareIconFrame(
                    base: 24,
                    symbolPointSize: 17,
                    scale: uiScale,
                    padding: 4
                ))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(text(title))
                    .font(.cadenza(14, weight: .semibold, scale: uiScale))
                Text(text(detail))
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
    }

    private func choiceCard(
        symbol: String,
        title: String.LocalizationValue,
        detail: String.LocalizationValue,
        isOn: Binding<Bool>,
        accessibilityIdentifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.cadenza(22, weight: .medium, scale: uiScale))
                .foregroundStyle(.tint)
                .frame(width: CadenzaControlMetrics.squareIconFrame(
                    base: 32,
                    symbolPointSize: 22,
                    scale: uiScale,
                    padding: 4
                ))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(text(title))
                    .font(.cadenza(15, weight: .semibold, scale: uiScale))
                Text(text(detail))
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)

            Spacer(minLength: 12)

            Toggle(text(title), isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(text(title))
                .accessibilityHint(text(detail))
                .accessibilityIdentifier(accessibilityIdentifier)
        }
        .padding(15)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var microphoneAction: some View {
        switch microphoneStatus {
        case .granted:
            Toggle(
                text("Include my microphone"),
                isOn: $captureMicrophoneEnabled
            )
            .toggleStyle(.switch)
            .accessibilityIdentifier("onboarding.microphoneCapture")
        case .notDetermined:
            Button {
                requestMicrophone()
            } label: {
                permissionButtonLabel(
                    title: activePermissionAction == .microphone
                        ? text("Requesting…")
                        : text("Allow"),
                    symbol: "mic"
                )
            }
            .buttonStyle(.bordered)
            .disabled(activePermissionAction != nil)
            .accessibilityIdentifier("onboarding.microphone")
        case .denied:
            Button {
                Permissions.openMicrophoneSettings()
            } label: {
                permissionButtonLabel(
                    title: text("Open Settings"),
                    symbol: "gearshape"
                )
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("onboarding.microphone")
        }
    }

    private func permissionButtonLabel(title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func summaryChip(_ title: String, ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
            .font(.cadenza(11, weight: .medium, scale: uiScale))
            .foregroundStyle(ready ? Color.green : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.45), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(ready ? text("Ready") : text("Skipped"))
    }

    private func requestMicrophone() {
        guard appState.startupPolicy.allowsHardwareCapture,
              activePermissionAction == nil else { return }
        activePermissionAction = .microphone

        Task { @MainActor in
            let granted = await Permissions.requestMicrophone()
            await appState.checkPermissions()
            refreshPermissionStatuses()
            if granted {
                captureMicrophoneEnabled = true
                announce(text("Microphone ready"))
            }
            activePermissionAction = nil
        }
    }

    private func prepareSystemAudio() {
        guard appState.startupPolicy.allowsHardwareCapture,
              activePermissionAction == nil else { return }
        activePermissionAction = .systemAudio
        permissionError = nil

        Task { @MainActor in
            let succeeded = await appState.prepareSystemAudioCapture()
            activePermissionAction = nil
            if succeeded {
                appState.dismissRecordingError()
                announce(text("System Audio set up"))
            } else {
                permissionError = appState.recordingError
                    ?? text("Cadenza could not set up System Audio. Try again or open System Settings.")
            }
        }
    }

    private func requestScreenRecording() {
        guard appState.startupPolicy.allowsHardwareCapture,
              activePermissionAction == nil else { return }
        if screenRecordingStatus == .granted || screenRecordingRequestAttempted {
            Permissions.openScreenRecordingSettings()
            return
        }
        activePermissionAction = .screenRecording
        let granted = Permissions.requestScreenRecordingAccess()
        screenRecordingRequestAttempted = !granted
        screenRecordingStatus = granted ? .granted : Permissions.screenRecordingStatus
        activePermissionAction = nil
        if granted {
            Task { await appState.checkPermissions() }
            announce(text("Screen Recording ready"))
        }
    }

    private func requestAccessibility() {
        guard appState.startupPolicy.checksPermissions,
              activePermissionAction == nil else { return }
        if accessibilityStatus == .granted || accessibilityRequestAttempted {
            Permissions.openAccessibilitySettings()
            return
        }
        activePermissionAction = .accessibility
        let granted = Permissions.requestAccessibility()
        accessibilityRequestAttempted = !granted
        accessibilityStatus = granted ? .granted : Permissions.accessibilityStatus
        activePermissionAction = nil
        if granted {
            Task { await appState.checkPermissions() }
            announce(text("Global shortcuts ready"))
        }
    }

    private func refreshPermissionStatuses() {
        guard appState.startupPolicy.checksPermissions else {
            microphoneStatus = .notDetermined
            screenRecordingStatus = .notDetermined
            accessibilityStatus = .notDetermined
            return
        }
        microphoneStatus = Permissions.microphoneStatus
        screenRecordingStatus = Permissions.screenRecordingStatus
        accessibilityStatus = Permissions.accessibilityStatus
    }

    private func permissionStatusText(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: text("Ready")
        case .denied: text("Needs Settings")
        case .notDetermined: text("Not set up")
        }
    }

    private func announce(_ value: String) {
        NSAccessibility.post(
            element: NSApp ?? NSObject(),
            notification: .announcementRequested,
            userInfo: [
                .announcement: value,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func finish(wantsAccount: Bool) {
        onComplete(OnboardingChoices(
            meetingDetectionEnabled: meetingDetectionEnabled,
            captureMicrophoneEnabled: captureMicrophoneEnabled,
            wantsAccount: wantsAccount
        ))
    }

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: Self.table)
    }

#if DEBUG
    static var previewOverrideEnabled: Bool {
        DebugDataRoot.isActive
            && ProcessInfo.processInfo.environment[previewOverrideKey] == "1"
    }
#else
    static let previewOverrideEnabled = false
#endif
}

private struct OnboardingPanelStyle: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                }
        } else {
            content.appGlassPanel(cornerRadius: 28, accent: .accentColor)
        }
    }
}
