import AppKit
import SwiftUI

@MainActor
enum AppIconManager {
    static let userDefaultsKey = "appIconVariant"

    static func applySavedSelection() {
        let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        let variant = AppIconVariant(rawValue: rawValue) ?? .classic
        apply(variant: variant)
    }

    static func apply(variant: AppIconVariant) {
        guard let image = image(for: variant, pointSize: 512, scale: 2) else {
            NSLog("[AppIconManager] failed to render app icon for variant: %@", variant.rawValue)
            return
        }
        NSApp.applicationIconImage = image
    }

    static func image(
        for variant: AppIconVariant,
        pointSize: CGFloat = 88,
        scale: CGFloat = 2
    ) -> NSImage? {
        if let rendered = renderedImage(for: variant, pointSize: pointSize, scale: scale) {
            return rendered
        }
        if let bundledImage = NSImage(named: variant.assetName) {
            return bundledImage
        }
        return nil
    }

    static func renderedImage(
        for variant: AppIconVariant,
        pointSize: CGFloat = 88,
        scale: CGFloat = 2
    ) -> NSImage? {
        let renderer = ImageRenderer(
            content: AppIconArtwork(variant: variant)
                .frame(width: pointSize, height: pointSize)
        )
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.nsImage
    }

}

private extension AppIconVariant {
    var assetName: String {
        switch self {
        case .classic: "AppIconVariantClassic"
        case .sky: "AppIconVariantSky"
        case .mint: "AppIconVariantMint"
        case .peach: "AppIconVariantPeach"
        case .blossom: "AppIconVariantBlossom"
        case .honey: "AppIconVariantHoney"
        case .snow: "AppIconVariantSnow"
        case .lavender: "AppIconVariantLavender"
        case .slate: "AppIconVariantSlate"
        case .grove: "AppIconVariantGrove"
        case .ember: "AppIconVariantEmber"
        case .coral: "AppIconVariantCoral"
        }
    }
}

struct AppIconArtwork: View {
    let variant: AppIconVariant

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let palette = variant.palette
            let iconSize = size * 0.83
            let backgroundShape = RoundedRectangle(
                cornerRadius: iconSize * 0.209,
                style: .continuous
            )

            ZStack {
                backgroundShape
                    .fill(
                        LinearGradient(
                            colors: [palette.backgroundStart, palette.backgroundEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(palette.leadingGlow.opacity(0.09))
                    .frame(width: iconSize * 0.384, height: iconSize * 0.384)
                    .offset(x: -iconSize * 0.238, y: -iconSize * 0.273)

                Circle()
                    .fill(palette.trailingGlow.opacity(0.08))
                    .frame(width: iconSize * 0.472, height: iconSize * 0.472)
                    .offset(x: iconSize * 0.262, y: iconSize * 0.294)

                RoundedRectangle(cornerRadius: iconSize * 0.192, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [palette.plateStart, palette.plateEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: iconSize * 0.708, height: iconSize * 0.708)

                RoundedRectangle(cornerRadius: iconSize * 0.172, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.55),
                                Color.white.opacity(0.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: iconSize * 0.020
                    )
                    .frame(width: iconSize * 0.670, height: iconSize * 0.670)

                Circle()
                    .trim(from: 0.12, to: 0.88)
                    .stroke(
                        palette.glyph,
                        style: StrokeStyle(
                            lineWidth: iconSize * 0.160,
                            lineCap: .round
                        )
                    )
                    .frame(width: iconSize * 0.460, height: iconSize * 0.460)
                    .offset(x: -iconSize * 0.004)

                Circle()
                    .fill(palette.accent)
                    .frame(width: iconSize * 0.112, height: iconSize * 0.112)
                    .offset(x: iconSize * 0.174)
            }
            .frame(width: iconSize, height: iconSize)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(backgroundShape)
        }
        .aspectRatio(1, contentMode: .fit)
        .drawingGroup()
    }
}

private struct AppIconPalette {
    let backgroundStart: Color
    let backgroundEnd: Color
    let plateStart: Color
    let plateEnd: Color
    let leadingGlow: Color
    let trailingGlow: Color
    let glyph: Color
    let accent: Color
}

private extension AppIconVariant {
    var palette: AppIconPalette {
        switch self {
        case .classic:
            AppIconPalette(
                backgroundStart: Color(hex: "142B33"),
                backgroundEnd: Color(hex: "315159"),
                plateStart: Color(hex: "FFF4DD"),
                plateEnd: Color(hex: "F0DFC1"),
                leadingGlow: Color(hex: "7FCDBE"),
                trailingGlow: Color(hex: "F18A59"),
                glyph: Color(hex: "21424A"),
                accent: Color(hex: "F1794A")
            )
        case .sky:
            AppIconPalette(
                backgroundStart: Color(hex: "D6EEFF"),
                backgroundEnd: Color(hex: "B8D4F0"),
                plateStart: Color(hex: "FFFCF5"),
                plateEnd: Color(hex: "E6EEF5"),
                leadingGlow: Color(hex: "69B8F2"),
                trailingGlow: Color(hex: "F0A870"),
                glyph: Color(hex: "23475D"),
                accent: Color(hex: "E67942")
            )
        case .mint:
            AppIconPalette(
                backgroundStart: Color(hex: "D0F5E8"),
                backgroundEnd: Color(hex: "B8E8D0"),
                plateStart: Color(hex: "FFFDF4"),
                plateEnd: Color(hex: "E6F1E7"),
                leadingGlow: Color(hex: "6DC8AA"),
                trailingGlow: Color(hex: "EEA461"),
                glyph: Color(hex: "26473C"),
                accent: Color(hex: "DE7834")
            )
        case .peach:
            AppIconPalette(
                backgroundStart: Color(hex: "FFE4D6"),
                backgroundEnd: Color(hex: "F0D0B8"),
                plateStart: Color(hex: "FFF6EE"),
                plateEnd: Color(hex: "F0DFD2"),
                leadingGlow: Color(hex: "F2B699"),
                trailingGlow: Color(hex: "E58A62"),
                glyph: Color(hex: "5A3F35"),
                accent: Color(hex: "D86B41")
            )
        case .blossom:
            AppIconPalette(
                backgroundStart: Color(hex: "FFD6E8"),
                backgroundEnd: Color(hex: "F0B8D0"),
                plateStart: Color(hex: "FFF4F8"),
                plateEnd: Color(hex: "EFDFE8"),
                leadingGlow: Color(hex: "EEA1C1"),
                trailingGlow: Color(hex: "F08D67"),
                glyph: Color(hex: "593847"),
                accent: Color(hex: "D86451")
            )
        case .honey:
            AppIconPalette(
                backgroundStart: Color(hex: "FFF0C8"),
                backgroundEnd: Color(hex: "F0DCA0"),
                plateStart: Color(hex: "FFFCEC"),
                plateEnd: Color(hex: "F3E3C0"),
                leadingGlow: Color(hex: "E4C269"),
                trailingGlow: Color(hex: "E99854"),
                glyph: Color(hex: "5B4926"),
                accent: Color(hex: "D8792E")
            )
        case .snow:
            AppIconPalette(
                backgroundStart: Color(hex: "F5F5F7"),
                backgroundEnd: Color(hex: "E8E8EC"),
                plateStart: Color(hex: "FFFFFF"),
                plateEnd: Color(hex: "F0F1F5"),
                leadingGlow: Color(hex: "CAD0DD"),
                trailingGlow: Color(hex: "D9B29B"),
                glyph: Color(hex: "3F4652"),
                accent: Color(hex: "C96C47")
            )
        case .lavender:
            AppIconPalette(
                backgroundStart: Color(hex: "E8DEFF"),
                backgroundEnd: Color(hex: "D4C4F0"),
                plateStart: Color(hex: "FBF6FF"),
                plateEnd: Color(hex: "ECE4F5"),
                leadingGlow: Color(hex: "BEA6ED"),
                trailingGlow: Color(hex: "F0A36B"),
                glyph: Color(hex: "473A5D"),
                accent: Color(hex: "D76E4B")
            )
        case .slate:
            AppIconPalette(
                backgroundStart: Color(hex: "1A2635"),
                backgroundEnd: Color(hex: "4B6882"),
                plateStart: Color(hex: "F6EEDD"),
                plateEnd: Color(hex: "E3D6C6"),
                leadingGlow: Color(hex: "8BBEE4"),
                trailingGlow: Color(hex: "F0B26A"),
                glyph: Color(hex: "223442"),
                accent: Color(hex: "E97D42")
            )
        case .grove:
            AppIconPalette(
                backgroundStart: Color(hex: "152B24"),
                backgroundEnd: Color(hex: "38614C"),
                plateStart: Color(hex: "FFF2DA"),
                plateEnd: Color(hex: "EAD9BA"),
                leadingGlow: Color(hex: "8FD1B2"),
                trailingGlow: Color(hex: "E3A157"),
                glyph: Color(hex: "213B31"),
                accent: Color(hex: "D97732")
            )
        case .ember:
            AppIconPalette(
                backgroundStart: Color(hex: "33201B"),
                backgroundEnd: Color(hex: "704639"),
                plateStart: Color(hex: "FFF0E1"),
                plateEnd: Color(hex: "F1D6BD"),
                leadingGlow: Color(hex: "F2B18F"),
                trailingGlow: Color(hex: "D96A4C"),
                glyph: Color(hex: "4A2B21"),
                accent: Color(hex: "D95B3C")
            )
        case .coral:
            AppIconPalette(
                backgroundStart: Color(hex: "FFD0D6"),
                backgroundEnd: Color(hex: "F0B8C0"),
                plateStart: Color(hex: "FFF4F5"),
                plateEnd: Color(hex: "F1DEE2"),
                leadingGlow: Color(hex: "F1A1AF"),
                trailingGlow: Color(hex: "EB8B5E"),
                glyph: Color(hex: "593A40"),
                accent: Color(hex: "D95F47")
            )
        }
    }
}
