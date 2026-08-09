import SwiftUI
import AppKit

/// Lightweight, app-wide transient notification surface used for
/// non-blocking feedback (export succeeded, export failed, etc.).
///
/// Design intent (from user feedback 2026-05-08): the prior export-failed
/// alert blocked the workspace AND showed the unreadable string
/// `Cadenza.CadenzaAPIError 错误 0`; export-succeeded had no feedback at
/// all. A toast addresses both: dismissable, non-modal, top-anchored
/// (so it does not collide with the FloatingAIChatButton at
/// bottomTrailing), auto-dismisses on a duration that scales with
/// severity (errors stay longer so the user can read).

// MARK: - Model

enum ToastKind: Equatable, Sendable {
    case success
    case error
    case info

    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return .green
        case .error:   return .red
        case .info:    return .accentColor
        }
    }

    /// How long the toast stays on screen by default. Errors get a
    /// longer dwell so the reader can absorb the message; success
    /// confirmations don't need to linger.
    var defaultDuration: Duration {
        switch self {
        case .error: return .seconds(10)
        case .success, .info: return .seconds(3)
        }
    }
}

struct Toast: Identifiable, Equatable, Sendable {
    let id = UUID()
    let kind: ToastKind
    let title: String
    let subtitle: String?

    init(kind: ToastKind, title: String, subtitle: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }
}

// MARK: - Center

/// App-singleton `@Observable` toast queue. Only one toast is visible at
/// a time; `show(...)` replaces any current toast (cancelling its
/// auto-dismiss) so a freshly-arriving error doesn't get hidden behind
/// a still-fading success. Callers stamp the toast's lifetime — the
/// center owns the dismissal timer.
///
/// `@MainActor` because `current` drives a SwiftUI body and the
/// dismissal Task touches it from inside an actor hop.
@Observable
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var current: Toast?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Convenience: success toast with the given title.
    func success(_ title: String, subtitle: String? = nil) {
        show(Toast(kind: .success, title: title, subtitle: subtitle))
    }

    /// Convenience: error toast with the given title.
    func error(_ title: String, subtitle: String? = nil) {
        show(Toast(kind: .error, title: title, subtitle: subtitle))
    }

    /// Display `toast`, replacing any in-flight toast. Auto-dismisses
    /// after `toast.kind.defaultDuration` unless replaced earlier.
    /// Posts a VoiceOver announcement so screen-reader users actually
    /// hear new toasts arrive (without it the capsule is only
    /// discoverable, not announced — Codex review #1 round 1, P3).
    func show(_ toast: Toast) {
        dismissTask?.cancel()
        current = toast
        announceForVoiceOver(toast)
        let id = toast.id
        let duration = toast.kind.defaultDuration
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.current?.id == id {
                    self.current = nil
                }
            }
        }
    }

    /// Posts a non-blocking accessibility announcement so VoiceOver
    /// reads the toast text aloud. Errors get high priority so they
    /// interrupt whatever VoiceOver was speaking; success/info use
    /// default priority and queue politely.
    private func announceForVoiceOver(_ toast: Toast) {
        var text = toast.title
        if let subtitle = toast.subtitle, !subtitle.isEmpty {
            // Sentence separator is locale-specific (CJK uses "。", not ". ").
            text = String(localized: "\(text). \(subtitle)")
        }
        let priority: NSAccessibilityPriorityLevel = (toast.kind == .error) ? .high : .medium
        NSAccessibility.post(
            element: NSApp ?? NSObject(),
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: priority.rawValue
            ]
        )
    }

    /// Dismiss immediately (e.g., the user clicks the toast or
    /// navigates away). Cancels any pending auto-dismiss.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}

// MARK: - Overlay

/// SwiftUI overlay that renders the current toast (if any) as a top-
/// anchored capsule. Mount with `.overlay(alignment: .top) { ToastOverlay() }`
/// on the workspace's detail pane (see MainWorkspaceView). The capsule
/// uses `.regularMaterial` so it visibly floats above content without
/// requiring the caller to manage z-order.
struct ToastOverlay: View {    @Environment(\.uiScale) private var uiScale: CGFloat

    @State private var center = ToastCenter.shared

    var body: some View {
        ZStack {
            if let toast = center.current {
                ToastCapsule(toast: toast)
                    .onTapGesture { center.dismiss() }
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    // The id() forces SwiftUI to re-run the transition
                    // when one toast replaces another (same overlay
                    // slot, different content).
                    .id(toast.id)
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(center.current != nil)
        .animation(.spring(duration: 0.32, bounce: 0.18), value: center.current?.id)
    }
}

private struct ToastCapsule: View {
    @Environment(\.uiScale) private var uiScale: CGFloat

    let toast: Toast

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: toast.kind.iconName)
                .font(.cadenza(15, weight: .semibold, scale: uiScale))
                .foregroundStyle(toast.kind.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.cadenza(.subheadline, weight: .medium, scale: uiScale))
                    .lineLimit(toast.kind == .error ? 3 : 2)
                    .foregroundStyle(.primary)
                if let subtitle = toast.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.cadenza(.caption, scale: uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(toast.kind == .error ? 4 : 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .frame(maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.title)
        .accessibilityHint(toast.subtitle ?? "")
    }
}
