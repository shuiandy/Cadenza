import SwiftUI

// MARK: - Environment value

/// Multiplier applied to font sizes through `Font.cadenza(_:scale:)`.
/// Default `1.0` means no scaling.
///
/// Set at the workspace root (`MainWindow.body`) from the user's
/// `uiScale` preference. The earlier implementation wrapped every font
/// call site in a `ViewModifier` that read this env value itself — that
/// added ~450 extra wrapper views to the view tree, which made SwiftUI's
/// transition diffing visibly slow (~280ms extra latency between a
/// settings dismiss click and the destination switch, observed
/// 2026-05-12). The current pattern is: each view declares
/// `@Environment(\.uiScale)` once and threads `scale: uiScale` into
/// every `Font.cadenza` call inside its body. No wrapper view per font
/// call site.
private struct UIScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleEnvironmentKey.self] }
        set { self[UIScaleEnvironmentKey.self] = newValue }
    }
}

// MARK: - Accessibility scale bridge

/// Converts SwiftUI's Dynamic Type category into the multiplier used by
/// Cadenza's numeric system fonts. Hard-coded `.system(size:)` fonts do not
/// scale by themselves on macOS; applying this once at the workspace root lets
/// the existing font factory honor the system accessibility category without
/// adding hundreds of per-font wrapper views.
enum CadenzaTextScale {
    static func factor(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.82
        case .small: 0.88
        case .medium: 0.94
        case .large: 1.0
        case .xLarge: 1.12
        case .xxLarge: 1.23
        case .xxxLarge: 1.35
        case .accessibility1: 1.64
        case .accessibility2: 1.82
        case .accessibility3: 2.05
        case .accessibility4: 2.35
        case .accessibility5: 2.70
        @unknown default: 1.0
        }
    }

    static func combined(uiScale: CGFloat, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let productScale = uiScale.isFinite && uiScale > 0 ? uiScale : 1.0
        return productScale * factor(dynamicTypeSize)
    }
}

// MARK: - Scaled control geometry

/// Keeps fixed-looking square controls large enough for Cadenza's numeric
/// fonts at accessibility sizes. A fixed 24/32pt frame clips SF Symbols once
/// the effective UI scale reaches the supported 3.105x maximum.
enum CadenzaControlMetrics {
    /// SF Symbols can render beyond the nominal point size in one axis. This
    /// multiplier reflects the largest real symbol fitting-size probe used by
    /// Cadenza while preserving the existing 24/32pt controls at scale 1.
    private static let symbolExtentFactor: CGFloat = 1.3

    static func squareIconFrame(
        base: CGFloat,
        symbolPointSize: CGFloat,
        scale: CGFloat,
        padding: CGFloat = 12
    ) -> CGFloat {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        let symbolExtent = symbolPointSize * safeScale * symbolExtentFactor
        return max(base, ceil(symbolExtent + padding))
    }
}

// MARK: - Font factory

extension Font {
    /// System font whose point size is `size * scale`. Drop-in for
    /// `.font(.system(size:weight:design:))` with a multiplier read from
    /// the caller's `\.uiScale` environment value.
    ///
    /// Usage in a SwiftUI view:
    /// ```swift
    /// struct Row: View {
    ///     @Environment(\.uiScale) private var uiScale
    ///     var body: some View {
    ///         Text("hello").font(.cadenza(13, weight: .semibold, scale: uiScale))
    ///     }
    /// }
    /// ```
    static func cadenza(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .rounded,
        scale: CGFloat = 1.0
    ) -> Font {
        .system(size: size * scale, weight: weight, design: design)
    }

    /// Semantic-style variant. Resolves `style` against macOS-standard
    /// point sizes and natural weights (e.g. `.headline` → 13pt semibold),
    /// then multiplies the size by `scale`. Use this instead of
    /// `.font(.body)` so the UI Scale picker affects semantic text too —
    /// macOS does not honor `\.dynamicTypeSize` for Cadenza's hardcoded
    /// font patterns, so the literal point sizes here are the only
    /// adjustable lever.
    static func cadenza(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .rounded,
        scale: CGFloat = 1.0
    ) -> Font {
        let (size, defaultWeight) = ScaledFontDefaults.attributes(for: style)
        return .system(size: size * scale, weight: weight ?? defaultWeight, design: design)
    }

    /// 阅读型长正文专用：固定 `.default`（SF Pro Text），不随 `cadenza` 的圆体默认走。
    /// 用于转录逐字稿、AI 摘要正文、chat 消息/流式正文 —— 长段落可读性与专业感优先。
    /// UI chrome（按钮/标题/label/输入栏/数字/meta）一律用 `cadenza`（圆体）。
    static func cadenzaBody(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        scale: CGFloat = 1.0
    ) -> Font {
        .system(size: size * scale, weight: weight, design: .default)
    }

    /// `cadenzaBody` 的语义 style 变体，对齐 `cadenza(_:weight:scale:)`。
    static func cadenzaBody(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        scale: CGFloat = 1.0
    ) -> Font {
        let (size, defaultWeight) = ScaledFontDefaults.attributes(for: style)
        return .system(size: size * scale, weight: weight ?? defaultWeight, design: .default)
    }
}

/// macOS-standard point size and natural weight for each semantic
/// `Font.TextStyle`. Hardcoded because the SwiftUI runtime doesn't expose
/// per-platform style metrics. Values come from Apple's HIG / SwiftUI
/// font catalog (macOS 14+).
private enum ScaledFontDefaults {
    static func attributes(for style: Font.TextStyle) -> (CGFloat, Font.Weight) {
        switch style {
        case .largeTitle:  return (26, .regular)
        case .title:       return (22, .regular)
        case .title2:      return (17, .regular)
        case .title3:      return (15, .regular)
        case .headline:    return (13, .semibold)
        case .body:        return (13, .regular)
        case .callout:     return (12, .regular)
        case .subheadline: return (11, .regular)
        case .footnote:    return (10, .regular)
        case .caption:     return (10, .regular)
        case .caption2:    return (10, .regular)
        @unknown default:  return (13, .regular)
        }
    }
}
