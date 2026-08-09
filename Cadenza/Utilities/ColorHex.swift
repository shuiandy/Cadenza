import AppKit
import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        if hex.count == 6 {
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        } else {
            r = 1; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }
}

enum AppStyle {
    enum Radius {
        static let card: CGFloat = 12
        static let bubble: CGFloat = 14
        static let chip: CGFloat = 10
        static let panel: CGFloat = 16
        static let rail: CGFloat = 14
    }

    enum ColorToken {
        static let stroke = Color.primary.opacity(0.08)
        static let softFill = Color.primary.opacity(0.03)
        static let assistantBubble = Color.primary.opacity(0.045)
        static let chipFill = Color.primary.opacity(0.045)
        static let chipBorder = Color.primary.opacity(0.09)
        static let controlFillActive = Color.primary.opacity(0.12)
        static let mutedCapsuleFill = Color.primary.opacity(0.065)
        static let mutedCapsuleStroke = Color.primary.opacity(0.12)
    }

}

// MARK: - Glass Tint Environment

private struct GlassTintKey: EnvironmentKey {
    static let defaultValue: Color = .clear
}

extension EnvironmentValues {
    var glassTint: Color {
        get { self[GlassTintKey.self] }
        set { self[GlassTintKey.self] = newValue }
    }
}

// 玻璃面的 availability 分支统一在 `PlatformCompatibility.swift`，本文件只消费 `cadenzaGlass`。

private struct AppCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let hovered: Bool
    @Environment(\.glassTint) private var glassTint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let hoverPresentation = AppCardHoverPolicy.presentation(
            hovered: hovered,
            reduceMotion: reduceMotion
        )
        // 玻璃面是渲染效果，不是绘制内容——不加 contentShape 的话整张卡片只有文字那几行
        // 参与 hit test，调用方紧随其后的 `.onHover` 也只在文字上触发。
        if glassTint == .clear {
            content
                .cadenzaGlass(in: shape)
                .contentShape(shape)
                .scaleEffect(hoverPresentation.scale)
                .offset(y: hoverPresentation.offsetY)
                .shadow(color: .black.opacity(hovered ? 0.12 : 0), radius: 12, y: 6)
                .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.16), value: hovered)
        } else {
            content
                .cadenzaGlass(in: shape, tint: glassTint)
                .contentShape(shape)
                .scaleEffect(hoverPresentation.scale)
                .offset(y: hoverPresentation.offsetY)
                .shadow(color: .black.opacity(hovered ? 0.12 : 0), radius: 12, y: 6)
                .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.16), value: hovered)
        }
    }
}

/// Lightweight surface for repeated collection cells. A recordings grid can
/// keep dozens of cells in the render graph at once; giving every cell its own
/// live glass sampler, hover transform, and shadow makes scrolling pay that
/// compositing cost over and over. Collection chrome stays intentionally flat
/// while panels and toolbar rails continue to use Liquid Glass.
private struct AppCollectionCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(AppStyle.ColorToken.assistantBubble))
            .overlay(shape.strokeBorder(AppStyle.ColorToken.stroke, lineWidth: 0.75))
    }
}

struct AppCardHoverPresentation: Equatable, Sendable {
    let scale: CGFloat
    let offsetY: CGFloat
}

enum AppCardHoverPolicy {
    static func presentation(hovered: Bool, reduceMotion: Bool) -> AppCardHoverPresentation {
        guard hovered, !reduceMotion else {
            return AppCardHoverPresentation(scale: 1, offsetY: 0)
        }
        return AppCardHoverPresentation(scale: 1.015, offsetY: -2)
    }
}

private struct AppGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.glassTint) private var glassTint

    // 玻璃在这里保持真正透明（采样环境背景，不垫任何本地底色）。
    // 超宽面板漏底的问题由 `AppStyle.maxWorkspacePanelWidth` 在调用侧限宽解决，
    // 不要往这个通用组件里塞不透明兜底——它同时服务 Recap / 设置 / 集成面板 / toolbar rail，
    // 垫了底就等于把全 app 的玻璃降级成“带玻璃效果的不透明面板”。
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if glassTint == .clear {
            content
                .cadenzaGlass(in: shape)
                .clipShape(shape)
        } else {
            content
                .cadenzaGlass(in: shape, tint: glassTint)
                .clipShape(shape)
        }
    }
}

/// 见 `View.appWorkspacePanel(cornerRadius:)` —— 实心内容面板，浮在半透明 chrome 之上。
private struct AppWorkspacePanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.glassTint) private var glassTint

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                // 文档区语义色：浅色下是纸白，深色下是接近黑的底，长正文读起来最稳。
                shape.fill(Color(nsColor: .textBackgroundColor))
                    // 背景主题的色调叠在上面（theme = none 时 glassTint 是 .clear，无影响）。
                    // 玻璃版靠 tint 跟主题走，实心版必须自己接，否则换主题面板纹丝不动。
                    .overlay(shape.fill(glassTint))
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(AppStyle.ColorToken.stroke, lineWidth: 0.75))
            // 浮起来的那一点距离感——层次靠它和实心底色，不靠玻璃。
            .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
    }
}

/// Reads the theme once and injects glassTint into the environment for all child views.
struct AppAmbientBackground: View {
    @AppStorage("backgroundTheme") private var theme: BackgroundTheme = .none
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = colorScheme == .dark ? theme.darkColors : theme.lightColors
        if colors.isEmpty {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
        } else {
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    /// The glass tint derived from the current theme + color scheme.
    var glassTintColor: Color {
        colorScheme == .dark ? theme.darkGlassTint : theme.lightGlassTint
    }
}

extension View {
    func appCard(cornerRadius: CGFloat = AppStyle.Radius.card, hovered: Bool = false) -> some View {
        modifier(AppCardModifier(cornerRadius: cornerRadius, hovered: hovered))
    }

    func appCollectionCard(cornerRadius: CGFloat = AppStyle.Radius.card) -> some View {
        modifier(AppCollectionCardModifier(cornerRadius: cornerRadius))
    }

    func appGlassPanel(cornerRadius: CGFloat = AppStyle.Radius.panel, accent: Color = .white) -> some View {
        modifier(AppGlassPanelModifier(cornerRadius: cornerRadius))
    }

    /// 铺满工作区的内容面板：**实心**，不用玻璃。
    ///
    /// 层次感来自「实心内容面板浮在半透明 chrome 之上」，而不是反过来——把大面积内容区
    /// 做成玻璃、拿不透明背景垫底，层次会整个塌掉（2026-08-07 对比 Craft 确认）。
    ///
    /// 实心还顺带绕开了 `glassEffect` 的渲染尺寸上限：面板宽到 ~1500pt（retina 3000px）时，
    /// 玻璃有一条根本不画，直接露出窗口本体、右下角见桌面（窄窗口不复现，空隙宽度随窗口
    /// 变宽而变宽，极易漏测）。实心背景没有这个问题，长正文的可读性也更好。
    ///
    /// 玻璃留给 sidebar / toolbar rail / 卡片这类小面积 chrome（`appGlassPanel`），
    /// 那些面积不会触顶。门禁见 `WorkspacePanelSizingTests`。
    func appWorkspacePanel(cornerRadius: CGFloat = AppStyle.Radius.panel) -> some View {
        modifier(AppWorkspacePanelModifier(cornerRadius: cornerRadius))
    }

    func appToolbarRail(cornerRadius: CGFloat = AppStyle.Radius.rail) -> some View {
        modifier(AppGlassPanelModifier(cornerRadius: cornerRadius))
    }
}

extension MeetingEvent {
    /// Resolved display color: per-calendar override > EKCalendar default > source fallback.
    var displayColor: Color {
        if !calendarID.isEmpty,
           let raw = UserDefaults.standard.string(forKey: "calColor.\(calendarID)") {
            if let option = CalendarColorOption(rawValue: raw) {
                return option.color
            }
            if raw.hasPrefix("#") {
                return Color(hex: raw)
            }
        }
        if !defaultColorHex.isEmpty {
            return Color(hex: defaultColorHex)
        }
        return source.userColor
    }
}
