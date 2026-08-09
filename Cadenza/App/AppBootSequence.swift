import AppKit
import Foundation
import SwiftUI

/// Top-level boot disposition, resolved before any service exists. The
/// runtime shell either runs the app with a resolved context or shows a
/// blocking halt surface. A halted boot constructs no AppState and adds
/// no writes of its own — though the bootstrap or transfer that halted
/// may already have recorded durable, resumable progress.
enum AppBootDisposition {
    case run(ProfileBootContext?)
    case halted(reason: String)
}

enum AppBootSequence {
    /// Recorded once by the live boot, before any scene or delegate
    /// callback runs. Scene policy and the app delegate read it to keep
    /// the halt shell visible and inert: nil in TestHost and on every
    /// normal boot.
    @MainActor private(set) static var haltedBootReason: String?

    /// Pure disposition logic over injected steps, so the halt paths are
    /// testable without live stores or registries.
    static func resolve(
        isRunningTests: Bool,
        bootstrap: () -> ProfileBootContext?,
        runTransfer: (PendingTransfer) -> ProfileTransferExecutor.Outcome
    ) -> AppBootDisposition {
        // TestHost: no live bootstrap is reachable (INV-8); the shell
        // runs with an ephemeral context.
        guard !isRunningTests else { return .run(nil) }
        var bootContext = bootstrap()
        if let context = bootContext, case .transfer(let pending) = context.mode {
            // Transfer completes before normal services are constructed.
            switch runTransfer(pending) {
            case .completed(let targetProfileID):
                // A completed transfer has exactly one legitimate
                // successor: the transferred target profile. Any other
                // resolution — a different profile, legacy fallback, no
                // context, or a persisted transfer mode — means the
                // registry and the executor's outcome disagree, and
                // opening anything else would serve the wrong authority.
                bootContext = bootstrap()
                guard let rebooted = bootContext,
                      case .profile(let bootedID) = rebooted.mode,
                      bootedID == targetProfileID,
                      rebooted.profile?.id == targetProfileID else {
                    return .halted(
                        reason: "post-transfer bootstrap did not resolve the transferred profile"
                    )
                }
            case .halted(let reason):
                return .halted(reason: reason)
            }
        }
        if let bootContext, case .halted(let reason) = bootContext.mode {
            // A committed registry exists but is unrecoverable. Opening
            // the legacy store would put two authorities over the same
            // data; stopping visibly is the only safe behavior.
            return .halted(reason: reason)
        }
        return .run(bootContext)
    }

    @MainActor
    static func resolveLive() -> AppBootDisposition {
        let disposition = resolve(
            isRunningTests: AppState.isRunningTests,
            bootstrap: { ProfileBootstrap.runLive() },
            runTransfer: { ProfileTransferExecutor.runLive(pending: $0) }
        )
        if case .halted(let reason) = disposition {
            haltedBootReason = reason
        }
        return disposition
    }
}

/// Stable, user-facing copy for a failed boot. The diagnostic remains a
/// developer-facing value and must never be used as a localization key or
/// rendered directly in the halt view.
enum BootHaltPresentation {
    static func title(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Cadenza can't open your data safely", locale: locale)
    }

    static func recoveryInstructions(locale: Locale? = nil) -> String {
        LocalizedBundle.string(
            "To protect your recordings, Cadenza stopped before opening your library. Quit and reopen to resume. If this keeps happening, copy the diagnostics and contact support.",
            locale: locale
        )
    }

    static func copyDiagnosticsLabel(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Copy Diagnostics", locale: locale)
    }

    static func copiedConfirmation(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Copied", locale: locale)
    }

    static func quitLabel(locale: Locale? = nil) -> String {
        LocalizedBundle.string("Quit Cadenza", locale: locale)
    }
}

enum BootHaltLayoutPolicy {
    static let width: CGFloat = 480
    static let horizontalPadding: CGFloat = 24

    static func stacksActions(scale: CGFloat) -> Bool {
        safeScale(scale) >= CadenzaTextScale.factor(.accessibility1)
    }

    static func minimumActionHeight(scale: CGFloat) -> CGFloat {
        max(28, ceil(12 * safeScale(scale) * 1.3))
    }

    private static func safeScale(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 1
    }
}

/// Optional geometry seam used only by the real NSHostingView regression.
/// Production never supplies a probe. Test probes match each SwiftUI action
/// frame but reject hit testing, so pointer events still reach the real Button.
@MainActor
final class BootHaltGeometryProbe {
    enum Element: Hashable {
        case content
        case copyAction
        case quitAction
    }

    private final class WeakView {
        weak var value: NSView?

        init(_ value: NSView) {
            self.value = value
        }
    }

    private var views: [Element: WeakView] = [:]

    func view(for element: Element) -> NSView? {
        views[element]?.value
    }

    fileprivate func record(_ view: NSView, for element: Element) {
        views[element] = WeakView(view)
    }
}

private final class BootHaltNonHitTestingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct BootHaltGeometryProbeView: NSViewRepresentable {
    let probe: BootHaltGeometryProbe
    let element: BootHaltGeometryProbe.Element

    func makeNSView(context: Context) -> NSView {
        let view = BootHaltNonHitTestingView(frame: .zero)
        probe.record(view, for: element)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        probe.record(nsView, for: element)
    }
}

/// Blocking halt surface for an unservable boot: gives stable recovery
/// guidance without exposing the internal reason. Intentionally inert — no
/// services exist behind it.
struct BootHaltView: View {
    private static let uiScaleDefaults: UserDefaults = {
        guard CadenzaApp.rootAppStorageUsesSharedDefaults(
            debugConfiguration: DebugDataRoot.configuration
        ) else {
            return UserDefaults(
                suiteName: "com.shuiandy.Cadenza.debug-boot-halt-scale.\(UUID().uuidString)"
            )!
        }
        return .standard
    }()

    let diagnosticReason: String
    private let productScaleOverride: CGFloat?
    private let geometryProbe: BootHaltGeometryProbe?
    private let copyDiagnosticsOverride: ((String) -> Bool)?
    private let quitOverride: (() -> Void)?

    @State private var diagnosticsCopied = false
    @AppStorage("uiScale", store: BootHaltView.uiScaleDefaults)
    private var uiScalePreset: UIScalePreset = .default
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    init(
        reason: String,
        productScaleOverride: CGFloat? = nil,
        geometryProbe: BootHaltGeometryProbe? = nil,
        copyDiagnosticsOverride: ((String) -> Bool)? = nil,
        quitOverride: (() -> Void)? = nil
    ) {
        diagnosticReason = reason
        self.productScaleOverride = productScaleOverride
        self.geometryProbe = geometryProbe
        self.copyDiagnosticsOverride = copyDiagnosticsOverride
        self.quitOverride = quitOverride
    }

    var body: some View {
        let effectiveUIScale = CadenzaTextScale.combined(
            uiScale: productScaleOverride ?? uiScalePreset.scaleFactor,
            dynamicTypeSize: dynamicTypeSize
        )
        VStack(alignment: .leading, spacing: 14) {
            Text(BootHaltPresentation.title(locale: locale))
                .font(.cadenza(15, weight: .semibold, scale: effectiveUIScale))
                .fixedSize(horizontal: false, vertical: true)
            Text(BootHaltPresentation.recoveryInstructions(locale: locale))
                .font(.cadenza(12, scale: effectiveUIScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if diagnosticsCopied {
                Label(
                    BootHaltPresentation.copiedConfirmation(locale: locale),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.cadenza(11, scale: effectiveUIScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            actionControls(scale: effectiveUIScale)
        }
        .padding(BootHaltLayoutPolicy.horizontalPadding)
        .frame(width: BootHaltLayoutPolicy.width, alignment: .leading)
        .background { geometryProbeView(for: .content) }
        .onAppear {
            // The halt window is the process's only surface; without an
            // explicit activation a login-item launch would leave it
            // buried behind other apps.
            guard !AppState.isRunningTests else { return }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @ViewBuilder
    private func actionControls(scale: CGFloat) -> some View {
        if BootHaltLayoutPolicy.stacksActions(scale: scale) {
            stackedActions(scale: scale)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    copyDiagnosticsButton(scale: scale, expands: false)
                    Spacer(minLength: 12)
                    quitButton(scale: scale, expands: false)
                }
                .fixedSize(horizontal: true, vertical: false)

                stackedActions(scale: scale)
            }
        }
    }

    private func stackedActions(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            copyDiagnosticsButton(scale: scale, expands: true)
            quitButton(scale: scale, expands: true)
        }
    }

    private func copyDiagnosticsButton(scale: CGFloat, expands: Bool) -> some View {
        Button {
            if let copyDiagnosticsOverride {
                diagnosticsCopied = copyDiagnosticsOverride(diagnosticReason)
            } else {
                NSPasteboard.general.clearContents()
                diagnosticsCopied = NSPasteboard.general.setString(
                    diagnosticReason,
                    forType: .string
                )
            }
        } label: {
            Text(BootHaltPresentation.copyDiagnosticsLabel(locale: locale))
                .font(.cadenza(12, weight: .medium, scale: scale))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxWidth: expands ? .infinity : nil,
                    minHeight: BootHaltLayoutPolicy.minimumActionHeight(scale: scale),
                    alignment: .leading
                )
        }
        .background { geometryProbeView(for: .copyAction) }
    }

    private func quitButton(scale: CGFloat, expands: Bool) -> some View {
        Button {
            if let quitOverride {
                quitOverride()
            } else {
                NSApp.terminate(nil)
            }
        } label: {
            Text(BootHaltPresentation.quitLabel(locale: locale))
                .font(.cadenza(12, weight: .medium, scale: scale))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxWidth: expands ? .infinity : nil,
                    minHeight: BootHaltLayoutPolicy.minimumActionHeight(scale: scale),
                    alignment: .trailing
                )
        }
        .keyboardShortcut(.defaultAction)
        .background { geometryProbeView(for: .quitAction) }
    }

    @ViewBuilder
    private func geometryProbeView(for element: BootHaltGeometryProbe.Element) -> some View {
        if let geometryProbe {
            BootHaltGeometryProbeView(probe: geometryProbe, element: element)
        }
    }
}
