import AppKit
import AVFoundation
import SwiftUI
import os.log

private let notchLogger = Logger(subsystem: "com.cadenza", category: "NotchOverlay")

// MARK: - Independent Hosting Root

/// Applies the same product-scale + Dynamic Type bridge used by `MainWindow`
/// to SwiftUI trees hosted in standalone AppKit panels.
///
/// Each overlay is its own `NSHostingView`, so it does not inherit the main
/// window's environment. Keeping this bridge at the hosting root prevents the
/// regular overlay, notch overlay, and microphone prompt from silently falling
/// back to the default 1.0 font scale.
@MainActor
struct RecordingOverlayRoot<Content: View>: View {
    @AppStorage("uiScale") private var uiScalePreset: UIScalePreset = .default
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let productScaleOverride: CGFloat?
    private let onScaleChange: ((CGFloat) -> Void)?
    private let content: Content

    init(
        productScaleOverride: CGFloat? = nil,
        onScaleChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.productScaleOverride = productScaleOverride
        self.onScaleChange = onScaleChange
        self.content = content()
    }

    private var effectiveScale: CGFloat {
        CadenzaTextScale.combined(
            uiScale: productScaleOverride ?? uiScalePreset.scaleFactor,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    var body: some View {
        content
            .environment(\.uiScale, effectiveScale)
            .onAppear {
                onScaleChange?(effectiveScale)
            }
            .onChange(of: effectiveScale) { _, newScale in
                onScaleChange?(newScale)
            }
    }
}

// MARK: - Overlay Layout Metrics

enum RecordingOverlayLayoutMetrics {
    /// Fixed button frames must grow with their SF Symbol fonts. Growing by the
    /// font delta preserves the original padding without turning every control
    /// into a 3x-sized target at the largest accessibility category.
    static func controlDimension(base: CGFloat, fontSize: CGFloat, scale: CGFloat) -> CGFloat {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        return ceil(max(base, base + fontSize * (safeScale - 1)))
    }

    static func iconDimension(base: CGFloat, fontSize: CGFloat, scale: CGFloat) -> CGFloat {
        CadenzaControlMetrics.squareIconFrame(
            base: base,
            symbolPointSize: fontSize,
            scale: scale,
            padding: 0
        )
    }

    static func expandedOverlayWidth(scale: CGFloat) -> CGFloat {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        return ceil(360 * min(max(safeScale, 1), 1.75))
    }

    /// Keeps an unbounded meeting title from consuming the action controls'
    /// horizontal space. The title still grows with the expanded surface, but
    /// truncates before it can force microphone, pause, or stop offscreen.
    static func compactStatusMaximumWidth(scale: CGFloat) -> CGFloat {
        let expandedWidth = expandedOverlayWidth(scale: scale)
        return ceil(min(240, max(120, expandedWidth * 0.38)))
    }

    static func regularPanelSize(scale: CGFloat, availableSize: NSSize?) -> NSSize {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        var size = NSSize(
            width: max(400, expandedOverlayWidth(scale: safeScale) + 40),
            height: max(500, 500 + min(max(safeScale - 1, 0), 1.5) * 80)
        )
        if let availableSize {
            size.width = min(size.width, max(320, availableSize.width - 24))
            size.height = min(size.height, max(320, availableSize.height - 24))
        }
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    static func sanitizedFittingSize(_ fittingSize: NSSize, availableSize: NSSize?) -> NSSize {
        var size = NSSize(
            width: max(1, fittingSize.width.isFinite ? fittingSize.width : 1),
            height: max(1, fittingSize.height.isFinite ? fittingSize.height : 1)
        )
        if let availableSize {
            size.width = min(size.width, max(1, availableSize.width - 24))
            size.height = min(size.height, max(1, availableSize.height - 24))
        }
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    static func clampedFrame(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        guard frame.width.isFinite,
              frame.height.isFinite,
              visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return frame
        }

        let width = min(max(1, frame.width), visibleFrame.width)
        let height = min(max(1, frame.height), visibleFrame.height)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let origin = NSPoint(
            x: min(max(frame.minX, visibleFrame.minX), maxX),
            y: min(max(frame.minY, visibleFrame.minY), maxY)
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }
}

/// Reflows the compact recording identity and its controls when Dynamic Type
/// reaches an accessibility category. Actions receive their own row so their
/// hit targets never compete with a long meeting title for horizontal space.
struct RecordingCompactBarLayout<Leading: View, Duration: View, Status: View, Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let showsActions: Bool
    private let leading: Leading
    private let duration: Duration
    private let status: Status
    private let actions: Actions

    init(
        showsActions: Bool,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder duration: () -> Duration,
        @ViewBuilder status: () -> Status,
        @ViewBuilder actions: () -> Actions
    ) {
        self.showsActions = showsActions
        self.leading = leading()
        self.duration = duration()
        self.status = status()
        self.actions = actions()
    }

    var body: some View {
        if showsActions && dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    leading
                        .fixedSize()
                    duration
                        .fixedSize()
                    status
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    actions
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
        } else {
            HStack(spacing: 10) {
                leading
                    .fixedSize()
                duration
                    .fixedSize()
                status
                actions
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }
}

// MARK: - Overlay Circle Button (with hover highlight)

struct OverlayCircleButton: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let icon: String
    var tint: Color = .primary
    var disabled: Bool = false
    var help: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let controlSize = RecordingOverlayLayoutMetrics.controlDimension(
            base: 28,
            fontSize: 12,
            scale: uiScale
        )
        Button(action: action) {
            Image(systemName: icon)
                .font(.cadenza(12, weight: .semibold, scale: uiScale))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : tint)
                .frame(width: controlSize, height: controlSize)
                .background(
                    Circle().fill(isHovered ? Color.primary.opacity(0.15) : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.cadenzaPlain(in: Circle()))
        .disabled(disabled)
        .help(help ?? "")
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Gradient Border

/// Static recording border. Keep this non-animated: the overlay is visible for
/// long recordings and per-frame gradients can saturate SwiftUI/WindowServer
/// commits while Teams is also using screen capture.
private struct AnimatedGradientBorder<S: Shape>: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let shape: S
    var lineWidth: CGFloat = 1.5

    private var gradientColors: [Color] {
        [
            .blue.opacity(0.45),
            .cyan.opacity(0.38),
            .purple.opacity(0.34),
            .pink.opacity(0.28),
        ]
    }

    var body: some View {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .mask(
            shape.stroke(
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        )
        .allowsHitTesting(false)
    }
}

/// A floating NSPanel that stays on top of all windows for the recording overlay.
final class RecordingOverlayPanel: NSPanel {
    init(contentView: NSView, size: NSSize = NSSize(width: 240, height: 56)) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        // Position at top-center of screen. Prefer NSScreen.main, but fall back to
        // the first available screen if main is transiently nil during display config changes.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - frame.width / 2
            let y = screenFrame.maxY - frame.height - 12
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // Allow the panel to become key window so text fields can receive input
    override var canBecomeKey: Bool { true }

    /// Resizes without making a top-center overlay jump as its content scale
    /// changes. The AppKit panel owns screen placement; SwiftUI owns the
    /// intrinsic content dimensions.
    func resizeKeepingTopCenter(to size: NSSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return
        }

        let oldFrame = frame
        var newFrame = NSRect(
            x: oldFrame.midX - size.width / 2,
            y: oldFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        if let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first {
            newFrame = constrainFrameRect(newFrame, to: targetScreen)
            newFrame = RecordingOverlayLayoutMetrics.clampedFrame(
                newFrame,
                to: targetScreen.visibleFrame
            )
        }

        setFrame(newFrame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: newFrame.size)
    }
}

/// RAII wrapper that removes its NotificationCenter observer on deinit.
/// Lets a `@MainActor`-isolated owner avoid a nonisolated deinit reaching into
/// non-Sendable observer tokens.
private final class NotificationObserverHandle {
    private var token: NSObjectProtocol?

    init(token: NSObjectProtocol) {
        self.token = token
    }

    func invalidate() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }

    deinit {
        invalidate()
    }
}

/// Controller that manages the overlay panel lifecycle.
@Observable @MainActor
final class RecordingOverlayController {
    private var panel: RecordingOverlayPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var promptPanel: RecordingOverlayPanel?
    private var promptHostingView: NSHostingView<AnyView>?
    private var pendingRegularResize: Task<Void, Never>?
    private var pendingPromptResize: Task<Void, Never>?

    var isExpanded = false
    var isCompactHovered = false
    var showsCountdown = false
    /// Panel is always this size — content floats inside with clear background.
    private let panelSize = NSSize(width: 400, height: 500)

    // Notch mode
    private(set) var notchMode = false
    var notchExpanded = false
    private var notchPanel: NSPanel?
    private var notchCollapseTask: DispatchWorkItem?

    // Screen-config tracking — without this, the overlay panel keeps the original screen's
    // geometry (notch shape / fixed origin) when the display layout changes (e.g. clamshell
    // mode), leaving a phantom black bar floating over other windows on the new display.
    @ObservationIgnored private weak var ownerAppState: AppState?
    @ObservationIgnored private var screenChangeObserver: NotificationObserverHandle?

    func show(appState: AppState) {
        guard appState.startupPolicy.allowsHardwareCapture else { return }
        guard panel == nil, notchPanel == nil else { return }

        isExpanded = false
        notchExpanded = false
        ownerAppState = appState

        installPanelsForCurrentScreen(appState: appState)
        registerScreenChangeObserverIfNeeded()
    }

    private func installPanelsForCurrentScreen(appState: AppState) {
        guard appState.startupPolicy.allowsHardwareCapture else { return }
        // Pick the active screen for layout. Fall back to the first available screen
        // when main is transiently nil during a display config change.
        let activeScreen = NSScreen.main ?? NSScreen.screens.first
        if let screen = activeScreen, Self.hasNotch(screen: screen) {
            notchMode = true
            showNotchOverlay(appState: appState, screen: screen)
        } else {
            notchMode = false
            showRegularOverlay(appState: appState)
        }
    }

    private func registerScreenChangeObserverIfNeeded() {
        guard screenChangeObserver == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification's queue is .main, but the observer block is not Swift-concurrency
            // isolated. Hop onto the main actor to safely touch @MainActor state.
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }
        screenChangeObserver = NotificationObserverHandle(token: token)
    }

    private func handleScreenParametersChanged() {
        // Only re-position when an overlay is actually showing.
        guard panel != nil || notchPanel != nil,
              let appState = ownerAppState,
              appState.startupPolicy.allowsHardwareCapture else { return }

        notchLogger.info("screen parameters changed — recreating overlay for current display layout")

        tearDownOverlayPanels()
        installPanelsForCurrentScreen(appState: appState)
    }

    private func tearDownOverlayPanels() {
        isExpanded = false
        notchExpanded = false
        notchMode = false
        notchCollapseTask?.cancel()
        notchCollapseTask = nil
        notchPanel?.close()
        notchPanel = nil
        panel?.close()
        panel = nil
        hostingView = nil
        pendingRegularResize?.cancel()
        pendingRegularResize = nil
    }

    private func showRegularOverlay(appState: AppState) {
        guard appState.startupPolicy.allowsHardwareCapture else { return }
        let overlayView = RecordingOverlayRoot(onScaleChange: { [weak self] scale in
            self?.scheduleRegularPanelResize(for: scale)
        }) {
            RecordingOverlayView()
                .environment(appState)
        }

        let hosting = NSHostingView(rootView: AnyView(overlayView))
        hosting.frame = NSRect(origin: .zero, size: panelSize)

        let panel = RecordingOverlayPanel(contentView: hosting, size: panelSize)
        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting
    }

    private func scheduleRegularPanelResize(for scale: CGFloat) {
        pendingRegularResize?.cancel()
        pendingRegularResize = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let panel, let hostingView else { return }
            let availableSize = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
            let size = RecordingOverlayLayoutMetrics.regularPanelSize(
                scale: scale,
                availableSize: availableSize
            )
            hostingView.frame = NSRect(origin: .zero, size: size)
            panel.resizeKeepingTopCenter(to: size)
        }
    }

    private func showNotchOverlay(appState: AppState, screen: NSScreen) {
        guard appState.startupPolicy.allowsHardwareCapture else { return }
        let notchW = screen.notchFrame?.width ?? 200
        let overlayView = RecordingOverlayRoot {
            NotchRecordingView(notchWidth: notchW)
                .environment(appState)
        }

        // DynamicNotchKit approach: half-screen panel centered at top.
        // NSHostingView passes through mouse events on transparent (empty) areas.
        let panelSize = NSSize(width: screen.frame.width / 2, height: screen.frame.height / 2)
        let panelOrigin = NSPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height
        )

        let hosting = NSHostingView(rootView: AnyView(overlayView))
        hosting.frame = NSRect(origin: .zero, size: panelSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: panelOrigin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = hosting
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        // ignoresMouseEvents defaults to false — NSHostingView.hitTest
        // returns nil for transparent areas, so menu bar clicks pass through.

        panel.orderFrontRegardless()
        self.notchPanel = panel
    }

    func dismiss() {
        screenChangeObserver?.invalidate()
        screenChangeObserver = nil
        ownerAppState = nil
        tearDownOverlayPanels()
    }

    var isShowing: Bool {
        panel != nil || notchPanel != nil
    }

    var isPromptShowing: Bool {
        promptPanel != nil
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
    }

    func expandNotch() {
        guard notchMode else { return }
        notchCollapseTask?.cancel()
        notchCollapseTask = nil
        notchExpanded = true
    }

    func collapseNotch() {
        guard notchMode, notchExpanded else { return }
        notchCollapseTask?.cancel()
        notchExpanded = false
    }


    static func hasNotch(screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 && screen.auxiliaryTopRightArea != nil
    }

    // MARK: - Mic Prompt

    func showPrompt(appState: AppState) {
        guard appState.startupPolicy.allowsHardwareCapture else { return }
        guard promptPanel == nil else { return }

        let promptView = RecordingOverlayRoot(onScaleChange: { [weak self] _ in
            self?.schedulePromptPanelResize()
        }) {
            MicPromptOverlayView()
                .environment(appState)
        }

        let hostingView = NSHostingView(rootView: AnyView(promptView))
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.layoutSubtreeIfNeeded()
        let initialSize = RecordingOverlayLayoutMetrics.sanitizedFittingSize(
            hostingView.fittingSize,
            availableSize: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
        )
        hostingView.frame = NSRect(origin: .zero, size: initialSize)

        let panel = RecordingOverlayPanel(contentView: hostingView, size: initialSize)
        self.promptPanel = panel
        self.promptHostingView = hostingView
        panel.orderFrontRegardless()
        schedulePromptPanelResize()
    }

    private func schedulePromptPanelResize() {
        pendingPromptResize?.cancel()
        pendingPromptResize = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let panel = promptPanel,
                  let hostingView = promptHostingView else { return }
            hostingView.invalidateIntrinsicContentSize()
            hostingView.layoutSubtreeIfNeeded()
            let availableSize = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
            let size = RecordingOverlayLayoutMetrics.sanitizedFittingSize(
                hostingView.fittingSize,
                availableSize: availableSize
            )
            hostingView.frame = NSRect(origin: .zero, size: size)
            panel.resizeKeepingTopCenter(to: size)
        }
    }

    func dismissPrompt() {
        pendingPromptResize?.cancel()
        pendingPromptResize = nil
        promptPanel?.close()
        promptPanel = nil
        promptHostingView = nil
    }
}

// MARK: - Recording Overlay SwiftUI View

struct RecordingOverlayView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(AppState.self) private var appState

    // Chat state
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var streamState = ChatStreamState()

    // Model selection
    @State private var selectedProvider = AIChatModelCatalog.configuredProvider()
    @State private var selectedModel: String = ""
    @State private var isStopping = false
    @State private var stopButtonHovered = false
    @State private var showLiveTranscript = false

    private var isExpanded: Bool {
        appState.overlayController.isExpanded
    }

    var body: some View {
        VStack {
            if isExpanded {
                VStack(spacing: 0) {
                    compactBar
                    Divider().opacity(0.32)
                    askAIContent
                }
                .frame(width: RecordingOverlayLayoutMetrics.expandedOverlayWidth(scale: uiScale))
                .cadenzaGlass(in: RoundedRectangle(cornerRadius: AppStyle.Radius.panel))
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.Radius.panel))
                .overlay {
                    AnimatedGradientBorder(shape: RoundedRectangle(cornerRadius: AppStyle.Radius.panel))
                }
                .onHover { hovering in
                    // Keep compact controls visible while hovering the expanded panel
                    if hovering {
                        appState.overlayController.isCompactHovered = true
                    }
                    // Don't collapse hover state when mouse leaves expanded panel —
                    // user may be moving between pill and chat area
                }
            } else {
                compactBar
                    .cadenzaGlass(in: Capsule())
                    .clipShape(Capsule())
                    .overlay {
                        AnimatedGradientBorder(shape: Capsule())
                    }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.12), value: isExpanded)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: showCompactControls)
        .onAppear {
            if appState.startupPolicy.allowsContentGeneration {
                initializeModel()
                syncSelectedProvider()
            }
        }
        .onDisappear {
            stopStreaming(savePartial: false)
        }
        .onChange(of: appState.recordingState) {
            if appState.recordingState != .recording && appState.recordingState != .paused {
                isStopping = false
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                // When AI panel expands, ensure compact controls stay visible
                appState.overlayController.isCompactHovered = true
            }
        }
    }

    private func initializeModel() {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        if selectedModel.isEmpty {
            selectedModel = AIChatModelCatalog.configuredModel(for: selectedProvider)
        }
    }

    private func syncSelectedProvider() {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        guard !availableChatProviders.contains(selectedProvider),
              let fallback = AIChatModelCatalog.preferredAvailableProvider(
                  from: availableChatProviders
              ) else { return }
        selectedProvider = fallback
        selectedModel = AIChatModelCatalog.configuredModel(for: fallback)
    }

    // MARK: - Compact Bar

    /// Whether the compact bar should show controls (hover, countdown, or paused).
    private var showCompactControls: Bool {
        appState.overlayController.isCompactHovered || appState.autoStopCountdown > 0 || appState.recordingState == .paused
    }

    @AppStorage("captureMicrophone") private var captureMicrophone = false
    @AppStorage("selectedMicrophoneID") private var selectedMicrophoneID = ""

    private var availableMicrophones: [AVCaptureDevice] {
        guard appState.startupPolicy.allowsHardwareCapture else { return [] }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// True when selectedMicrophoneID is empty or matches an available device.
    /// False when the stored device has disconnected (e.g. AirPods removed).
    private var isSelectedMicAvailable: Bool {
        selectedMicrophoneID.isEmpty || availableMicrophones.contains { $0.uniqueID == selectedMicrophoneID }
    }

    private func microphoneSelectionBinding(for deviceID: String) -> Binding<Bool> {
        Binding(
            get: {
                if deviceID.isEmpty {
                    return selectedMicrophoneID.isEmpty || !isSelectedMicAvailable
                }
                return selectedMicrophoneID == deviceID
            },
            set: { isSelected in
                guard appState.startupPolicy.allowsHardwareCapture else { return }
                if deviceID.isEmpty && !isSelectedMicAvailable {
                    selectedMicrophoneID = ""
                    return
                }
                guard isSelected else { return }
                selectedMicrophoneID = deviceID
            }
        )
    }

    /// Debounced hover — prevents flicker when panel resizes under cursor.
    @State private var hoverDebounceTask: Task<Void, Never>?

    private var compactBar: some View {
        RecordingCompactBarLayout(showsActions: showCompactControls) {
            compactLeadingContent
        } duration: {
            compactDurationContent
        } status: {
            compactStatusContent
        } actions: {
            compactActionControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // A collapsed capsule stays at its intrinsic size. The expanded bar
        // accepts its parent's finite width so the title can truncate instead
        // of pushing the action row beyond the clipped glass surface.
        .fixedSize(horizontal: !isExpanded, vertical: true)
        .contentShape(Capsule())
        .onHover { hovering in
            hoverDebounceTask?.cancel()
            if hovering {
                // Enter immediately
                appState.overlayController.isCompactHovered = true
            } else {
                // When AI panel is expanded, don't collapse on hover exit
                guard !isExpanded else { return }
                // Delay exit to prevent flicker during resize
                hoverDebounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    appState.overlayController.isCompactHovered = false
                }
            }
        }
        .onChange(of: appState.autoStopCountdown > 0) { _, counting in
            appState.overlayController.showsCountdown = counting
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: showCompactControls)
    }

    @ViewBuilder
    private var compactLeadingContent: some View {
        // Left icon: waveform when collapsed, AI sparkles when hovered/expanded.
        if showCompactControls {
            OverlayCircleButton(
                icon: isExpanded ? "chevron.down" : "sparkles",
                tint: isExpanded ? .secondary : .purple
            ) {
                if isExpanded {
                    appState.overlayController.collapse()
                } else {
                    appState.overlayController.expand()
                }
            }
        } else {
            WaveformView(level: appState.audioLevel, color: .red)
                .frame(
                    width: RecordingOverlayLayoutMetrics.iconDimension(
                        base: 24,
                        fontSize: 12,
                        scale: uiScale
                    ),
                    height: RecordingOverlayLayoutMetrics.iconDimension(
                        base: 20,
                        fontSize: 12,
                        scale: uiScale
                    )
                )
        }
    }

    private var compactDurationContent: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(Self.formatDuration(
                accumulated: appState.pauseAccumulatedDuration,
                segmentStart: appState.currentSegmentStart,
                at: context.date
            ))
                .font(.cadenza(15, weight: .semibold, design: .monospaced, scale: uiScale))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var compactStatusContent: some View {
        if showCompactControls {
            if appState.autoStopCountdown > 0 {
                Text("Stopping \(appState.autoStopCountdown)s", comment: "Auto-stop countdown label")
                    .font(.cadenza(12, weight: .medium, scale: uiScale))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        maxWidth: RecordingOverlayLayoutMetrics.compactStatusMaximumWidth(scale: uiScale),
                        alignment: .leading
                    )
            } else if let name = appState.currentMeetingName, !name.isEmpty {
                Text(name)
                    .font(.cadenza(12, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        maxWidth: RecordingOverlayLayoutMetrics.compactStatusMaximumWidth(scale: uiScale),
                        alignment: .leading
                    )
            }
        }
    }

    @ViewBuilder
    private var compactActionControls: some View {
        if showCompactControls {
            HStack(spacing: 10) {
                if appState.autoStopCountdown > 0 {
                    // Keep recording by cancelling the pending auto-stop.
                    OverlayCircleButton(
                        icon: "record.circle",
                        tint: .red,
                        help: String(localized: "Keep recording")
                    ) {
                        guard appState.startupPolicy.allowsHardwareCapture else { return }
                        appState.cancelAutoStop()
                    }
                    .accessibilityIdentifier("recording-overlay-keep-recording")
                } else {
                    compactMicrophoneMenu

                    // Pause / Resume
                    OverlayCircleButton(
                        icon: appState.recordingState == .paused ? "play.fill" : "pause.fill",
                        tint: .primary
                    ) {
                        guard appState.startupPolicy.allowsHardwareCapture else { return }
                        if appState.recordingState == .paused {
                            appState.resumeRecording()
                        } else {
                            appState.pauseRecording()
                        }
                    }
                    .accessibilityIdentifier("recording-overlay-pause-resume")
                }

                compactStopButton
            }
        }
    }

    private var compactMicrophoneMenu: some View {
        Menu {
            Button {
                guard appState.startupPolicy.allowsHardwareCapture else { return }
                captureMicrophone.toggle()
                appState.recordingEngine.audioMixer.setMicCapture(enabled: captureMicrophone)
            } label: {
                Label(
                    captureMicrophone ? "Mute Microphone" : "Unmute Microphone",
                    systemImage: captureMicrophone ? "mic.slash" : "mic.fill"
                )
            }

            Divider()

            // Show Default as selected when the stored device is disconnected.
            Toggle(isOn: microphoneSelectionBinding(for: "")) {
                Text("Default")
            }

            ForEach(availableMicrophones, id: \.uniqueID) { device in
                Toggle(isOn: microphoneSelectionBinding(for: device.uniqueID)) {
                    Text(device.localizedName)
                }
            }
        } label: {
            let controlSize = RecordingOverlayLayoutMetrics.controlDimension(
                base: 28,
                fontSize: 12,
                scale: uiScale
            )
            Image(systemName: captureMicrophone ? "mic.fill" : "mic.slash.fill")
                .font(.cadenza(12, weight: .semibold, scale: uiScale))
                .foregroundStyle(captureMicrophone ? .primary : .secondary)
                .frame(width: controlSize, height: controlSize)
                .background(Circle().fill(.primary.opacity(0.1)))
        }
        .buttonStyle(.plain) // hit-test-exempt: Menu, not a Button; label 已有实心 Circle 背景
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!appState.startupPolicy.allowsHardwareCapture)
        .accessibilityIdentifier("recording-overlay-microphone-menu")
    }

    private var compactStopButton: some View {
        Button {
            guard appState.startupPolicy.allowsHardwareCapture, !isStopping else { return }
            isStopping = true
            appState.stopRecording()
        } label: {
            let controlSize = RecordingOverlayLayoutMetrics.controlDimension(
                base: 28,
                fontSize: 12,
                scale: uiScale
            )
            ZStack {
                if isStopping {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.secondary)
                } else {
                    Image(systemName: "stop.fill")
                        .font(.cadenza(12, weight: .semibold, scale: uiScale))
                        .foregroundStyle(Color(red: 0.96, green: 0.28, blue: 0.28))
                }
            }
            .frame(width: controlSize, height: controlSize)
            .background(
                Circle().fill(stopButtonHovered ? Color.primary.opacity(0.15) : Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.cadenzaPlain(in: Circle()))
        .disabled(isStopping)
        .accessibilityIdentifier("recording-overlay-stop")
        .onHover { stopButtonHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: stopButtonHovered)
    }

    // MARK: - Ask AI Tab

    private var askAIContent: some View {
        VStack(spacing: 0) {
            switch RealtimeOverlayStatus.resolve(
                hint: appState.realtimeHint,
                segmentCount: appState.liveTranscriptSegments.count,
                isEnabled: UserDefaults.standard.bool(forKey: "enableRealtimeTranscription")
            ) {
            case .failure(let hint):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.cadenza(11, scale: uiScale))
                    Text(hint)
                        .font(.cadenza(11, weight: .medium, scale: uiScale))
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .active(let segmentCount):
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.cadenza(11, scale: uiScale))
                    Text("Live transcript active \u{00B7} \(segmentCount) segments")
                        .font(.cadenza(11, weight: .medium, scale: uiScale))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .listening:
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.cadenza(11, scale: uiScale))
                    Text("Listening...")
                        .font(.cadenza(11, weight: .medium, scale: uiScale))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .hidden:
                EmptyView()
            }

            // Live transcript toggle + display
            if !appState.liveTranscriptSegments.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : .default) {
                        showLiveTranscript.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showLiveTranscript ? "eye.slash" : "eye")
                            .font(.cadenza(10, scale: uiScale))
                        Text(showLiveTranscript ? String(localized: "Hide Transcript") : String(localized: "Show Transcript"))
                            .font(.cadenza(11, weight: .medium, scale: uiScale))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.cadenzaPlain)
                .frame(maxWidth: .infinity, alignment: .leading)

                if showLiveTranscript {
                    let recentSegments = Array(appState.liveTranscriptSegments.suffix(30))
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(recentSegments) { segment in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(segment.formattedTimestamp)
                                            .font(.cadenza(11, design: .monospaced, scale: uiScale))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: ceil(36 * max(uiScale, 1)), alignment: .trailing)
                                        Text(segment.text)
                                            .font(.cadenzaBody(13, scale: uiScale))
                                            .opacity(segment.isFinal ? 1.0 : 0.5)
                                    }
                                    .id(segment.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                        .frame(minHeight: 60, maxHeight: 160)
                        .onChange(of: appState.liveTranscriptSegments.count) {
                            if let last = appState.liveTranscriptSegments.last {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }

            if shouldShowSuggestions {
                Divider().opacity(0.32)
                aiSuggestionsView
                Divider().opacity(0.32)
            } else if shouldShowAIMessagesArea {
                Divider().opacity(0.32)
                aiMessagesArea
                Divider().opacity(0.32)
            } else {
                Divider().opacity(0.32)
            }

            aiInputBar
        }
    }

    // MARK: - AI Suggestions

    private var shouldShowSuggestions: Bool {
        messages.isEmpty && !streamState.isActive && !showLiveTranscript
    }

    private var shouldShowAIMessagesArea: Bool {
        !messages.isEmpty || streamState.isActive
    }

    private var suggestedQuestions: [(icon: String, text: String)] {
        var questions: [(icon: String, text: String)] = []

        // In-meeting urgent prompts — only useful when live transcript is flowing.
        // These cover the "I'm in the meeting NOW and need help right now" scenarios.
        if !appState.liveTranscriptSegments.isEmpty {
            questions.append(contentsOf: [
                (icon: "ear.badge.waveform", text: String(localized: "I zoned out — catch me up on the last 2 minutes")),
                (icon: "hand.raised", text: String(localized: "What was just asked of me?")),
                (icon: "person.wave.2", text: String(localized: "Did anyone just mention my name?")),
                (icon: "scale.3d", text: String(localized: "What's the current disagreement on the table?"))
            ])
        }

        // Auxiliary prompts — useful before/after or when no transcript yet.
        questions.append(contentsOf: [
            (icon: "arrow.triangle.branch", text: String(localized: "What follow-up questions should I ask?")),
            (icon: "list.bullet.rectangle", text: String(localized: "Give me a meeting notes template"))
        ])

        return questions
    }

    private var aiSuggestionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Suggestions")
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                ForEach(suggestedQuestions, id: \.text) { q in
                    Button {
                        guard appState.startupPolicy.allowsContentGeneration else { return }
                        startStreamingMessage(q.text)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: q.icon)
                                .font(.cadenza(12, scale: uiScale))
                                .foregroundStyle(.secondary)
                                .frame(width: RecordingOverlayLayoutMetrics.iconDimension(
                                    base: 20,
                                    fontSize: 12,
                                    scale: uiScale
                                ))
                            Text(q.text)
                                .font(.cadenza(13, scale: uiScale))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.cadenza(9, weight: .semibold, scale: uiScale))
                                .foregroundStyle(.quaternary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(OverlaySuggestionButtonStyle())
                    .disabled(!appState.startupPolicy.allowsContentGeneration)
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - AI Messages

    private var aiMessagesArea: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(messages) { message in
                    compactBubble(message)
                        .id(message.id)
                }
                // Isolation boundary — per-tick streamState reads stay inside
                // OverlayStreamingSection so streaming never re-evaluates this
                // list body (see ARCHITECTURE.md §12.2 hang postmortem).
                OverlayStreamingSection(
                    streamState: streamState,
                    uiScale: uiScale
                )
            }
            .padding(12)
        }
        .frame(minHeight: 100)
        .defaultScrollAnchor(.bottom)
    }

    private func compactBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if message.role == .user { Spacer(minLength: 40) }

            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.cadenza(10, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: RecordingOverlayLayoutMetrics.iconDimension(
                            base: 18,
                            fontSize: 10,
                            scale: uiScale
                        ),
                        height: RecordingOverlayLayoutMetrics.iconDimension(
                            base: 18,
                            fontSize: 10,
                            scale: uiScale
                        )
                    )
                    .padding(.top, 3)
            }

            Group {
                if message.role == .assistant {
                    MarkdownMessageView(message.content, fontSize: 12, uiScale: uiScale, compact: true)
                } else {
                    Text(message.content)
                        .font(.cadenza(12, scale: uiScale))
                }
            }
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: AppStyle.Radius.bubble)
                        .fill(message.role == .user
                              ? Color.accentColor.opacity(0.85)
                              : AppStyle.ColorToken.assistantBubble)
                )
                .foregroundStyle(message.role == .user ? .white : .primary)

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    // MARK: - AI Input Bar

    private var aiInputBar: some View {
        HStack(spacing: 8) {
            modelMenu
                .help("Choose model")

            HStack(spacing: 6) {
                TextField("Ask about this recording...", text: $inputText)
                    .font(.cadenza(12, weight: .medium, scale: uiScale))
                    .textFieldStyle(.plain)
                    .onSubmit(submitInput)
                    .disabled(streamState.isActive || !appState.startupPolicy.allowsContentGeneration)

                if streamState.isActive {
                    Button {
                        stopStreaming(savePartial: true)
                    } label: {
                        let controlSize = RecordingOverlayLayoutMetrics.controlDimension(
                            base: 22,
                            fontSize: 9,
                            scale: uiScale
                        )
                        Image(systemName: "stop.fill")
                            .font(.cadenza(9, weight: .bold, scale: uiScale))
                            .foregroundStyle(.white)
                            .frame(width: controlSize, height: controlSize)
                            .background(Circle().fill(Color.secondary.opacity(0.75)))
                    }
                    .buttonStyle(.cadenzaPlain)
                    .help("Stop response")
                } else if !inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: submitInput) {
                        let controlSize = RecordingOverlayLayoutMetrics.controlDimension(
                            base: 22,
                            fontSize: 10,
                            scale: uiScale
                        )
                        Image(systemName: "arrow.up")
                            .font(.cadenza(10, weight: .bold, scale: uiScale))
                            .foregroundStyle(.white)
                            .frame(width: controlSize, height: controlSize)
                            .background(Circle().fill(Color.accentColor.opacity(0.85)))
                    }
                    .buttonStyle(.cadenzaPlain)
                    .disabled(streamState.isActive || !appState.startupPolicy.allowsContentGeneration)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .cadenzaGlass(in: RoundedRectangle(cornerRadius: AppStyle.Radius.card, style: .continuous))
        }
        .padding(8)
        .cadenzaGlass(in: RoundedRectangle(cornerRadius: AppStyle.Radius.card + 1, style: .continuous))
    }

    private var availableChatProviders: [AIProvider] {
        guard appState.startupPolicy.allowsContentGeneration else { return [] }
        return AIProvider.allCases.filter { provider in
            provider.requiresAPIKey
                && provider.makeChatService(apiKey: "") != nil
                && KeychainManager.shared.hasAPIKey(for: provider)
        }
    }

    private var modelMenu: some View {
        AIChatModelMenu(
            availableProviders: availableChatProviders,
            selectedProvider: $selectedProvider,
            selectedModel: $selectedModel,
            labelKind: .providerIcon(iconSize: 14, frameSize: 26, cornerRadius: 8)
        )
    }

    // MARK: - AI Integration

    private func submitInput() {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !streamState.isActive else { return }
        inputText = ""
        startStreamingMessage(text)
    }

    private func startStreamingMessage(_ text: String) {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        guard !streamState.isActive else { return }
        streamState.run { await sendMessage(text) }
    }

    private func stopStreaming(savePartial: Bool) {
        streamState.stop(savePartial: savePartial)
    }

    private func sendMessage(_ text: String) async {
        guard appState.startupPolicy.allowsContentGeneration else { return }
        messages.append(ChatMessage(role: .user, content: text))

        guard let (service, modelID) = resolveAIService() else {
            messages.append(ChatMessage(
                role: .assistant,
                content: String(localized: "No AI provider configured. Please add an API key in Settings.")
            ))
            return
        }

        let systemPrompt = buildSystemPrompt()
        let fullUserMessage = buildUserMessage(currentQuestion: text)

        let stream = service.streamChat(
            systemPrompt: systemPrompt,
            userMessage: fullUserMessage,
            model: modelID
        )

        do {
            let response = try await streamState.collect(stream)
            messages.append(ChatMessage(role: .assistant, content: response))
        } catch is CancellationError {
            let partial = streamState.currentPartialText()
            if streamState.savePartialOnCancel && !partial.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: partial))
            }
        } catch {
            let partial = streamState.currentPartialText()
            let content = partial.isEmpty
                ? String(localized: "AI response failed: \(error.localizedDescription)")
                : partial
            messages.append(ChatMessage(role: .assistant, content: content))
        }
    }

    private func resolveAIService() -> (AIServiceProtocol, String)? {
        guard appState.startupPolicy.allowsContentGeneration else { return nil }
        let apiKey: String
        if selectedProvider.requiresAPIKey {
            guard let key = KeychainManager.shared.apiKey(for: selectedProvider), !key.isEmpty else { return nil }
            apiKey = key
        } else {
            apiKey = ""
        }
        guard let service = selectedProvider.makeChatService(apiKey: apiKey) else { return nil }
        return (service, selectedModel)
    }

    /// Pause-aware duration: accumulated (from completed segments) + live offset from current segment.
    static func formatDuration(accumulated: TimeInterval, segmentStart: Date?, at now: Date) -> String {
        let liveOffset = segmentStart.map { now.timeIntervalSince($0) } ?? 0
        let total = Int(max(0, accumulated + liveOffset))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func buildSystemPrompt() -> String {
        let meetingName = appState.currentMeetingName ?? "Untitled Recording"
        let duration = appState.formattedDuration
        let status = appState.recordingState == .paused ? "Paused" : "Recording"

        var prompt = """
        You are an AI assistant helping during a live recording.
        The user is IN the meeting right now and may need answers fast — be terse.
        Default to 1-3 sentences. Use bullets only if the question genuinely needs structure.
        Skip preambles like "Sure, here is..." and just answer.

        Meeting: \(meetingName)
        Duration: \(duration)
        Status: \(status)
        """

        prompt += AIContextAssembler.identityBlock()
        prompt += AIContextAssembler.languageDirective()

        // Inject live transcript context — cap at ~12000 chars (~3000 tokens) to avoid OOM/context overflow.
        // Use the most recent segments first (most relevant to user's question).
        let maxTranscriptChars = 12000
        var liveText = ""
        for segment in appState.liveTranscriptSegments.reversed() where segment.isFinal {
            let line = segment.text
            if liveText.count + line.count > maxTranscriptChars { break }
            liveText = line + " " + liveText
        }
        liveText = liveText.trimmingCharacters(in: .whitespaces)

        if !liveText.isEmpty {
            prompt += """


            You have access to the most recent portion of the live transcript. Use it to answer questions about what was discussed.

            --- LIVE TRANSCRIPT (most recent) ---
            \(liveText)
            --- END LIVE TRANSCRIPT ---
            """
        } else {
            prompt += """


            Live transcript is not yet available. If asked factual details about exact speech content, say it is unavailable until post-processing transcript completes.
            Still provide concise and helpful guidance.
            """
        }

        return prompt
    }

    private func buildUserMessage(currentQuestion: String) -> String {
        AIContextAssembler.packHistory(Array(messages.dropLast()), currentQuestion: currentQuestion)
    }

}

// MARK: - Overlay Suggestion Button Style

private struct OverlaySuggestionButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? AppStyle.ColorToken.softFill : .clear)
            )
            .onHover { isHovered = $0 }
    }
}

// MARK: - NSScreen Notch Geometry

extension NSScreen {
    var notchFrame: NSRect? {
        guard
            let leftWidth = auxiliaryTopLeftArea?.width,
            let rightWidth = auxiliaryTopRightArea?.width
        else { return nil }
        let notchWidth = frame.width - leftWidth - rightWidth
        let notchHeight = safeAreaInsets.top
        return NSRect(
            x: frame.midX - notchWidth / 2,
            y: frame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
    }
}

// MARK: - Notch Recording Overlay

/// Keeps the hardware-notch reservation at its physical height while placing
/// scalable controls in a separate row below it. This small layout boundary is
/// also safe to probe with `NSHostingView.fittingSize` because it contains no
/// timer-driven content of its own.
struct NotchBelowHardwareLayout<Content: View>: View {
    let physicalTopHeight: CGFloat
    let minWidth: CGFloat
    private let content: Content

    init(
        physicalTopHeight: CGFloat,
        minWidth: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.physicalTopHeight = physicalTopHeight
        self.minWidth = minWidth
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: physicalTopHeight)
            content
        }
        .frame(minWidth: minWidth)
    }
}

/// Keeps the auto-stop message from competing with every transport action in
/// one unbounded row. The regular layout preserves the compact ordering; at
/// accessibility sizes the message and transport targets receive separate rows.
struct NotchActionControlsLayout<Microphone: View, Countdown: View, Transport: View>: View {
    let showsCountdown: Bool
    let scale: CGFloat
    private let microphone: Microphone
    private let countdown: Countdown
    private let transport: Transport

    init(
        showsCountdown: Bool,
        scale: CGFloat,
        @ViewBuilder microphone: () -> Microphone,
        @ViewBuilder countdown: () -> Countdown,
        @ViewBuilder transport: () -> Transport
    ) {
        self.showsCountdown = showsCountdown
        self.scale = scale
        self.microphone = microphone()
        self.countdown = countdown()
        self.transport = transport()
    }

    var body: some View {
        if showsCountdown && scale >= CadenzaTextScale.factor(.accessibility1) {
            VStack(alignment: .trailing, spacing: 8) {
                countdown
                HStack(spacing: 10) {
                    microphone
                    transport
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(spacing: 10) {
                microphone
                if showsCountdown {
                    countdown
                }
                transport
            }
        }
    }
}

struct NotchRecordingView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(AppState.self) private var appState
    @State private var isStopping = false
    @State private var availableMicrophones: [AVCaptureDevice] = []
    @AppStorage("selectedMicrophoneID") private var selectedMicrophoneID = ""
    let notchWidth: CGFloat

    private var isExpanded: Bool {
        appState.overlayController.notchExpanded || appState.autoStopCountdown > 0
    }

    private let topCornerRadius: CGFloat = 6
    private let bottomCornerRadius: CGFloat = 14
    private var notchHeight: CGFloat { NSScreen.main?.safeAreaInsets.top ?? 32 }
    private var minWidth: CGFloat { notchWidth + topCornerRadius * 2 }

    var body: some View {
        ZStack(alignment: .top) {
            // Compact: content on both sides of the notch
            compactContent
                .opacity(isExpanded ? 0 : 1)

            // Expanded: notch extends downward with full controls
            expandedContent
                .opacity(isExpanded ? 1 : 0)
                .frame(maxWidth: isExpanded ? nil : 0, maxHeight: isExpanded ? nil : 0)
                .clipped()
        }
        .padding(.horizontal, topCornerRadius)
        // Preserve intrinsic height without allowing localized content to
        // exceed the half-screen notch panel horizontally.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: minWidth, minHeight: notchHeight)
        .onHover { hovering in
            if hovering {
                appState.overlayController.expandNotch()
            } else {
                appState.overlayController.collapseNotch()
            }
        }
        .background {
            Rectangle().fill(.black).padding(-60)
        }
        .mask {
            NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
        }
        .shadow(color: .black.opacity(isExpanded ? 0.5 : 0), radius: isExpanded ? 12 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: isExpanded)
        .onAppear {
            guard appState.startupPolicy.allowsHardwareCapture else { return }
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
            )
            availableMicrophones = session.devices
        }
        .onChange(of: appState.recordingState) {
            if appState.recordingState != .recording && appState.recordingState != .paused {
                isStopping = false
            }
        }
    }

    // MARK: - Compact (both sides of notch)

    private var compactContent: some View {
        HStack(spacing: 0) {
            // Left side of notch: app icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(.leading, 8)
                .padding(.trailing, 4)

            // Spacer for the notch gap
            Spacer()
                .frame(width: notchWidth)

            // Right side of notch: recording waveform
            Image(systemName: "waveform")
                // The compact row occupies the physical camera-notch height.
                // Keep that hardware geometry stable; accessibility-sized
                // controls live in the expanded rows below it.
                .font(.cadenza(14, weight: .bold, scale: min(uiScale, 1)))
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, isActive: appState.recordingState == .recording)
                .padding(.leading, 4)
                .padding(.trailing, 8)
        }
        .foregroundStyle(.white)
        .frame(height: notchHeight)
    }

    // MARK: - Expanded (drops below notch)

    private var expandedContent: some View {
        NotchBelowHardwareLayout(
            physicalTopHeight: notchHeight,
            minWidth: notchWidth + 200
        ) {
            expandedControlContent
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var expandedControlContent: some View {
        if uiScale >= CadenzaTextScale.factor(.accessibility1) {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    recordingIdentity
                    Spacer(minLength: 8)
                    notchDurationText
                        .font(.cadenza(13, weight: .medium, design: .monospaced, scale: uiScale))
                        .opacity(0.7)
                }
                notchActionControls
            }
        } else {
            HStack(spacing: 10) {
                recordingIdentity
                notchDurationText
                    .font(.cadenza(13, weight: .medium, design: .monospaced, scale: uiScale))
                    .opacity(0.7)
                Spacer(minLength: 4)
                notchActionControls
            }
        }
    }

    private var recordingIdentity: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)

            Group {
                if let name = appState.currentMeetingName {
                    Text(name)
                } else {
                    Text("Recording")
                }
            }
            .font(.cadenza(13, weight: .medium, scale: uiScale))
            .lineLimit(1)
        }
    }

    private var notchActionControls: some View {
        let showsCountdown = appState.autoStopCountdown > 0
        return NotchActionControlsLayout(showsCountdown: showsCountdown, scale: uiScale) {
            micPickerMenu
        } countdown: {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(.cadenza(10, scale: uiScale))
                    Text("\(appState.autoStopCountdown)s")
                        .font(.cadenza(11, weight: .semibold, design: .monospaced, scale: uiScale))
                }
                .foregroundStyle(.orange)

                Button("Keep Recording") {
                    guard appState.startupPolicy.allowsHardwareCapture else { return }
                    appState.cancelAutoStop()
                }
                .font(.cadenza(11, weight: .semibold, scale: uiScale))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: notchTransportControlSize)
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
                .accessibilityHint("Cancels the automatic stop countdown")
            }
        } transport: {
            HStack(spacing: 10) {
                pauseResumeButton
                stopButton
            }
        }
    }

    private var notchTransportControlSize: CGFloat {
        RecordingOverlayLayoutMetrics.controlDimension(
            base: 24,
            fontSize: 11,
            scale: uiScale
        )
    }

    private var pauseResumeButton: some View {
        let controlSize = notchTransportControlSize
        return Button {
            guard appState.startupPolicy.allowsHardwareCapture else { return }
            if appState.recordingState == .paused {
                appState.resumeRecording()
            } else {
                appState.pauseRecording()
            }
        } label: {
            Image(systemName: appState.recordingState == .paused ? "play.fill" : "pause.fill")
                .font(.cadenza(11, weight: .semibold, scale: uiScale))
                .frame(width: controlSize, height: controlSize)
                .background(Circle().fill(.white.opacity(0.15)))
        }
        .buttonStyle(.cadenzaPlain)
        .disabled(!appState.startupPolicy.allowsHardwareCapture)
    }

    private var stopButton: some View {
        Button {
            guard appState.startupPolicy.allowsHardwareCapture, !isStopping else { return }
            isStopping = true
            appState.stopRecording()
        } label: {
            HStack(spacing: 4) {
                if isStopping {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "waveform")
                        .font(.cadenza(10, weight: .bold, scale: uiScale))
                }
                Text("Stop")
                    .font(.cadenza(12, weight: .semibold, scale: uiScale))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.red))
        }
        .buttonStyle(.cadenzaPlain)
        .disabled(isStopping || !appState.startupPolicy.allowsHardwareCapture)
    }

    // MARK: - Mic Picker

    private var isSelectedMicAvailable: Bool {
        selectedMicrophoneID.isEmpty || availableMicrophones.contains { $0.uniqueID == selectedMicrophoneID }
    }

    private func microphoneSelectionBinding(for deviceID: String) -> Binding<Bool> {
        Binding(
            get: {
                if deviceID.isEmpty {
                    return selectedMicrophoneID.isEmpty || !isSelectedMicAvailable
                }
                return selectedMicrophoneID == deviceID
            },
            set: { isSelected in
                guard appState.startupPolicy.allowsHardwareCapture else { return }
                if deviceID.isEmpty && !isSelectedMicAvailable {
                    selectedMicrophoneID = ""
                    return
                }
                guard isSelected else { return }
                selectedMicrophoneID = deviceID
            }
        )
    }

    private var micPickerMenu: some View {
        Menu {
            Toggle(isOn: microphoneSelectionBinding(for: "")) {
                Text("Default")
            }
            Divider()
            ForEach(availableMicrophones, id: \.uniqueID) { device in
                Toggle(isOn: microphoneSelectionBinding(for: device.uniqueID)) {
                    Text(device.localizedName)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .font(.cadenza(11, weight: .semibold, scale: uiScale))
                Image(systemName: "chevron.down")
                    .font(.cadenza(9, weight: .bold, scale: uiScale))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.15)))
        }
        .buttonStyle(.plain) // hit-test-exempt: Menu, not a Button; label 已有实心 Capsule 背景
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!appState.startupPolicy.allowsHardwareCapture)
    }

    // MARK: - Duration

    private var notchDurationText: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(RecordingOverlayView.formatDuration(
                accumulated: appState.pauseAccumulatedDuration,
                segmentStart: appState.currentSegmentStart,
                at: context.date
            ))
        }
    }
}

// MARK: - Notch Shape

private struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Mic Prompt Overlay

struct MicPromptOverlayView: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.cadenza(18, scale: uiScale))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)

            Text("Mic active — record?")
                .font(.cadenza(.subheadline, weight: .medium, scale: uiScale))
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                guard appState.startupPolicy.allowsHardwareCapture else { return }
                Task {
                    do { try await appState.startRecording(captureMicrophone: true) }
                    catch { appState.presentStartRecordingError(error) }
                }
            } label: {
                let controlSize = RecordingOverlayLayoutMetrics.controlDimension(
                    base: 28,
                    fontSize: 20,
                    scale: uiScale
                )
                Image(systemName: "record.circle.fill")
                    .font(.cadenza(20, scale: uiScale))
                    .foregroundStyle(.red)
                    .frame(width: controlSize, height: controlSize)
            }
            .buttonStyle(.cadenzaPlain)
            .disabled(!appState.startupPolicy.allowsHardwareCapture)

            Button {
                appState.dismissMicPrompt()
            } label: {
                let controlSize = RecordingOverlayLayoutMetrics.controlDimension(
                    base: 22,
                    fontSize: 11,
                    scale: uiScale
                )
                Image(systemName: "xmark")
                    .font(.cadenza(11, weight: .bold, scale: uiScale))
                    .foregroundStyle(.secondary)
                    .frame(width: controlSize, height: controlSize)
            }
            .buttonStyle(.cadenzaPlain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize(horizontal: true, vertical: true)
        .cadenzaGlass(in: .capsule, interactive: true)
    }
}

#Preview("Recording") {
    RecordingOverlayView()
        .environment(AppState())
        .padding(40)
}

#Preview("Mic Prompt") {
    MicPromptOverlayView()
        .environment(AppState())
        .padding(40)
}

// MARK: - Streaming Isolation Boundary (overlay chat)

/// Same isolation pattern as the floating panel: the only view here reading
/// streamState's per-tick state, so streaming ticks re-evaluate just this
/// subtree instead of the whole overlay message list.
private struct OverlayStreamingSection: View {
    let streamState: ChatStreamState
    let uiScale: CGFloat

    var body: some View {
        Group {
            if streamState.isActive {
                bubble
                    .id("streaming")
            }
        }
    }

    private var bubble: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.cadenza(10, scale: uiScale))
                .foregroundStyle(.secondary)
                .frame(
                    width: RecordingOverlayLayoutMetrics.iconDimension(
                        base: 18,
                        fontSize: 10,
                        scale: uiScale
                    ),
                    height: RecordingOverlayLayoutMetrics.iconDimension(
                        base: 18,
                        fontSize: 10,
                        scale: uiScale
                    )
                )
                .padding(.top, 3)

            if !streamState.hasVisibleContent {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(.secondary.opacity(0.4))
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: AppStyle.Radius.bubble)
                        .fill(AppStyle.ColorToken.assistantBubble)
                )
            } else {
                StreamingMarkdownMessageView(snapshot: streamState.snapshot, fontSize: 12, uiScale: uiScale, compact: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: AppStyle.Radius.bubble)
                            .fill(AppStyle.ColorToken.assistantBubble)
                    )
            }

            Spacer(minLength: 40)
        }
    }
}
