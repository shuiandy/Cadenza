import SwiftUI

enum MainWindowToolbarPolicy {
    static func showsPrimaryAction(
        isRecording: Bool,
        hasStatusPhase: Bool,
        allowsHardwareCapture: Bool
    ) -> Bool {
        isRecording || hasStatusPhase || allowsHardwareCapture
    }
}

struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDestination: NavigationDestination? = .allRecordings
    @State private var windowHandle = WindowHandle()
    @AppStorage("uiScale") private var uiScalePreset: UIScalePreset = .default
    @AppStorage("backgroundTheme") private var backgroundTheme: BackgroundTheme = .none
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // MARK: - Toolbar status state
    @State private var toolbarCompletionPhase: ProcessingToastPhase?
    @State private var toolbarCompletionDismissTask: Task<Void, Never>?

    private var pageTitle: String {
        if case .recordingDetail = appState.activeDestination {
            return appState.recordingDetailTitle ?? String(localized: "Recording")
        }
        let title = appState.activeDestination.title
        return title.isEmpty ? "Cadenza" : title
    }

    /// 需要出口的页面（详情页 + 全页 AI 助手）永远显示；此外只要是 `present(_:)`
    /// 进来的，也给一个返回按钮回到来路。
    private var showDetailCloseButton: Bool {
        appState.activeDestination.requiresExplicitExit || !appState.navigationReturnStack.isEmpty
    }

    private func dismissCurrentDestination() {
        // Suppress the implicit transition animation that wrapped the
        // destination switch — Settings → main was ~700ms of fade despite
        // looking like a frozen wait. Bare property writes inside a
        // `Transaction(animation: nil)` make the swap snap (2026-05-12).
        withTransaction(Transaction(animation: nil)) {
            appState.closeDetail()
        }
    }

    /// Derives the status pill phase from live AppState + local completion phase.
    private var toolbarStatusPhase: ProcessingToastPhase? {
        switch appState.recordingState {
        case .transcribing:
            return .transcribing
        case .summarizing:
            return .summarizing
        default:
            return toolbarCompletionPhase
        }
    }

    var body: some View {
        @Bindable var appState = appState

        // Product UI Scale and the system Dynamic Type category are combined
        // into the font multiplier consumed through `\.uiScale`.
        // read by the `.font(.cadenza(_:, scale: uiScale))` modifier (see `ScaledFont.swift`).
        // Two earlier approaches failed: `.scaleEffect` broke hit-testing on
        // macOS 26 (entire bottom strip unclickable), and
        // `.dynamicTypeSize(_:)` was a no-op on macOS for Cadenza's
        // hardcoded `.font(.system(size: N))` sites. The font-multiplier
        // path scales fonts and SF Symbol icons without touching layout
        // geometry, so hit-testing stays honest.
        let effectiveUIScale = CadenzaTextScale.combined(
            uiScale: uiScalePreset.scaleFactor,
            dynamicTypeSize: dynamicTypeSize
        )
        MainWorkspaceView(selectedDestination: $selectedDestination)
            .environment(\.uiScale, effectiveUIScale)
            .environment(\.glassTint, colorScheme == .dark ? backgroundTheme.darkGlassTint : backgroundTheme.lightGlassTint)
            // NavigationSplitView 在超宽窗口下不会自己撑满，HStack 跟着比窗口窄，
            // 右下角空出的那块就是透明窗口本体 —— 直接露出桌面。窄窗口正好占满，
            // 所以只在把窗口拉宽后才看得见（2026-08-07）。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AppAmbientBackground() }
        .toolbar(removing: .sidebarToggle)
            .toolbar {
                if showDetailCloseButton {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            dismissCurrentDestination()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .help("Close")
                    }
                }

                if MainWindowToolbarPolicy.showsPrimaryAction(
                    isRecording: appState.isRecording,
                    hasStatusPhase: toolbarStatusPhase != nil,
                    allowsHardwareCapture: appState.startupPolicy.allowsHardwareCapture
                ) {
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 8) {
                            // Recording status pill -- shows meeting name + elapsed time
                            if appState.isRecording {
                                ToolbarRecordingPill(
                                    meetingName: appState.currentMeetingName,
                                    statusText: appState.statusText
                                )
                                .transition(reduceMotion ? .opacity : .asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                ))
                            } else if let phase = toolbarStatusPhase {
                                // Processing / completion status pill
                                ToolbarStatusPill(
                                    phase: phase,
                                    chunksDone: appState.transcriptionChunksDone,
                                    chunksTotal: appState.transcriptionChunksTotal
                                )
                                .transition(reduceMotion ? .opacity : .asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                ))
                            }

                            // Record / Stop button
                            if appState.startupPolicy.allowsHardwareCapture {
                                if appState.isRecording {
                                    Button {
                                        appState.stopRecording()
                                    } label: {
                                        Label("Stop", systemImage: "stop.fill")
                                    }
                                    .cadenzaGlassButtonStyle()
                                    .tint(.red)
                                    .help("Stop Recording")
                                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                                } else {
                                    let starting = appState.isStartingRecording
                                    let blocked = appState.isRecordingStartBlocked
                                    Button {
                                        Task {
                                            do {
                                                try await appState.startRecording()
                                            } catch {
                                                appState.presentStartRecordingError(error)
                                            }
                                        }
                                    } label: {
                                        Label(
                                            blocked ? "Saving recording…"
                                                : (starting ? "Starting…" : "Start Recording"),
                                            systemImage: starting || blocked
                                                ? "hourglass" : "record.circle.fill"
                                        )
                                        .labelStyle(.titleAndIcon)
                                    }
                                    .cadenzaGlassButtonStyle()
                                    .tint(.red)
                                    .disabled(starting || blocked)
                                    .help(
                                        blocked
                                            ? (appState.recordingStartBlockReason ?? String(localized: "Saving recording…"))
                                            : (starting ? "Starting Recording…" : "Start Recording")
                                    )
                                }
                            }
                        }
                        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: appState.isRecording)
                        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: appState.isStartingRecording)
                        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: appState.isRecordingStartBlocked)
                        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: toolbarStatusPhase)
                    }
                }
            }
            .onChange(of: appState.recordingState) { _, newValue in
                switch newValue {
                case .transcribing, .summarizing:
                    // Live state drives toolbarStatusPhase — clear any stale completion
                    toolbarCompletionDismissTask?.cancel()
                    toolbarCompletionPhase = nil
                default:
                    break
                }
            }
            .onChange(of: appState.postProcessingCompletedToken) { _, token in
                guard token > 0 else { return }
                showToolbarCompletion(.complete)
            }
            .onChange(of: appState.recordingDiscardedReason) { _, reason in
                if let reason {
                    showToolbarCompletion(.discarded(reason))
                    appState.recordingDiscardedReason = nil
                }
            }
            .background(
                WindowChromeBridge(
                    title: pageTitle,
                    handle: windowHandle,
                    titlebarAppearsTransparent: true
                )
                    .frame(width: 0, height: 0)
            )
            .alert("API Key Required", isPresented: $appState.showAPIKeyAlert) {
                Button("Open Settings") {
                    appState.openSettings(category: .integrations)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let provider = appState.missingAPIKeyProvider {
                    Text(
                        String(
                            format: String(localized: "Add an API key for %@ in Settings. Cadenza will not use another transcription provider automatically."),
                            provider.displayName
                        )
                    )
                }
            }
            .alert("Recording Error", isPresented: Binding(
                get: { appState.recordingError != nil },
                set: { if !$0 { appState.dismissRecordingError() } }
            )) {
                if appState.recordingErrorOffersSystemAudioSettings {
                    Button("Open System Audio Settings") {
                        Permissions.openSystemAudioRecordingSettings()
                        appState.dismissRecordingError()
                    }
                }
                Button("OK", role: .cancel) {
                    appState.dismissRecordingError()
                }
            } message: {
                Text(appState.recordingError ?? "")
            }
            .task {
                await appState.setup()
            }
            .overlay {
                switch appState.profileTransitionPhase {
                case .idle:
                    EmptyView()
                case .preparing:
                    ProfileTransitionRelaunchOverlay(stage: .preparing, uiScale: effectiveUIScale)
                case .relaunching:
                    ProfileTransitionRelaunchOverlay(stage: .relaunching, uiScale: effectiveUIScale)
                case .halted:
                    ProfileTransitionHaltOverlay(uiScale: effectiveUIScale)
                }
            }
    }

    /// Blocking handoff state, shown from quiescence through relaunch.
    /// The label follows the actual phase: while preparing, nothing has
    /// been committed yet and the transition can still be refused, so it
    /// must not claim a restart is underway.
    private struct ProfileTransitionRelaunchOverlay: View {
        let stage: ProfileTransitionOverlayCopy.Stage
        let uiScale: CGFloat

        var body: some View {
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text(ProfileTransitionOverlayCopy.statusText(for: stage))
                        .font(.cadenza(14, weight: .semibold, scale: uiScale))
                }
                .padding(32)
            }
        }
    }

    /// Blocking restart-required state: a profile transition could not be
    /// classified, so the process must not keep serving data.
    private struct ProfileTransitionHaltOverlay: View {
        let uiScale: CGFloat

        var body: some View {
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle")
                        .font(.cadenza(36, scale: uiScale))
                        .foregroundStyle(.secondary)
                    Text("Restart needed")
                        .font(.cadenza(16, weight: .semibold, scale: uiScale))
                    Text("A profile change didn't finish. Quit and reopen Cadenza to continue.")
                        .font(.cadenza(13, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: MainWindowLayoutMetrics.haltMessageMaximumWidth(scale: uiScale))
                    Button(String(localized: "Quit Cadenza")) {
                        NSApp.terminate(nil)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(32)
            }
        }
    }

    private func showToolbarCompletion(_ phase: ProcessingToastPhase) {
        toolbarCompletionDismissTask?.cancel()
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.18)) {
            toolbarCompletionPhase = phase
        }
        toolbarCompletionDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                toolbarCompletionPhase = nil
            }
        }
    }
}

private struct MainWorkspaceView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(AppState.self) private var appState
    @Binding var selectedDestination: NavigationDestination?

    private var isOnAIAssistantPage: Bool {
        if case .aiAssistant = appState.activeDestination { return true }
        return false
    }

    /// Mirrors the app's recording-detail destination into a real navigation
    /// path. The root ContentView remains mounted underneath the pushed detail,
    /// preserving the recordings grid and its local scroll/selection state.
    private var recordingDetailPath: Binding<[UUID]> {
        Binding(
            get: {
                if case .recordingDetail(let recordingID) = appState.activeDestination {
                    return [recordingID]
                }
                return []
            },
            set: { path in
                if let recordingID = path.last {
                    guard appState.activeDestination != .recordingDetail(recordingID) else { return }
                    appState.openRecordingDetail(recordingID: recordingID, title: nil)
                } else if case .recordingDetail = appState.activeDestination {
                    appState.closeDetail()
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(selectedDestination: $selectedDestination)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            } detail: {
                NavigationStack(path: recordingDetailPath) {
                    ContentView()
                        // 四周均匀 10pt：和右侧 AI 面板的 .padding(.vertical, 10) 对齐，
                        // 少了 top 的话内容面板紧贴 toolbar、AI 面板却留缝，两边不齐。
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .navigationDestination(for: UUID.self) { recordingID in
                            RecordingDetailPage(recordingID: recordingID)
                                .padding(10)
                                // 和上面的 root 对称：玻璃面板的大小就是这个 frame 的大小，
                                // 少了它面板会按内容收缩，右下角露出窗口本体——而窗口在
                                // macOS 26 下是透明的，露出来的直接是桌面（2026-08-07）。
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .navigationBarBackButtonHidden(true)
                        }
                }
                // Top-anchored transient capsule for export feedback
                // (and any future success/failure pings). Mounted on
                // the detail pane only so the sidebar stays
                // unobstructed; lives at alignment .top so it does not
                // collide with the bottomTrailing FloatingAIChatButton.
                .overlay(alignment: .top) {
                    ToastOverlay()
                }
            }
            .navigationSplitViewStyle(.balanced)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 浮动按钮挂在整个 split view 之上，不能挂在 NavigationStack 上：
            // push 上来的详情页有自己的呈现层，会盖住 NavigationStack 的 overlay。
            // 面板还是玻璃时按钮能隐约透出来，换成不透明实心面板后就彻底看不见了
            // （2026-08-07：日志确认按钮一直 mounted，是被遮住而不是没渲染）。
            .overlay(alignment: .bottomTrailing) {
                // Hide on the AI assistant page — the page itself is the assistant.
                if !isOnAIAssistantPage {
                    FloatingAIChatButton(
                        placeholder: "Ask about your recordings...",
                        isProminent: true
                    )
                    .padding(.trailing, 28)
                    .padding(.bottom, 16)
                }
            }

            // In-window AI chat sidebar — a NavigationSplitView SIBLING (NOT a ContentView
            // overlay). Its streaming @State lives in this subtree and never touches the
            // recordings grid's `overlayPreferenceValue(CardFrameKey)` chain, so the 0.1s
            // streaming commits no longer re-run the grid's anchorPreference reduction +
            // re-measure (the old main-thread hang; see ARCHITECTURE §12.2). Native
            // `.move(edge:.trailing)` gives the Craft-style slide an NSPanel never could.
            if appState.floatingChatController.isExpanded && !isOnAIAssistantPage {
                FloatingChatPanelRoot(controller: appState.floatingChatController)
                    .padding(.trailing, 10)
                    .padding(.vertical, 10)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.84), value: appState.floatingChatController.isExpanded)
        // 两个方向按「值」收敛，不用同步标志位。标志位是在闭包结尾就置回 false 的，
        // 而 onChange 是下一个 update 周期才跑——跨周期根本挡不住回声，于是
        // `present(.aiAssistant())` 刚压进返回栈就被回声里的 `navigate` 清空，
        // 全页 AI 助手的返回按钮永远不出现（2026-08-07）。
        .onChange(of: selectedDestination) { _, newValue in
            guard let destination = newValue else { return }
            // 这次变化是 activeDestination 同步出去的回声，不是用户点了 sidebar。
            guard !appState.activeDestination.isSidebarEcho(of: destination) else { return }
            appState.navigate(to: destination)
        }
        .onChange(of: appState.activeDestination) { _, newValue in
            guard let sidebarDest = newValue.sidebarDestination,
                  selectedDestination != sidebarDest else { return }
            selectedDestination = sidebarDest
        }
    }
}

private final class WindowHandle {
    weak var window: NSWindow?
}

// MARK: - Accessibility Layout Metrics

/// Geometry shared by the main-window chrome and its folder editor. Cadenza's
/// numeric fonts can reach a 3.105x effective scale, so fixed 18/24/32pt
/// containers are not safe for SF Symbols or single-line labels.
enum MainWindowLayoutMetrics {
    private static func safeScale(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 1
    }

    static func sidebarControlDimension(scale: CGFloat) -> CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 32,
            symbolPointSize: 15,
            scale: safeScale(scale)
        )
    }

    static func sidebarIconColumnWidth(pointSize: CGFloat, scale: CGFloat) -> CGFloat {
        let normalized = safeScale(scale)
        let symbolWidth = CadenzaControlMetrics.squareIconFrame(
            base: 18,
            symbolPointSize: pointSize,
            scale: normalized,
            padding: 0
        )
        // Wide badge/drive symbols exceed their nominal square extent by a
        // couple of points at accessibility sizes. Preserve the 18pt default
        // column, then add measured breathing room only as scaling increases.
        let breathingRoom = ceil(min(4, max(0, (normalized - 1) * 2)))
        return max(18, symbolWidth + breathingRoom)
    }

    static func folderCloseControlDimension(scale: CGFloat) -> CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 24,
            symbolPointSize: 11,
            scale: safeScale(scale),
            padding: 10
        )
    }

    static func folderSheetWidth(scale: CGFloat) -> CGFloat {
        let growth = 400 + 80 * (safeScale(scale) - 1)
        return ceil(min(max(growth, 400), 560))
    }

    static func folderColorPickerWidth(scale: CGFloat) -> CGFloat {
        let growth = 200 + 60 * (safeScale(scale) - 1)
        return ceil(min(max(growth, 200), 360))
    }

    static func folderIconCellDimension(scale: CGFloat) -> CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: 36,
            symbolPointSize: 15,
            scale: safeScale(scale)
        )
    }

    static func folderIconPickerSize(scale: CGFloat) -> CGSize {
        let normalized = safeScale(scale)
        return CGSize(
            width: ceil(min(max(370 + 70 * (normalized - 1), 370), 500)),
            height: ceil(min(max(420 + 50 * (normalized - 1), 420), 525))
        )
    }

    static func toolbarStatusMaximumWidth(scale: CGFloat) -> CGFloat {
        ceil(min(max(220 + 48 * (safeScale(scale) - 1), 220), 320))
    }

    static func toolbarRecordingMaximumWidth(scale: CGFloat) -> CGFloat {
        ceil(min(max(240 + 48 * (safeScale(scale) - 1), 240), 340))
    }

    static func toolbarLineLimit(scale: CGFloat) -> Int {
        safeScale(scale) >= CadenzaTextScale.factor(.accessibility1) ? 2 : 1
    }

    static func haltMessageMaximumWidth(scale: CGFloat) -> CGFloat {
        ceil(min(max(360 + 60 * (safeScale(scale) - 1), 360), 520))
    }
}

// MARK: - Toolbar Status Pill

private struct ToolbarStatusPill: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let phase: ProcessingToastPhase
    var chunksDone: Int = 0
    var chunksTotal: Int = 0

    var body: some View {
        HStack(spacing: 6) {
            if phase == .transcribing || phase == .summarizing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            } else if phase == .complete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.green)
            } else {
                Image(systemName: phase.symbol)
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
                    .foregroundStyle(phase.tint)
            }

            Text(pillLabel)
                .font(.cadenza(12, weight: .semibold, scale: uiScale))
                .foregroundStyle(.primary)
                .lineLimit(MainWindowLayoutMetrics.toolbarLineLimit(scale: uiScale))
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .cadenzaGlass(in: .capsule)
        .frame(
            maxWidth: MainWindowLayoutMetrics.toolbarStatusMaximumWidth(scale: uiScale),
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
    }

    private var pillLabel: String {
        if case .transcribing = phase, chunksTotal > 1, chunksDone > 0 {
            let pct = min(100, chunksDone * 100 / chunksTotal)
            return String(localized: "Transcribing \(pct)%")
        }
        return phase.title
    }
}

private struct ToolbarRecordingPill: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let meetingName: String?
    let statusText: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle.fill")
                .font(.cadenza(12, weight: .semibold, scale: uiScale))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)

            VStack(alignment: .leading, spacing: 0) {
                Text(meetingName ?? String(localized: "Recording"))
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.primary)
                    .lineLimit(MainWindowLayoutMetrics.toolbarLineLimit(scale: uiScale))
                    .truncationMode(.tail)
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.cadenza(10, weight: .regular, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .cadenzaGlass(in: .capsule)
        .frame(
            maxWidth: MainWindowLayoutMetrics.toolbarRecordingMaximumWidth(scale: uiScale),
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
    }
}

/// Keeps title-bar chrome settings in sync with NSWindow/NSToolbar lifecycle changes.
private struct WindowChromeBridge: NSViewRepresentable {
    let title: String
    let handle: WindowHandle
    let titlebarAppearsTransparent: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            title: title,
            handle: handle,
            titlebarAppearsTransparent: titlebarAppearsTransparent
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.title = title
        context.coordinator.titlebarAppearsTransparent = titlebarAppearsTransparent
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
            context.coordinator.applyChromeIfPossible()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var title: String
        var titlebarAppearsTransparent: Bool

        private weak var handle: WindowHandle?
        private weak var window: NSWindow?
        private var didBecomeKeyObserver: NSObjectProtocol?

        init(title: String, handle: WindowHandle, titlebarAppearsTransparent: Bool) {
            self.title = title
            self.titlebarAppearsTransparent = titlebarAppearsTransparent
            self.handle = handle
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else { return }

            if window !== newWindow {
                removeObservers()
                window = newWindow
                handle?.window = newWindow

                didBecomeKeyObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: newWindow,
                    queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.applyChromeIfPossible()
                    }
                }
            }

            applyChromeIfPossible()
            DispatchQueue.main.async { [weak self] in self?.applyChromeIfPossible() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.applyChromeIfPossible() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.applyChromeIfPossible() }
        }

        func applyChromeIfPossible() {
            guard let window else { return }
            window.isMovableByWindowBackground = false
            window.toolbarStyle = .unified
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = titlebarAppearsTransparent
            window.titlebarSeparatorStyle = .none
            window.title = title
        }

        func detach() {
            removeObservers()
            window = nil
            handle?.window = nil
        }

        private func removeObservers() {
            if let observer = didBecomeKeyObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            didBecomeKeyObserver = nil
        }
    }
}

// MARK: - Sidebar

private struct SidebarChromeActivityModifier: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.opacity(appearsActive ? 1 : 0.5)
    }
}

private extension View {
    func sidebarChromeActivity() -> some View {
        modifier(SidebarChromeActivityModifier())
    }
}

private struct SidebarView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(AppState.self) private var appState
    @Binding var selectedDestination: NavigationDestination?

    @State private var folderToDelete: FolderDTO?
    @State private var activeFolderSheet: FolderSheetMode?


    private var isSettingsSidebarMode: Bool {
        appState.activeDestination == .settings
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isSettingsSidebarMode {
                AccountBanner()
                    .sidebarChromeActivity()
                Divider().opacity(0.4)
            }
            // Settings mode has no sidebar back affordance — the toolbar's
            // `xmark` close button (see MainWindow.body.toolbar) is the
            // canonical exit, matching the recording-detail close pattern.

            List(selection: $selectedDestination) {
                if isSettingsSidebarMode {
                    settingsSidebarContent
                } else {
                    librarySidebarContent
                }
            }
            .listStyle(.sidebar)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSettingsSidebarMode)

            if !isSettingsSidebarMode {
                Divider()
                sidebarBottomBar
                    .sidebarChromeActivity()
            }
        }
        .alert("Delete Folder?", isPresented: Binding(
            get: { folderToDelete != nil },
            set: { if !$0 { folderToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                folderToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let folder = folderToDelete {
                    appState.deleteFolder(folderID: folder.id)
                    if case .folder(let selectedID) = selectedDestination, selectedID == folder.id {
                        selectedDestination = .allRecordings
                    }
                }
                folderToDelete = nil
            }
        } message: {
            Text("Recordings in this folder will not be deleted, only un-assigned.")
        }
        .sheet(item: $activeFolderSheet) { mode in
            FolderFormSheet(mode: mode) {
                activeFolderSheet = nil
            }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportRecordingSheet()
                .environment(appState)
        }
    }

    @ViewBuilder
    private var librarySidebarContent: some View {
        Section("Library") {
            Label("All Recordings", systemImage: "waveform.circle")
                .tag(NavigationDestination.allRecordings)
            Label("Calendar", systemImage: "calendar")
                .tag(NavigationDestination.calendar)
            Label("Recaps", systemImage: "calendar.badge.clock")
                .tag(NavigationDestination.recaps)
            Label("AI Assistant", systemImage: "bubble.left.and.text.bubble.right")
                .tag(NavigationDestination.aiAssistant())
        }

        let smartFolders = appState.sidebarSmartFolders
        if !smartFolders.isEmpty {
            Section("Smart Folders") {
                ForEach(smartFolders) { folder in
                    smartFolderRow(folder)
                }
            }
        }

        Section("Folders") {
            ForEach(appState.folders) { folder in
                folderRow(folder)
            }

            Button {
                activeFolderSheet = .create
            } label: {
                Label("New Folder", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.cadenzaPlain)
        }


    }

    private var sidebarBottomBar: some View {
        HStack(spacing: 0) {
            sidebarBottomButton(
                title: "Trash",
                icon: "trash",
                destination: .trash
            )

            Spacer()

            sidebarImportButton

            sidebarBottomButton(
                title: "Settings",
                icon: "gearshape",
                destination: .settings
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @State private var importButtonHovered = false
    @State private var showImportSheet = false

    private var sidebarImportButton: some View {
        let controlSize = MainWindowLayoutMetrics.sidebarControlDimension(scale: uiScale)
        return Button {
            showImportSheet = true
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.cadenza(15, weight: .medium, scale: uiScale))
                .foregroundStyle(.secondary)
                .frame(width: controlSize, height: controlSize)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(importButtonHovered ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.cadenzaPlain)
        .contentShape(Rectangle())
        .onHover { importButtonHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: importButtonHovered)
        .help("Import Audio Files (⇧⌘I)")
        .accessibilityLabel("Import Audio Files")
    }

    @ViewBuilder
    private func sidebarBottomButton(
        title: LocalizedStringKey,
        icon: String,
        destination: NavigationDestination,
        badge: Int = 0
    ) -> some View {
        let isActive = selectedDestination == destination
        let controlSize = MainWindowLayoutMetrics.sidebarControlDimension(scale: uiScale)

        Button {
            selectedDestination = destination
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.cadenza(15, weight: .medium, scale: uiScale))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .frame(width: controlSize, height: controlSize)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isActive ? Color.accentColor.opacity(0.15) : .clear)
                    )

                if badge > 0 {
                    Text("\(badge)")
                        .font(.cadenza(9, weight: .bold, scale: uiScale))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.red))
                        .offset(x: 6, y: -4)
                }
            }
        }
        .buttonStyle(.cadenzaPlain)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.15), value: isActive)
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityValue(isActive ? Text("Selected") : Text("Not selected"))
    }

    @ViewBuilder
    private var settingsSidebarContent: some View {
        Section("Settings") {
            ForEach(SettingsCategory.allCases) { category in
                settingsCategoryRow(category)
            }
        }
    }

    private func settingsCategoryRow(_ category: SettingsCategory) -> some View {
        let isActive = appState.selectedSettingsCategory == category

        return Button {
            appState.selectedSettingsCategory = category
        } label: {
            Label(category.title, systemImage: category.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Must be inside the label: .plain buttons hit-test the
                // label's content shape, so an outer modifier leaves the
                // trailing area unclickable.
                .contentShape(Rectangle())
        }
            .buttonStyle(.cadenzaPlain)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.2) : .clear)
                    .padding(.horizontal, 2)
            )
            .accessibilityValue(isActive ? Text("Selected") : Text("Not selected"))
    }

    private func smartFolderRow(_ folder: SmartFolderDTO) -> some View {
        HStack(spacing: 8) {
            Image(systemName: folder.icon)
                .font(.cadenza(13, weight: .medium, scale: uiScale))
                .foregroundStyle(folderColor(folder.iconColor))
                .frame(
                    width: MainWindowLayoutMetrics.sidebarIconColumnWidth(
                        pointSize: 13,
                        scale: uiScale
                    )
                )

            Text(folder.title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(folder.recordingCount)")
                .font(.cadenza(.caption, scale: uiScale))
                .foregroundStyle(.secondary)
        }
        .tag(NavigationDestination.smartFolder(folder.id))
        .contextMenu {
            Button {
                appState.saveSmartFolderAsFolder(smartFolderID: folder.id)
            } label: {
                Label("Save as Folder", systemImage: "folder.badge.plus")
            }
        }
    }

    private func folderRow(_ folder: FolderDTO) -> some View {
        HStack(spacing: 8) {
            FolderIconView(icon: folder.icon, color: folderColor(folder.iconColor), size: 16)
                .frame(
                    width: MainWindowLayoutMetrics.sidebarIconColumnWidth(
                        pointSize: 12,
                        scale: uiScale
                    )
                )

            Text(folder.name)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(folder.recordingCount)")
                .font(.cadenza(.caption, scale: uiScale))
                .foregroundStyle(.secondary)
        }
        .tag(NavigationDestination.folder(folder.id))
        .contextMenu {
            Button {
                activeFolderSheet = .edit(folder)
            } label: {
                Label("Edit...", systemImage: "pencil")
            }

            Divider()

            Menu("Sort By") {
                Picker("", selection: folderSortSelectionBinding(folder.id)) {
                    Text("Date (Newest)").tag("dateNewest")
                    Text("Date (Oldest)").tag("dateOldest")
                    Text("Name (A-Z)").tag("nameAZ")
                    Text("Name (Z-A)").tag("nameZA")
                }
                .labelsHidden()
                .pickerStyle(.inline)
            }

            Divider()

            Button(role: .destructive) {
                folderToDelete = folder
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func folderSortSelectionBinding(_ folderID: UUID) -> Binding<String> {
        Binding(
            get: {
                UserDefaults.standard.string(forKey: ActiveProfileDefaults.key("folderSort.\(folderID)")) ?? "dateNewest"
            },
            set: { key in
                UserDefaults.standard.set(key, forKey: ActiveProfileDefaults.key("folderSort.\(folderID)"))
            }
        )
    }

    private func folderColor(_ rawValue: String) -> Color {
        CalendarColorOption(rawValue: rawValue)?.color ?? .secondary
    }
}

// MARK: - Folder Sheet

enum FolderSheetMode: Identifiable {
    case create
    case edit(FolderDTO)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let folder):
            return folder.id.uuidString
        }
    }
}

struct FolderFormSheet: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let mode: FolderSheetMode
    let onDismiss: () -> Void

    @Environment(AppState.self) private var appState

    @State private var name = ""
    @State private var icon = "folder"
    @State private var iconColor = ""
    @State private var showIconPicker = false
    @State private var showColorPicker = false

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private var sheetWidth: CGFloat {
        MainWindowLayoutMetrics.folderSheetWidth(scale: uiScale)
    }

    private var closeControlSize: CGFloat {
        MainWindowLayoutMetrics.folderCloseControlDimension(scale: uiScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — title + close button
            HStack {
                Text(isCreate ? String(localized: "New Folder") : String(localized: "Edit Folder"))
                    .font(.cadenza(.title2, weight: .semibold, scale: uiScale))

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.cadenza(11, weight: .bold, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .frame(width: closeControlSize, height: closeControlSize)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.cadenzaPlain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Content — single card with rows (Craft-style)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                // Title row
                GridRow {
                    Text("Title")
                        .font(.cadenza(14, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    TextField("Folder name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.cadenza(14, scale: uiScale))
                }
                .padding(.vertical, 12)

                Divider()
                    .opacity(0.32)
                    .gridCellColumns(2)

                // Icon row
                GridRow {
                    Text("Icon")
                        .font(.cadenza(14, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            showIconPicker.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: icon)
                                    .font(.cadenza(16, scale: uiScale))
                                    .foregroundStyle(selectedColor)

                                Image(systemName: "chevron.right")
                                    .font(.cadenza(11, weight: .semibold, scale: uiScale))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.cadenzaPlain)
                        .popover(isPresented: $showIconPicker) {
                            FolderIconPicker(selection: $icon)
                        }
                    }
                }
                .padding(.vertical, 10)

                Divider()
                    .opacity(0.32)
                    .gridCellColumns(2)

                // Color row
                GridRow {
                    Text("Color")
                        .font(.cadenza(14, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            showColorPicker.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(selectedColor)
                                    .frame(width: 16, height: 16)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                                    }

                                Image(systemName: "chevron.right")
                                    .font(.cadenza(11, weight: .semibold, scale: uiScale))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.cadenzaPlain)
                        .popover(isPresented: $showColorPicker) {
                            FolderColorPicker(selection: $iconColor)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 14)
            .appGlassPanel(cornerRadius: 14, accent: .accentColor)
            .padding(.horizontal, 20)

            Spacer(minLength: 0)

            // Bottom action button
            Button(action: save) {
                Text(isCreate ? String(localized: "Create") : String(localized: "Update"))
                    .font(.cadenza(14, weight: .medium, scale: uiScale))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: sheetWidth)
        .frame(minHeight: 280)
        .onAppear {
            if case .edit(let folder) = mode {
                name = folder.name
                icon = folder.icon
                iconColor = folder.iconColor
            }
        }
    }

    private var selectedColor: Color {
        if iconColor.isEmpty {
            return .secondary
        }
        return CalendarColorOption(rawValue: iconColor)?.color ?? .secondary
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch mode {
        case .create:
            appState.createFolder(name: trimmed, icon: icon, iconColor: iconColor)
        case .edit(let folder):
            appState.updateFolder(folderID: folder.id, name: trimmed, icon: icon, iconColor: iconColor)
        }

        onDismiss()
    }
}

// MARK: - Folder Color Picker

private struct FolderColorPicker: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    private struct ColorItem: Identifiable {
        let id: String
        let label: String
        let color: Color
    }

    private var colorItems: [ColorItem] {
        var items = [ColorItem(id: "__default__", label: String(localized: "Default"), color: .secondary.opacity(0.35))]
        for option in CalendarColorOption.allCases {
            items.append(ColorItem(id: option.rawValue, label: option.localizedName, color: option.color))
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(colorItems) { item in
                colorRow(item)
            }
        }
        .padding(.vertical, 4)
        .frame(width: MainWindowLayoutMetrics.folderColorPickerWidth(scale: uiScale))
    }

    private func colorRow(_ item: ColorItem) -> some View {
        let value = item.id == "__default__" ? "" : item.id
        return Button {
            selection = value
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(item.color)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    }

                Text(item.label)
                    .font(.cadenza(13, scale: uiScale))
                    .foregroundStyle(.primary)

                Spacer()

                if selection == value {
                    Image(systemName: "checkmark")
                        .font(.cadenza(12, weight: .semibold, scale: uiScale))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.cadenzaPlain)
    }
}

// MARK: - Folder Icon View

struct FolderIconView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let icon: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: icon)
            .font(.cadenza(size * 0.75, scale: uiScale))
            .foregroundStyle(color)
    }
}

// MARK: - SF Symbol Icon Picker

struct FolderIconPicker: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private static var allIcons: [(name: String, symbols: [String])] { [
        (String(localized: "Files & Folders"), [
            "folder", "folder.fill", "folder.badge.plus", "folder.badge.gear",
            "doc", "doc.fill", "doc.text", "doc.text.fill",
            "doc.on.doc", "doc.plaintext", "doc.richtext", "doc.append",
            "note.text", "list.clipboard", "list.bullet.clipboard",
            "archivebox", "archivebox.fill", "tray", "tray.full", "tray.2",
            "externaldrive", "internaldrive"
        ]),
        (String(localized: "Communication"), [
            "envelope", "envelope.fill", "envelope.open", "paperplane", "paperplane.fill",
            "bubble.left", "bubble.right", "bubble.left.and.bubble.right",
            "phone", "phone.fill", "video", "video.fill",
            "megaphone", "megaphone.fill", "bell", "bell.fill",
            "mic", "mic.fill", "speaker.wave.2", "speaker.wave.2.fill"
        ]),
        (String(localized: "Objects"), [
            "pencil", "pencil.line", "eraser", "paintbrush", "paintbrush.fill",
            "scissors", "paperclip", "link", "pin", "pin.fill",
            "mappin", "flag", "flag.fill", "bookmark", "bookmark.fill",
            "tag", "tag.fill", "camera", "camera.fill",
            "book", "book.fill", "books.vertical", "books.vertical.fill",
            "newspaper", "graduationcap", "backpack", "briefcase", "briefcase.fill",
            "suitcase", "suitcase.fill"
        ]),
        (String(localized: "Devices & Tools"), [
            "desktopcomputer", "laptopcomputer", "iphone", "ipad",
            "keyboard", "computermouse", "printer", "scanner",
            "network", "wifi", "antenna.radiowaves.left.and.right",
            "externaldrive.connected.to.line.below",
            "wrench", "wrench.and.screwdriver", "hammer", "gearshape", "gearshape.fill",
            "gearshape.2", "slider.horizontal.3", "tuningfork"
        ]),
        (String(localized: "Symbols"), [
            "star", "star.fill", "heart", "heart.fill",
            "bolt", "bolt.fill", "flame", "flame.fill",
            "sparkles", "wand.and.stars",
            "lightbulb", "lightbulb.fill", "power",
            "lock", "lock.fill", "key", "key.fill",
            "shield", "shield.fill", "checkmark.shield",
            "eye", "eye.fill", "hand.raised", "hand.thumbsup"
        ]),
        (String(localized: "Shapes & Misc"), [
            "circle", "circle.fill", "square", "square.fill",
            "triangle", "triangle.fill", "diamond", "diamond.fill",
            "hexagon", "hexagon.fill", "seal", "seal.fill",
            "rosette", "crown", "crown.fill",
            "atom", "cube", "cube.fill",
            "target", "scope", "location", "location.fill",
            "globe", "globe.americas", "building", "building.2", "house", "house.fill"
        ]),
        (String(localized: "Nature & Weather"), [
            "sun.max", "sun.max.fill", "moon", "moon.fill",
            "cloud", "cloud.fill", "cloud.rain", "snowflake",
            "wind", "tornado", "rainbow",
            "leaf", "leaf.fill", "tree", "tree.fill",
            "mountain.2", "water.waves", "drop", "drop.fill",
            "flame.fill", "pawprint", "pawprint.fill",
            "hare", "tortoise", "bird", "fish", "ant"
        ]),
        (String(localized: "People & Activities"), [
            "person", "person.fill", "person.2", "person.2.fill",
            "person.3", "figure.run", "figure.walk",
            "sportscourt", "trophy", "trophy.fill",
            "medal", "medal.fill", "rosette",
            "music.note", "music.note.list", "guitars",
            "film", "theatermasks", "paintpalette", "paintpalette.fill",
            "gamecontroller", "gamecontroller.fill", "puzzlepiece", "puzzlepiece.fill",
            "cup.and.saucer", "cup.and.saucer.fill", "fork.knife", "cart", "cart.fill"
        ])
    ] }

    private var filteredIcons: [(name: String, symbols: [String])] {
        if searchText.isEmpty {
            return Self.allIcons
        }
        let query = searchText.lowercased()
        return Self.allIcons.compactMap { category in
            let matched = category.symbols.filter { $0.lowercased().contains(query) }
            return matched.isEmpty ? nil : (name: category.name, symbols: matched)
        }
    }

    private var cellSize: CGFloat {
        MainWindowLayoutMetrics.folderIconCellDimension(scale: uiScale)
    }

    private var pickerSize: CGSize {
        MainWindowLayoutMetrics.folderIconPickerSize(scale: uiScale)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                TextField("Search icons", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.cadenza(13, scale: uiScale))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Icon grid
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filteredIcons.enumerated()), id: \.offset) { _, category in
                        Text(category.name)
                            .font(.cadenza(11, weight: .semibold, scale: uiScale))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 4)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: cellSize, maximum: cellSize), spacing: 2)],
                            spacing: 2
                        ) {
                            ForEach(category.symbols, id: \.self) { symbol in
                                Button {
                                    selection = symbol
                                    dismiss()
                                } label: {
                                    Image(systemName: symbol)
                                        .font(.cadenza(15, scale: uiScale))
                                        .foregroundStyle(selection == symbol ? .primary : .secondary)
                                        .frame(width: cellSize, height: cellSize)
                                        .background(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(selection == symbol ? Color.accentColor.opacity(0.2) : .clear)
                                        )
                                }
                                .buttonStyle(.cadenzaPlain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: pickerSize.width, height: pickerSize.height)
    }
}

// MARK: - Sidebar Account Banner

private struct AccountBanner: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    private var auth: CadenzaAuthService { appState.cadenzaAuth }

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(primaryText)
                        .font(.cadenza(13, weight: .semibold, scale: uiScale))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(secondaryText)
                        .font(.cadenza(11, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                trailingAccessory
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.cadenzaPlain)
        .disabled(auth.sessionState == .signingIn)
        .onHover { isHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .help(helpText)
    }

    @ViewBuilder
    private var avatar: some View {
        let size: CGFloat = 28
        Group {
            if let url = auth.currentUser?.pictureURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        fallbackAvatar(size: size)
                    }
                }
            } else {
                fallbackAvatar(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.secondary.opacity(0.25), lineWidth: 0.5))
    }

    private func fallbackAvatar(size: CGFloat) -> some View {
        Image(systemName: "person.crop.circle.fill")
            // Avatar artwork is a fixed preview, not text. Scaling a 28pt SF
            // Symbol to 87pt inside a 28pt image frame only crops the glyph.
            .font(.cadenza(size, scale: min(uiScale, 1)))
            .foregroundStyle(.secondary)
    }

    private var primaryText: String {
        switch auth.sessionState {
        case .signedIn:
            return auth.currentUser?.displayName ?? String(localized: "Cadenza Account")
        case .signingIn:
            return String(localized: "Signing in…")
        case .expired:
            return String(localized: "Session expired")
        case .signedOut:
            return String(localized: "Sign in to Cadenza")
        }
    }

    private var secondaryText: String {
        switch auth.sessionState {
        case .signedIn:
            return auth.currentUser?.email ?? ""
        case .signingIn:
            return String(localized: "Waiting for browser…")
        case .expired:
            return String(localized: "Tap to sign in again")
        case .signedOut:
            return String(localized: "Sign in to sync transcripts and summaries")
        }
    }

    private var helpText: String {
        switch auth.sessionState {
        case .signedIn: String(localized: "Manage account")
        case .signingIn: String(localized: "Signing in…")
        case .expired:  String(localized: "Sign in again")
        case .signedOut: String(localized: "Sign in with Google")
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        switch auth.sessionState {
        case .signingIn:
            ProgressView().controlSize(.small)
        case .expired:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.cadenza(11, scale: uiScale))
                .foregroundStyle(.orange)
        case .signedOut:
            Image(systemName: "arrow.right.circle")
                .font(.cadenza(13, scale: uiScale))
                .foregroundStyle(.secondary)
        case .signedIn:
            Image(systemName: "chevron.right")
                .font(.cadenza(10, weight: .semibold, scale: uiScale))
                .foregroundStyle(.tertiary)
        }
    }

    private func handleTap() {
        switch auth.sessionState {
        case .signedIn:
            appState.openSettings(category: .integrations)
        case .expired:
            Task {
                await appState.signInToCadenza()
            }
        case .signedOut:
            // Unbound profiles route through the Profiles login flow, which
            // decides binding; bound profiles re-auth in place.
            appState.presentSignIn()
        case .signingIn:
            break
        }
    }
}

/// Localized copy for the transition overlay; locale-injectable.
enum ProfileTransitionOverlayCopy {
    enum Stage {
        case preparing
        case relaunching
    }

    static func statusText(for stage: Stage, locale: Locale? = nil) -> String {
        switch stage {
        case .preparing:
            return LocalizedBundle.string("Pausing background work…", locale: locale)
        case .relaunching:
            return LocalizedBundle.string("Restarting…", locale: locale)
        }
    }
}

#Preview {
    MainWindow()
        .environment(AppState())
        .frame(width: 1080, height: 720)
}
