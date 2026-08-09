import AppKit
import Foundation
import SwiftUI

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

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

private struct AppIconArtwork: View {
    let palette = AppIconPalette(
        backgroundStart: Color(hex: "142B33"),
        backgroundEnd: Color(hex: "315159"),
        plateStart: Color(hex: "FFF4DD"),
        plateEnd: Color(hex: "F0DFC1"),
        leadingGlow: Color(hex: "7FCDBE"),
        trailingGlow: Color(hex: "F18A59"),
        glyph: Color(hex: "21424A"),
        accent: Color(hex: "F1794A")
    )

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
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

@MainActor
private func writeIcon(to url: URL, pixels: CGFloat) throws {
    let renderer = ImageRenderer(
        content: AppIconArtwork()
            .frame(width: pixels, height: pixels)
    )
    renderer.scale = 1
    renderer.isOpaque = false

    guard let image = renderer.nsImage else {
        throw NSError(domain: "GeneratePrimaryAppIcon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to render \(url.lastPathComponent)"
        ])
    }
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GeneratePrimaryAppIcon", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Failed to encode \(url.lastPathComponent) as PNG"
        ])
    }

    try pngData.write(to: url)
}

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let appIconSetURL = repositoryRoot
    .appendingPathComponent("Cadenza/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let iconFiles: [(filename: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for iconFile in iconFiles {
    try await MainActor.run {
        try writeIcon(to: appIconSetURL.appendingPathComponent(iconFile.filename), pixels: iconFile.pixels)
    }
}
