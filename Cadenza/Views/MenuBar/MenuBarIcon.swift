import AppKit
import SwiftUI

struct MenuBarIcon: View {
    let state: RecordingState
    let hasError: Bool

    var body: some View {
        Image(nsImage: iconImage)
            .renderingMode(.template)
            .accessibilityLabel(resolvedAccessibilityLabel)
            .help(resolvedAccessibilityLabel)
    }

    private var iconImage: NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            platePath.fill()

            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            cCutoutPath.stroke()
            indicatorPath.fill()

            return true
        }
        image.isTemplate = true
        image.size = size
        return image
    }

    private var platePath: NSBezierPath {
        NSBezierPath(
            roundedRect: NSRect(x: 2.6, y: 1.1, width: 16.8, height: 15.8),
            xRadius: 4.7,
            yRadius: 4.7
        )
    }

    private var indicatorYOffset: CGFloat { 0.85 }
    private var indicatorXOffset: CGFloat { 2.2 }

    private var indicatorPath: NSBezierPath {
        if hasError {
            let path = NSBezierPath()
            path.append(
                NSBezierPath(
                    roundedRect: NSRect(
                        x: 11.55 + indicatorXOffset,
                        y: 7.45 + indicatorYOffset,
                        width: 0.8,
                        height: 2.7
                    ),
                    xRadius: 0.4,
                    yRadius: 0.4
                )
            )
            path.append(
                NSBezierPath(
                    ovalIn: NSRect(
                        x: 11.5 + indicatorXOffset,
                        y: 6.15 + indicatorYOffset,
                        width: 0.9,
                        height: 0.9
                    )
                )
            )
            return path
        }

        switch state {
        case .idle:
            return NSBezierPath(ovalIn: NSRect(x: 11.25 + indicatorXOffset, y: 6.95 + indicatorYOffset, width: 1.8, height: 1.8))
        case .recording:
            return NSBezierPath(ovalIn: NSRect(x: 11.05 + indicatorXOffset, y: 6.8 + indicatorYOffset, width: 2.05, height: 2.05))
        case .paused:
            let path = NSBezierPath()
            path.append(
                NSBezierPath(
                    roundedRect: NSRect(x: 10.95 + indicatorXOffset, y: 6.3 + indicatorYOffset, width: 0.62, height: 3.45),
                    xRadius: 0.45,
                    yRadius: 0.45
                )
            )
            path.append(
                NSBezierPath(
                    roundedRect: NSRect(x: 11.95 + indicatorXOffset, y: 6.3 + indicatorYOffset, width: 0.62, height: 3.45),
                    xRadius: 0.45,
                    yRadius: 0.45
                )
            )
            return path
        case .transcribing:
            let path = NSBezierPath()
            path.append(
                NSBezierPath(
                    roundedRect: NSRect(x: 10.55 + indicatorXOffset, y: 7.0 + indicatorYOffset, width: 0.58, height: 1.95),
                    xRadius: 0.4,
                    yRadius: 0.4
                )
            )
            path.append(
                NSBezierPath(
                    roundedRect: NSRect(x: 11.45 + indicatorXOffset, y: 6.15 + indicatorYOffset, width: 0.58, height: 3.75),
                    xRadius: 0.4,
                    yRadius: 0.4
                )
            )
            path.append(
                NSBezierPath(
                    roundedRect: NSRect(x: 12.35 + indicatorXOffset, y: 6.75 + indicatorYOffset, width: 0.58, height: 2.6),
                    xRadius: 0.4,
                    yRadius: 0.4
                )
            )
            return path
        case .summarizing:
            let spark = NSBezierPath()
            spark.move(to: NSPoint(x: 11.9 + indicatorXOffset, y: 10.45 + indicatorYOffset))
            spark.line(to: NSPoint(x: 12.2 + indicatorXOffset, y: 9.45 + indicatorYOffset))
            spark.line(to: NSPoint(x: 13.05 + indicatorXOffset, y: 9.1 + indicatorYOffset))
            spark.line(to: NSPoint(x: 12.2 + indicatorXOffset, y: 8.75 + indicatorYOffset))
            spark.line(to: NSPoint(x: 11.9 + indicatorXOffset, y: 7.75 + indicatorYOffset))
            spark.line(to: NSPoint(x: 11.6 + indicatorXOffset, y: 8.75 + indicatorYOffset))
            spark.line(to: NSPoint(x: 10.75 + indicatorXOffset, y: 9.1 + indicatorYOffset))
            spark.line(to: NSPoint(x: 11.6 + indicatorXOffset, y: 9.45 + indicatorYOffset))
            spark.close()
            return spark
        }
    }

    private var cCutoutPath: NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 3.1
        path.lineCapStyle = .round
        path.appendArc(
            withCenter: NSPoint(x: 11.1, y: 9.0),
            radius: 4.35,
            startAngle: 46,
            endAngle: 314,
            clockwise: false
        )
        return path
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle:
            return String(localized: "Cadenza")
        case .recording:
            return String(localized: "Cadenza recording")
        case .paused:
            return String(localized: "Cadenza paused")
        case .transcribing:
            return String(localized: "Cadenza transcribing")
        case .summarizing:
            return String(localized: "Cadenza summarizing")
        }
    }

    private var resolvedAccessibilityLabel: String {
        guard hasError else { return accessibilityLabel }
        return accessibilityLabel + ", " + String(localized: "Recording Error")
    }
}
