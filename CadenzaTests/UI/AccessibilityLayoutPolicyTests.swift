import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Cadenza

@Suite("Accessibility layout policies")
struct AccessibilityLayoutPolicyTests {
    @Test func fixedIconControlsKeepTheirExistingDefaultScaleFrames() {
        #expect(
            CadenzaControlMetrics.squareIconFrame(
                base: 32,
                symbolPointSize: 15,
                scale: 1,
                padding: 12
            ) == 32
        )
        #expect(
            CadenzaControlMetrics.squareIconFrame(
                base: 24,
                symbolPointSize: 10,
                scale: 1,
                padding: 10
            ) == 24
        )
        #expect(
            CadenzaControlMetrics.squareIconFrame(
                base: 32,
                symbolPointSize: 15,
                scale: .nan,
                padding: 12
            ) == 32
        )
    }

    @MainActor @Test func fixedIconControlsContainRealSymbolsAtMaximumSupportedScale() {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )

        for probe in [
            (symbol: "square.grid.2x2", pointSize: CGFloat(15), base: CGFloat(32), padding: CGFloat(12)),
            (symbol: "sparkles", pointSize: CGFloat(10), base: CGFloat(24), padding: CGFloat(10)),
        ] {
            let glyphHost = NSHostingView(
                rootView: Image(systemName: probe.symbol)
                    .font(.cadenza(probe.pointSize, weight: .medium, scale: scale))
            )
            glyphHost.sizingOptions = [.intrinsicContentSize]
            glyphHost.layoutSubtreeIfNeeded()

            let frame = CadenzaControlMetrics.squareIconFrame(
                base: probe.base,
                symbolPointSize: probe.pointSize,
                scale: scale,
                padding: probe.padding
            )
            let glyphSize = glyphHost.fittingSize

            #expect(glyphSize.width.isFinite)
            #expect(glyphSize.height.isFinite)
            #expect(frame >= glyphSize.width + probe.padding)
            #expect(frame >= glyphSize.height + probe.padding)
        }
    }

    @Test func calendarUsesAgendaAtEveryAccessibilityTextSize() {
        let sizes: [DynamicTypeSize] = [
            .accessibility1,
            .accessibility2,
            .accessibility3,
            .accessibility4,
            .accessibility5,
        ]

        for size in sizes {
            #expect(
                CalendarAdaptiveLayoutPolicy.mode(
                    for: size,
                    effectiveScale: CadenzaTextScale.factor(size)
                ) == .agenda
            )
        }
    }

    @Test func calendarUsesEffectiveScaleToProtectShortEventText() {
        #expect(
            CalendarAdaptiveLayoutPolicy.mode(
                for: .large,
                effectiveScale: 1.0
            ) == .timeline
        )
        #expect(
            CalendarAdaptiveLayoutPolicy.mode(
                for: .xLarge,
                effectiveScale: CadenzaTextScale.factor(.xLarge)
            ) == .agenda
        )
        #expect(
            CalendarAdaptiveLayoutPolicy.mode(
                for: .xxLarge,
                effectiveScale: CadenzaTextScale.factor(.xxLarge)
            ) == .agenda
        )
        #expect(
            CalendarAdaptiveLayoutPolicy.mode(
                for: .large,
                effectiveScale: UIScalePreset.large.scaleFactor
            ) == .agenda
        )
        #expect(
            CalendarAdaptiveLayoutPolicy.mode(
                for: .xxxLarge,
                effectiveScale: 1.35 * 1.15
            ) == .agenda
        )
    }

    @MainActor @Test func defaultScaleCalendarEventBlockFitsThirtyMinuteSlot() {
        let startDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let event = MeetingEvent(
            id: "a11y-default-short-event",
            title: "Accessibility review with a long event title",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(30 * 60),
            meetingURL: nil,
            meetingApp: .zoom,
            calendarName: "Accessibility",
            notes: nil
        )
        let host = NSHostingView(
            rootView: CalendarEventBlock(event: event)
                .environment(\.uiScale, 1.0)
                .frame(width: 260)
        )

        // Against the real slot, not a duplicated constant — the block's type
        // sizes and `CalendarTimelineMetrics.hourHeight` are one decision.
        #expect(host.fittingSize.height <= CalendarTimelineMetrics.thirtyMinuteSlotHeight)
    }

    @Test func reduceMotionRemovesCardTranslationAndScaling() {
        let presentation = AppCardHoverPolicy.presentation(
            hovered: true,
            reduceMotion: true
        )

        #expect(presentation.scale == 1)
        #expect(presentation.offsetY == 0)
    }

    @Test func normalMotionKeepsHoverFeedback() {
        let presentation = AppCardHoverPolicy.presentation(
            hovered: true,
            reduceMotion: false
        )

        #expect(presentation.scale > 1)
        #expect(presentation.offsetY < 0)
    }

    @MainActor @Test func largeCalendarFallbacksRenderRealShortEventAtCompactWidth() {
        let selectedDate = Binding.constant(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let viewMode = Binding.constant(CalendarViewMode.month)
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: 1.15,
            dynamicTypeSize: .xxxLarge
        )

        let startDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let event = MeetingEvent(
            id: "a11y-short-event",
            title: "Accessibility review with a long event title",
            startDate: startDate,
            endDate: startDate.addingTimeInterval(30 * 60),
            meetingURL: nil,
            meetingApp: .zoom,
            calendarName: "Accessibility",
            notes: nil
        )
        let views = VStack(spacing: 0) {
            CalendarMonthView(
                selectedDate: selectedDate,
                events: [event],
                viewMode: viewMode
            )
            CalendarDayView(
                selectedDate: selectedDate,
                events: [event],
                onEventTap: { _ in }
            )
            CalendarWeekView(
                selectedDate: selectedDate,
                events: [event],
                onEventTap: { _ in }
            )
        }
        .environment(\.dynamicTypeSize, .xxxLarge)
        .environment(\.uiScale, effectiveScale)
        .frame(width: 480, height: 720)

        let renderer = ImageRenderer(content: views)
        renderer.proposedSize = ProposedViewSize(width: 480, height: 720)

        #expect(renderer.nsImage != nil)
    }
}

@Suite("Standalone recording overlay layout")
struct OverlayPanelLayoutTests {
    @MainActor @Test func micPromptUsesRealFittingSizeAtMaximumSupportedScale() {
        let baselineHost = makeMicPromptHost(
            productScale: UIScalePreset.default.scaleFactor,
            dynamicTypeSize: .large
        )
        let accessibilityHost = makeMicPromptHost(
            productScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )

        let baselineSize = baselineHost.fittingSize
        let accessibilitySize = accessibilityHost.fittingSize
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let largestControl = RecordingOverlayLayoutMetrics.controlDimension(
            base: 28,
            fontSize: 20,
            scale: effectiveScale
        )

        #expect(baselineSize.width.isFinite)
        #expect(baselineSize.height.isFinite)
        #expect(accessibilitySize.width.isFinite)
        #expect(accessibilitySize.height.isFinite)
        #expect(accessibilitySize.width > baselineSize.width)
        #expect(accessibilitySize.height > baselineSize.height)
        #expect(accessibilitySize.width > 280)
        #expect(accessibilitySize.height > 56)
        #expect(accessibilitySize.height >= largestControl + 20)
    }

    @MainActor @Test func regularOverlayControlFrameFitsItsScaledSymbol() {
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let root = RecordingOverlayRoot(productScaleOverride: UIScalePreset.large.scaleFactor) {
            OverlayCircleButton(icon: "stop.fill", action: {})
        }
        .environment(\.dynamicTypeSize, .accessibility5)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()

        let size = host.fittingSize
        let expectedControlSize = RecordingOverlayLayoutMetrics.controlDimension(
            base: 28,
            fontSize: 12,
            scale: effectiveScale
        )

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.width >= expectedControlSize)
        #expect(size.height >= expectedControlSize)
    }

    @MainActor @Test func expandedCompactBarKeepsEveryActionTargetInsideAtMaximumScale() throws {
        let productScale = UIScalePreset.large.scaleFactor
        let dynamicTypeSize = DynamicTypeSize.accessibility5
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: productScale,
            dynamicTypeSize: dynamicTypeSize
        )
        let barWidth = RecordingOverlayLayoutMetrics.expandedOverlayWidth(scale: effectiveScale)
        let controlSize = RecordingOverlayLayoutMetrics.controlDimension(
            base: 28,
            fontSize: 12,
            scale: effectiveScale
        )
        let microphoneProbe = OverlayActionFrameProbe()
        let pauseProbe = OverlayActionFrameProbe()
        let stopProbe = OverlayActionFrameProbe()

        let root = RecordingOverlayRoot(productScaleOverride: productScale) {
            RecordingCompactBarLayout(showsActions: true) {
                Image(systemName: "chevron.down")
                    .font(.cadenza(12, weight: .semibold, scale: effectiveScale))
                    .frame(width: controlSize, height: controlSize)
            } duration: {
                Text("99:59")
                    .font(.cadenza(15, weight: .semibold, design: .monospaced, scale: effectiveScale))
            } status: {
                Text("Quarterly accessibility review with a deliberately unbounded meeting title")
                    .font(.cadenza(12, scale: effectiveScale))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        maxWidth: RecordingOverlayLayoutMetrics.compactStatusMaximumWidth(
                            scale: effectiveScale
                        ),
                        alignment: .leading
                    )
            } actions: {
                HStack(spacing: 10) {
                    overlayActionButton(probe: microphoneProbe, size: controlSize, icon: "mic.fill")
                    overlayActionButton(probe: pauseProbe, size: controlSize, icon: "pause.fill")
                    overlayActionButton(probe: stopProbe, size: controlSize, icon: "stop.fill")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: barWidth)
        }
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = SwiftUI.NSHostingSizingOptions.intrinsicContentSize
        host.layoutSubtreeIfNeeded()
        let fittingSize = host.fittingSize
        let panel = RecordingOverlayPanel(contentView: host, size: fittingSize)
        defer { panel.close() }
        host.frame = NSRect(origin: .zero, size: fittingSize)
        host.layoutSubtreeIfNeeded()

        #expect(fittingSize.width.isFinite)
        #expect(fittingSize.height.isFinite)
        #expect(fittingSize.width <= barWidth)
        #expect(fittingSize.height >= controlSize * 2 + 10 + 24)

        for probe in [microphoneProbe, pauseProbe, stopProbe] {
            let view = try #require(probe.view)
            let frame = view.convert(view.bounds, to: host)

            #expect(frame.width >= controlSize)
            #expect(frame.height >= controlSize)
            #expect(host.bounds.contains(frame))

            let localCenter = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            #expect(view.hitTest(localCenter) === view)
            #expect(host.hitTest(NSPoint(x: frame.midX, y: frame.midY)) != nil)
        }
    }

    @MainActor @Test func resizeKeepingTopCenterConstrainsEdgePanelsToVisibleFrame() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let visibleFrame = screen.visibleFrame
        #expect(visibleFrame.width > 400)
        #expect(visibleFrame.height > 400)

        let initialSize = NSSize(width: 240, height: 56)
        let expandedSize = NSSize(
            width: min(670, visibleFrame.width - 24),
            height: min(620, visibleFrame.height - 24)
        )
        let topY = visibleFrame.maxY - initialSize.height - 12
        let origins = [
            NSPoint(x: visibleFrame.minX + 2, y: topY),
            NSPoint(x: visibleFrame.maxX - initialSize.width - 2, y: topY),
            NSPoint(x: visibleFrame.midX - initialSize.width / 2, y: visibleFrame.minY + 2),
        ]

        for origin in origins {
            let contentView = NSView(frame: NSRect(origin: .zero, size: initialSize))
            let panel = RecordingOverlayPanel(contentView: contentView, size: initialSize)
            defer { panel.close() }
            panel.setFrame(NSRect(origin: origin, size: initialSize), display: false)

            panel.resizeKeepingTopCenter(to: expandedSize)

            #expect(visibleFrame.contains(panel.frame))
            #expect(panel.frame.size == expandedSize)
            #expect(contentView.frame.size == expandedSize)
        }
    }

    @MainActor @Test func expandedNotchAddsAccessibilityControlsBelowPhysicalTopRow() {
        let physicalNotchHeight: CGFloat = 32
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let controlSize = RecordingOverlayLayoutMetrics.controlDimension(
            base: 24,
            fontSize: 11,
            scale: effectiveScale
        )
        let root = RecordingOverlayRoot(productScaleOverride: UIScalePreset.large.scaleFactor) {
            NotchBelowHardwareLayout(physicalTopHeight: physicalNotchHeight, minWidth: 400) {
                Image(systemName: "pause.fill")
                    .font(.cadenza(11, weight: .semibold, scale: effectiveScale))
                    .frame(width: controlSize, height: controlSize)
            }
        }
        .environment(\.dynamicTypeSize, .accessibility5)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = SwiftUI.NSHostingSizingOptions.intrinsicContentSize
        host.layoutSubtreeIfNeeded()

        let size = host.fittingSize

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.width >= 400)
        #expect(size.height >= physicalNotchHeight + controlSize)
    }

    @MainActor @Test func notchAutoStopFitsLongestLocalizedLabelInsideHalfScreenPanel() throws {
        let productScale = UIScalePreset.large.scaleFactor
        let dynamicTypeSize = DynamicTypeSize.accessibility5
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: productScale,
            dynamicTypeSize: dynamicTypeSize
        )
        // A conservative half-screen notch panel (1280pt display), minus the
        // production view's 6pt outer and 16pt inner horizontal padding.
        let panelWidth: CGFloat = 640
        let contentWidth = panelWidth - 44
        let controlSize = RecordingOverlayLayoutMetrics.controlDimension(
            base: 24,
            fontSize: 11,
            scale: effectiveScale
        )
        let keepLabel = try longestLocalizedValue(
            for: "Keep Recording",
            pointSize: 11,
            scale: effectiveScale
        )
        let stopLabel = try longestLocalizedValue(
            for: "Stop",
            pointSize: 12,
            scale: effectiveScale
        )

        let legacyHost = NSHostingView(rootView: AnyView(
            HStack(spacing: 10) {
                simulatedNotchMicrophone(scale: effectiveScale, probe: OverlayActionFrameProbe())
                simulatedCountdown(
                    keepLabel: keepLabel,
                    scale: effectiveScale,
                    controlSize: controlSize,
                    probe: OverlayActionFrameProbe()
                )
                overlayActionButton(
                    probe: OverlayActionFrameProbe(),
                    size: controlSize,
                    icon: "pause.fill"
                )
                simulatedNotchStop(
                    label: stopLabel,
                    scale: effectiveScale,
                    probe: OverlayActionFrameProbe()
                )
            }
        ))
        legacyHost.sizingOptions = [.intrinsicContentSize]
        legacyHost.layoutSubtreeIfNeeded()
        #expect(
            legacyHost.fittingSize.width > contentWidth,
            "The probe must reproduce the prior single-row overflow"
        )

        let microphoneProbe = OverlayActionFrameProbe()
        let keepProbe = OverlayActionFrameProbe()
        let pauseProbe = OverlayActionFrameProbe()
        let stopProbe = OverlayActionFrameProbe()
        let root = RecordingOverlayRoot(productScaleOverride: productScale) {
            NotchActionControlsLayout(showsCountdown: true, scale: effectiveScale) {
                simulatedNotchMicrophone(scale: effectiveScale, probe: microphoneProbe)
            } countdown: {
                simulatedCountdown(
                    keepLabel: keepLabel,
                    scale: effectiveScale,
                    controlSize: controlSize,
                    probe: keepProbe
                )
            } transport: {
                HStack(spacing: 10) {
                    overlayActionButton(probe: pauseProbe, size: controlSize, icon: "pause.fill")
                    simulatedNotchStop(label: stopLabel, scale: effectiveScale, probe: stopProbe)
                }
            }
            .padding(.vertical, 10)
            .frame(width: contentWidth, alignment: .trailing)
        }
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        let fittingSize = host.fittingSize
        let panel = RecordingOverlayPanel(contentView: host, size: fittingSize)
        defer { panel.close() }
        host.frame = NSRect(origin: .zero, size: fittingSize)
        host.layoutSubtreeIfNeeded()

        #expect(fittingSize.width == contentWidth)
        #expect(fittingSize.height >= controlSize * 2 + 8 + 20)

        for probe in [microphoneProbe, keepProbe, pauseProbe, stopProbe] {
            let view = try #require(probe.view)
            let frame = view.convert(view.bounds, to: host)

            #expect(frame.width > 0)
            #expect(frame.height >= controlSize)
            #expect(host.bounds.contains(frame))
            #expect(host.hitTest(NSPoint(x: frame.midX, y: frame.midY)) != nil)
        }
    }

    @MainActor
    private func makeMicPromptHost(
        productScale: CGFloat,
        dynamicTypeSize: DynamicTypeSize
    ) -> NSHostingView<AnyView> {
        let root = RecordingOverlayRoot(productScaleOverride: productScale) {
            MicPromptOverlayView()
                .environment(AppState())
        }
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = SwiftUI.NSHostingSizingOptions.intrinsicContentSize
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func overlayActionButton(
        probe: OverlayActionFrameProbe,
        size: CGFloat,
        icon: String
    ) -> some View {
        Button(action: {}) {
            OverlayActionProbeView(probe: probe)
                .frame(width: size, height: size)
                .background {
                    Circle().fill(.primary.opacity(0.1))
                }
                .overlay {
                    Image(systemName: icon)
                }
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func simulatedNotchMicrophone(
        scale: CGFloat,
        probe: OverlayActionFrameProbe
    ) -> some View {
        Button(action: {}) {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .font(.cadenza(11, weight: .semibold, scale: scale))
                Image(systemName: "chevron.down")
                    .font(.cadenza(9, weight: .bold, scale: scale))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.primary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .background { OverlayActionProbeView(probe: probe) }
    }

    @MainActor
    private func simulatedCountdown(
        keepLabel: String,
        scale: CGFloat,
        controlSize: CGFloat,
        probe: OverlayActionFrameProbe
    ) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .font(.cadenza(10, scale: scale))
                Text("59s")
                    .font(.cadenza(11, weight: .semibold, design: .monospaced, scale: scale))
            }

            Button(action: {}) {
                Text(keepLabel)
                    .font(.cadenza(11, weight: .semibold, scale: scale))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: controlSize)
            .buttonStyle(.borderless)
            .background { OverlayActionProbeView(probe: probe) }
        }
    }

    @MainActor
    private func simulatedNotchStop(
        label: String,
        scale: CGFloat,
        probe: OverlayActionFrameProbe
    ) -> some View {
        Button(action: {}) {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.cadenza(10, weight: .bold, scale: scale))
                Text(label)
                    .font(.cadenza(12, weight: .semibold, scale: scale))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.red))
        }
        .buttonStyle(.plain)
        .background { OverlayActionProbeView(probe: probe) }
    }

    @MainActor
    private func longestLocalizedValue(
        for key: String,
        pointSize: CGFloat,
        scale: CGFloat
    ) throws -> String {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Cadenza/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let values = localizations.values.compactMap { localization -> String? in
            guard let localization = localization as? [String: Any],
                  let unit = localization["stringUnit"] as? [String: Any]
            else { return nil }
            return unit["value"] as? String
        } + [key]
        let longest = values.max { lhs, rhs in
            localizedTextWidth(lhs, pointSize: pointSize, scale: scale)
                < localizedTextWidth(rhs, pointSize: pointSize, scale: scale)
        }
        return try #require(longest)
    }

    @MainActor
    private func localizedTextWidth(
        _ value: String,
        pointSize: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        let host = NSHostingView(
            rootView: Text(value)
                .font(.cadenza(pointSize, weight: .semibold, scale: scale))
                .fixedSize()
        )
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }
}

@MainActor
private final class OverlayActionFrameProbe {
    var view: NSView?
}

@MainActor
private struct OverlayActionProbeView: NSViewRepresentable {
    let probe: OverlayActionFrameProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        probe.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@Suite("Export backup adaptive layout")
struct ExportBackupAdaptiveLayoutTests {
    private let contentWidth: CGFloat = 530
    private let effectiveScale = CadenzaTextScale.combined(
        uiScale: UIScalePreset.large.scaleFactor,
        dynamicTypeSize: .accessibility5
    )

    @Test func onlyAccessibilitySizesUseTheStackedLayout() {
        #expect(!ExportBackupAdaptiveLayoutPolicy.stacksControls(for: .large))
        #expect(!ExportBackupAdaptiveLayoutPolicy.stacksControls(for: .xxxLarge))
        #expect(ExportBackupAdaptiveLayoutPolicy.stacksControls(for: .accessibility1))
        #expect(ExportBackupAdaptiveLayoutPolicy.stacksControls(for: .accessibility5))
    }

    @MainActor @Test func legacyGermanAndFrenchRowsOverflowAtMaximumSupportedScale() {
        let checkboxHost = intrinsicHost(
            HStack(spacing: 14) {
                legacyCheckbox("Transkript (.txt)")
                legacyCheckbox("Untertitel (.srt)")
                legacyCheckbox("Transkript (.md)")
                legacyCheckbox("Zusammenfassung")
                legacyCheckbox("Audio")
            }
            .fixedSize()
        )
        let headerHost = intrinsicHost(
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Exporter toutes les données (archive portable)")
                    Text("Une sauvegarde vérifiable de chaque enregistrement, transcription, résumé et chat, audio inclus. Elle ne contient jamais de clés API ni de jetons de compte.")
                }
                .fixedSize()
                Spacer(minLength: 12)
                Button("Exporter une archive…", action: {})
                    .fixedSize()
            }
            .font(.cadenza(13, scale: effectiveScale))
            .fixedSize()
        )
        let resultHost = intrinsicHost(
            HStack(spacing: 8) {
                Text("341 enregistrements archivés, 17 échecs — consultez manifest.json.")
                    .fixedSize()
                Button("Afficher dans le Finder", action: {})
                    .fixedSize()
                Button("Fermer", action: {})
                    .fixedSize()
            }
            .font(.cadenza(12, scale: effectiveScale))
            .fixedSize()
        )

        NSLog(
            "[ExportBackupLayoutProbe] legacy checkbox=%.1fx%.1f header=%.1fx%.1f result=%.1fx%.1f limit=%.1f scale=%.3f",
            checkboxHost.fittingSize.width,
            checkboxHost.fittingSize.height,
            headerHost.fittingSize.width,
            headerHost.fittingSize.height,
            resultHost.fittingSize.width,
            resultHost.fittingSize.height,
            contentWidth,
            effectiveScale
        )
        #expect(checkboxHost.fittingSize.width > contentWidth)
        #expect(headerHost.fittingSize.width > contentWidth)
        #expect(resultHost.fittingSize.width > contentWidth)
    }

    @MainActor @Test func adaptiveRowsKeepLongestLocalizedLabelsAndActionsInBoundsAndHittable() throws {
        let checkboxProbes = (0..<5).map { _ in ExportBackupFrameProbe() }
        let headerTextProbe = ExportBackupFrameProbe()
        let headerActionProbe = ExportBackupFrameProbe()
        let resultTextProbe = ExportBackupFrameProbe()
        let showProbe = ExportBackupFrameProbe()
        let dismissProbe = ExportBackupFrameProbe()
        let automaticBackupTextProbe = ExportBackupFrameProbe()
        let automaticBackupActionProbe = ExportBackupFrameProbe()

        let root = VStack(alignment: .leading, spacing: 20) {
            ExportBackupAdaptiveControls(regularSpacing: 14) {
                probedCheckbox("Transkript (.txt)", probe: checkboxProbes[0])
                probedCheckbox("Untertitel (.srt)", probe: checkboxProbes[1])
                probedCheckbox("Transkript (.md)", probe: checkboxProbes[2])
                probedCheckbox("Zusammenfassung", probe: checkboxProbes[3])
                probedCheckbox("Audio", probe: checkboxProbes[4])
            }

            ExportBackupAdaptiveRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Exporter toutes les données (archive portable)")
                    Text("Une sauvegarde vérifiable de chaque enregistrement, transcription, résumé et chat, audio inclus. Elle ne contient jamais de clés API ni de jetons de compte.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .background { ExportBackupFrameProbeView(probe: headerTextProbe) }
            } trailing: {
                Button("Exporter une archive…", action: {})
                    .background { ExportBackupFrameProbeView(probe: headerActionProbe) }
            }

            ExportBackupAdaptiveRow {
                Text("341 enregistrements archivés, 17 échecs — consultez manifest.json.")
                    .fixedSize(horizontal: false, vertical: true)
                    .background { ExportBackupFrameProbeView(probe: resultTextProbe) }
            } trailing: {
                ExportBackupAdaptiveControls {
                    Button("Afficher dans le Finder", action: {})
                        .background { ExportBackupFrameProbeView(probe: showProbe) }
                    Button("Fermer", action: {})
                        .background { ExportBackupFrameProbeView(probe: dismissProbe) }
                }
            }

            ExportBackupAdaptiveRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatische Wiederherstellungssicherungen")
                    Text("Cadenza bewahrt bis zu drei Wiederherstellungskopien vom App-Start auf. Mit dieser Aktion werden Kopien für das aktuelle Profil sowie aus früheren Versionen gelöscht, ohne die aktive Mediathek zu verändern.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .background { ExportBackupFrameProbeView(probe: automaticBackupTextProbe) }
            } trailing: {
                Button("Sicherungen löschen…", action: {})
                    .background { ExportBackupFrameProbeView(probe: automaticBackupActionProbe) }
            }
        }
        .font(.cadenza(12, scale: effectiveScale))
        .frame(width: contentWidth, alignment: .leading)
        .environment(\.dynamicTypeSize, .accessibility5)

        let host = intrinsicHost(root)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        let probes = checkboxProbes + [
            headerTextProbe,
            headerActionProbe,
            resultTextProbe,
            showProbe,
            dismissProbe,
            automaticBackupTextProbe,
            automaticBackupActionProbe,
        ]
        NSLog(
            "[ExportBackupLayoutProbe] adaptive=%.1fx%.1f limit=%.1f controls=%ld scale=%.3f",
            host.fittingSize.width,
            host.fittingSize.height,
            contentWidth,
            probes.count,
            effectiveScale
        )
        #expect(host.fittingSize.width <= contentWidth + 0.5)

        for probe in probes {
            let view = try #require(probe.view)
            let frame = view.convert(view.bounds, to: host)
            let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)

            #expect(frame.width > 0)
            #expect(frame.height > 0)
            #expect(frame.minX >= -0.5)
            #expect(frame.minY >= -0.5)
            #expect(frame.maxX <= host.bounds.maxX + 0.5)
            #expect(frame.maxY <= host.bounds.maxY + 0.5)
            #expect(view.hitTest(center) === view)
        }
    }

    @MainActor
    private func legacyCheckbox(_ title: String) -> some View {
        Toggle(title, isOn: .constant(true))
            .toggleStyle(.checkbox)
            .font(.cadenza(12, scale: effectiveScale))
            .fixedSize()
    }

    @MainActor
    private func probedCheckbox(_ title: String, probe: ExportBackupFrameProbe) -> some View {
        Toggle(title, isOn: .constant(true))
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: false, vertical: true)
            .background { ExportBackupFrameProbeView(probe: probe) }
    }

    @MainActor
    private func intrinsicHost<Content: View>(_ content: Content) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(content))
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        return host
    }
}

@MainActor
private final class ExportBackupFrameProbe {
    var view: NSView?
}

@MainActor
private struct ExportBackupFrameProbeView: NSViewRepresentable {
    let probe: ExportBackupFrameProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        probe.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
