import SwiftUI

// MARK: - Summary Detail Level

enum SummaryDetailLevel: String, CaseIterable, Sendable {
    case highlights
    case detailed
    case fullBreakdown

    var displayName: String {
        switch self {
        case .highlights: String(localized: "Highlights Only")
        case .detailed: String(localized: "Detailed")
        case .fullBreakdown: String(localized: "Full Breakdown")
        }
    }

    var description: String {
        switch self {
        case .highlights: String(localized: "Key points and action items only")
        case .detailed: String(localized: "Key points, decisions, and follow-ups")
        case .fullBreakdown: String(localized: "Comprehensive analysis with full context")
        }
    }
}

// MARK: - App Theme

enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

// MARK: - App Icon Variant

enum AppIconVariant: String, CaseIterable, Identifiable, Sendable {
    case classic
    case sky
    case mint
    case peach
    case blossom
    case honey
    case snow
    case lavender
    case slate
    case grove
    case ember
    case coral

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: String(localized: "Classic")
        case .sky: String(localized: "Sky")
        case .mint: String(localized: "Mint")
        case .peach: String(localized: "Peach")
        case .blossom: String(localized: "Blossom")
        case .honey: String(localized: "Honey")
        case .snow: String(localized: "Snow")
        case .lavender: String(localized: "Lavender")
        case .slate: String(localized: "Slate")
        case .grove: String(localized: "Grove")
        case .ember: String(localized: "Ember")
        case .coral: String(localized: "Coral")
        }
    }

    var description: String {
        switch self {
        case .classic: String(localized: "Original teal plate")
        case .sky: String(localized: "Soft sky blue")
        case .mint: String(localized: "Light mint glass")
        case .peach: String(localized: "Warm peach glow")
        case .blossom: String(localized: "Powder pink")
        case .honey: String(localized: "Muted honey gold")
        case .snow: String(localized: "Cool silver white")
        case .lavender: String(localized: "Powder lavender")
        case .slate: String(localized: "Cool steel blue")
        case .grove: String(localized: "Deep moss green")
        case .ember: String(localized: "Warm copper red")
        case .coral: String(localized: "Rosy coral tint")
        }
    }
}

// MARK: - UI Scale

/// Coarse "UI scale" preset for the workspace.
///
/// Applied at the workspace root via the `\.uiScale` environment value
/// (see `ScaledFont.swift`), which the `Font.cadenza(_:scale:)` factory reads
/// to multiply hardcoded point sizes. The scaling is local to Cadenza —
/// SwiftUI's `.dynamicTypeSize(_:)` is a no-op on macOS for
/// `.font(.system(size: N))`-style sites, and the older
/// `.scaleEffect`-based implementation broke hit-testing across the
/// bottom of the window (2026-05-12). The font-multiplier path scales
/// fonts and SF Symbol icon sizes without touching layout geometry, so
/// hit-testing stays correct.
enum UIScalePreset: String, CaseIterable, Sendable {
    case compact
    case `default`
    case large

    var displayName: String {
        switch self {
        case .compact: String(localized: "Compact")
        case .default: String(localized: "Default")
        case .large: String(localized: "Large")
        }
    }

    var scaleFactor: CGFloat {
        switch self {
        case .compact: 0.9
        case .default: 1.0
        case .large: 1.15
        }
    }
}

// MARK: - Background Theme

enum BackgroundTheme: String, CaseIterable, Identifiable, Sendable {
    case none
    case skyBlue
    case lavender
    case mintFresh
    case aquaLight
    case peachBlossom
    case cherryBlossom
    case lemonZest
    case coralReef
    case honeyGold
    case pureSnow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: String(localized: "Default")
        case .skyBlue: String(localized: "Sky Blue")
        case .lavender: String(localized: "Lavender Dream")
        case .mintFresh: String(localized: "Mint Fresh")
        case .aquaLight: String(localized: "Aqua Light")
        case .peachBlossom: String(localized: "Peach Blossom")
        case .cherryBlossom: String(localized: "Cherry Blossom")
        case .lemonZest: String(localized: "Lemon Zest")
        case .coralReef: String(localized: "Coral Reef")
        case .honeyGold: String(localized: "Honey Gold")
        case .pureSnow: String(localized: "Pure Snow")
        }
    }

    /// Light-mode gradient colors (top-left → bottom-right)
    var lightColors: [Color] {
        switch self {
        case .none: []
        case .skyBlue: [Color(hex: "D6EEFF"), Color(hex: "B8D4F0")]
        case .lavender: [Color(hex: "E8DEFF"), Color(hex: "D4C4F0")]
        case .mintFresh: [Color(hex: "D0F5E8"), Color(hex: "B8E8D0")]
        case .aquaLight: [Color(hex: "CCF2F8"), Color(hex: "B0E8F0")]
        case .peachBlossom: [Color(hex: "FFE4D6"), Color(hex: "F0D0B8")]
        case .cherryBlossom: [Color(hex: "FFD6E8"), Color(hex: "F0B8D0")]
        case .lemonZest: [Color(hex: "FFF8D0"), Color(hex: "F0E8B0")]
        case .coralReef: [Color(hex: "FFD0D6"), Color(hex: "F0B8C0")]
        case .honeyGold: [Color(hex: "FFF0C8"), Color(hex: "F0DCA0")]
        case .pureSnow: [Color(hex: "F5F5F7"), Color(hex: "E8E8EC")]
        }
    }

    /// Dark-mode gradient colors (subtler, darker tints)
    var darkColors: [Color] {
        switch self {
        case .none: []
        case .skyBlue: [Color(hex: "1A2A3A"), Color(hex: "15253A")]
        case .lavender: [Color(hex: "2A1F3A"), Color(hex: "251A38")]
        case .mintFresh: [Color(hex: "1A302A"), Color(hex: "152A25")]
        case .aquaLight: [Color(hex: "1A2E32"), Color(hex: "152830")]
        case .peachBlossom: [Color(hex: "3A2820"), Color(hex: "35221A")]
        case .cherryBlossom: [Color(hex: "3A1F2A"), Color(hex: "351A28")]
        case .lemonZest: [Color(hex: "32301A"), Color(hex: "2D2A15")]
        case .coralReef: [Color(hex: "3A2022"), Color(hex: "351A1E")]
        case .honeyGold: [Color(hex: "352D18"), Color(hex: "302815")]
        case .pureSnow: [Color(hex: "222224"), Color(hex: "1E1E20")]
        }
    }

    /// Tint color for glass panels (light mode) — subtler than background gradient
    var lightGlassTint: Color {
        switch self {
        case .none: .clear
        case .skyBlue: Color(hex: "A8D4F0").opacity(0.25)
        case .lavender: Color(hex: "C4B0E8").opacity(0.25)
        case .mintFresh: Color(hex: "A0D8C0").opacity(0.25)
        case .aquaLight: Color(hex: "90D8E8").opacity(0.25)
        case .peachBlossom: Color(hex: "F0C0A0").opacity(0.25)
        case .cherryBlossom: Color(hex: "F0A0C0").opacity(0.25)
        case .lemonZest: Color(hex: "E8D890").opacity(0.25)
        case .coralReef: Color(hex: "F0A0A8").opacity(0.25)
        case .honeyGold: Color(hex: "E8C880").opacity(0.25)
        case .pureSnow: Color(hex: "D0D0D4").opacity(0.15)
        }
    }

    /// Tint color for glass panels (dark mode)
    var darkGlassTint: Color {
        switch self {
        case .none: .clear
        case .skyBlue: Color(hex: "4080B0").opacity(0.2)
        case .lavender: Color(hex: "7050A0").opacity(0.2)
        case .mintFresh: Color(hex: "408070").opacity(0.2)
        case .aquaLight: Color(hex: "407888").opacity(0.2)
        case .peachBlossom: Color(hex: "B07050").opacity(0.2)
        case .cherryBlossom: Color(hex: "B05070").opacity(0.2)
        case .lemonZest: Color(hex: "A09040").opacity(0.2)
        case .coralReef: Color(hex: "B05058").opacity(0.2)
        case .honeyGold: Color(hex: "A08830").opacity(0.2)
        case .pureSnow: Color(hex: "606068").opacity(0.12)
        }
    }
}

// MARK: - Calendar Colors

enum CalendarColorOption: String, CaseIterable, Sendable {
    case red, orange, yellow, green, cyan, blue, indigo, purple, pink

    var localizedName: String {
        localizedName(locale: nil)
    }

    func localizedName(locale: Locale?) -> String {
        switch self {
        case .red: LocalizedBundle.string("Red", locale: locale)
        case .orange: LocalizedBundle.string("Orange", locale: locale)
        case .yellow: LocalizedBundle.string("Yellow", locale: locale)
        case .green: LocalizedBundle.string("Green", locale: locale)
        case .cyan: LocalizedBundle.string("Cyan", locale: locale)
        case .blue: LocalizedBundle.string("Blue", locale: locale)
        case .indigo: LocalizedBundle.string("Indigo", locale: locale)
        case .purple: LocalizedBundle.string("Purple", locale: locale)
        case .pink: LocalizedBundle.string("Pink", locale: locale)
        }
    }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        }
    }
}

extension CalendarSource {
    var defaultColorOption: CalendarColorOption {
        switch self {
        case .apple: .red
        case .google: .blue
        case .zoom: .indigo
        }
    }

    var colorOption: CalendarColorOption {
        let raw = UserDefaults.standard.string(forKey: "calendarColor.\(rawValue)")
            ?? defaultColorOption.rawValue
        return CalendarColorOption(rawValue: raw) ?? defaultColorOption
    }

    var userColor: Color {
        colorOption.color
    }
}

// MARK: - App Language

enum AppLanguage: String, CaseIterable, Sendable {
    case system = "system"
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"

    var displayName: String {
        switch self {
        case .system: String(localized: "System Default")
        case .english: "English"
        case .chinese: "简体中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        }
    }

    /// Apply this language override. Call on app launch and when user changes setting.
    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
