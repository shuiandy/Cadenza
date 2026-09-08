import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Cadenza

@Suite("Recordings Chrome Layout")
struct RecordingsChromeLayoutTests {
    @MainActor @Test func legacyFixedRecordingChromeClipsAtMaximumSupportedScale() {
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )

        let labelledAction = fittingSize(
            AnyView(Label("Umbenennen", systemImage: "pencil")
                .font(.cadenza(13, scale: effectiveScale))),
            effectiveScale: 1
        )
        let transcriptTimestamp = fittingSize(
            AnyView(Text("123:45")
                .font(.cadenza(11, design: .monospaced, scale: effectiveScale))),
            effectiveScale: 1
        )
        let bubbleTimestamp = fittingSize(
            AnyView(Text("123:45")
                .font(.cadenza(.caption, scale: effectiveScale))
                .monospacedDigit()),
            effectiveScale: 1
        )
        let importContent = fittingSize(
            AnyView(LegacyImportRecordingContentProbe()),
            effectiveScale: effectiveScale,
            width: 520
        )

        let fixedSymbolProbes: [(symbol: String, pointSize: CGFloat, frame: CGFloat)] = [
            ("video", 13, 22),
            ("clock", 13, 22),
            ("mappin.and.ellipse", 13, 22),
            ("xmark", 12, 26),
            ("rectangle.grid.2x2", 14, 32),
            ("waveform", 14, 34),
            ("waveform", 16, 34),
        ]
        var measuredSymbols: [String] = []
        for probe in fixedSymbolProbes {
            let glyph = fittingSize(
                AnyView(Image(systemName: probe.symbol)
                    .font(.cadenza(probe.pointSize, weight: .medium, scale: effectiveScale))),
                effectiveScale: 1
            )
            measuredSymbols.append("\(probe.symbol)=\(Int(glyph.width))x\(Int(glyph.height))/\(Int(probe.frame))")
            #expect(
                glyph.width > probe.frame || glyph.height > probe.frame,
                "The former \(Int(probe.frame))pt frame must remain represented by a real clipping probe for \(probe.symbol)."
            )
        }

        NSLog(
            "[RecordingFixedGeometryProbe] label %.1fx%.1f; timestamps %.1f/%.1f; import %.1fx%.1f; %@",
            labelledAction.width,
            labelledAction.height,
            transcriptTimestamp.width,
            bubbleTimestamp.width,
            importContent.width,
            importContent.height,
            measuredSymbols.joined(separator: ", ")
        )

        #expect(labelledAction.height > 32)
        #expect(transcriptTimestamp.width > 38)
        #expect(transcriptTimestamp.width > 50)
        #expect(bubbleTimestamp.width > 50)
        #expect(importContent.height > 480)
    }

    @MainActor @Test func repairedRecordingChromeContainsRealContentAtMaximumSupportedScale() {
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )

        let labelledAction = fittingSize(
            AnyView(Label("Umbenennen", systemImage: "pencil")
                .font(.cadenza(13, scale: effectiveScale))),
            effectiveScale: 1
        )
        let adaptiveLabel = fittingSize(
            AnyView(Label("Umbenennen", systemImage: "pencil")
                .font(.cadenza(13, scale: effectiveScale))
                .frame(minHeight: 32)),
            effectiveScale: 1
        )
        let transcriptTimestamp = fittingSize(
            AnyView(Text("123:45")
                .font(.cadenza(11, design: .monospaced, scale: effectiveScale))
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 38, alignment: .trailing)),
            effectiveScale: 1
        )
        let bubbleTimestamp = fittingSize(
            AnyView(Text("123:45")
                .font(.cadenza(.caption, scale: effectiveScale))
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 50, alignment: .trailing)),
            effectiveScale: 1
        )

        #expect(adaptiveLabel.height >= labelledAction.height)
        #expect(transcriptTimestamp.width >= 127)
        #expect(bubbleTimestamp.width >= 104)

        let symbolProbes: [(
            symbol: String,
            renderedPointSize: CGFloat,
            frame: CGFloat
        )] = [
            ("video", 13, EventDetailLayoutMetrics.metadataIconColumnWidth(for: effectiveScale)),
            ("clock", 13, EventDetailLayoutMetrics.metadataIconColumnWidth(for: effectiveScale)),
            ("mappin.and.ellipse", 13, EventDetailLayoutMetrics.metadataIconColumnWidth(for: effectiveScale)),
            ("xmark", 12, CadenzaControlMetrics.squareIconFrame(base: 26, symbolPointSize: 12, scale: effectiveScale, padding: 10)),
            ("rectangle.grid.2x2", 14, CadenzaControlMetrics.squareIconFrame(base: 32, symbolPointSize: 14, scale: effectiveScale, padding: 4)),
            ("waveform", 14, CadenzaControlMetrics.squareIconFrame(base: 34, symbolPointSize: 14, scale: effectiveScale, padding: 2)),
            ("waveform", 16, CadenzaControlMetrics.squareIconFrame(base: 34, symbolPointSize: 16, scale: effectiveScale, padding: 0)),
        ]
        for probe in symbolProbes {
            let glyph = fittingSize(
                AnyView(Image(systemName: probe.symbol)
                    .font(.cadenza(probe.renderedPointSize, weight: .medium, scale: effectiveScale))),
                effectiveScale: 1
            )
            #expect(probe.frame >= glyph.width, "\(probe.symbol) must fit horizontally.")
            #expect(probe.frame >= glyph.height, "\(probe.symbol) must fit vertically.")
        }

        #expect(ImportRecordingLayoutMetrics.sheetSize(for: 1) == CGSize(width: 520, height: 480))
        #expect(ImportRecordingLayoutMetrics.sheetSize(for: effectiveScale) == CGSize(width: 720, height: 640))
        #expect(EventDetailLayoutMetrics.sheetSize(for: 1) == CGSize(width: 400, height: 540))
        #expect(EventDetailLayoutMetrics.sheetSize(for: effectiveScale) == CGSize(width: 640, height: 700))
        #expect(EventDetailLayoutMetrics.metadataIconColumnWidth(for: 1) == 22)

        let isolatedState = AppState(
            cadenzaAuth: CadenzaAuthService.ephemeral(),
            startupPolicy: .isolatedFixture
        )
        let importHost = NSHostingView(
            rootView: ImportRecordingSheet()
                .environment(isolatedState)
                .environment(\.dynamicTypeSize, .accessibility5)
                .environment(\.uiScale, effectiveScale)
        )
        importHost.sizingOptions = [.intrinsicContentSize]
        importHost.layoutSubtreeIfNeeded()
        #expect(importHost.fittingSize == CGSize(width: 720, height: 640))

        NSLog(
            "[RecordingRepairedGeometryProbe] label %.1f; timestamps %.1f/%.1f; icon columns %.1f; controls %.1f/%.1f/%.1f; sheets %.0fx%.0f/%.0fx%.0f",
            adaptiveLabel.height,
            transcriptTimestamp.width,
            bubbleTimestamp.width,
            EventDetailLayoutMetrics.metadataIconColumnWidth(for: effectiveScale),
            symbolProbes[3].frame,
            symbolProbes[4].frame,
            symbolProbes[6].frame,
            importHost.fittingSize.width,
            importHost.fittingSize.height,
            EventDetailLayoutMetrics.sheetSize(for: effectiveScale).width,
            EventDetailLayoutMetrics.sheetSize(for: effectiveScale).height
        )
    }

    @Test func isolatedRecordingAndEventBoundariesDoNotInvokeDirectSinks() throws {
        var serviceConstructionCount = 0
        let isolatedService: Int? = RecordingsContentGenerationBoundary.constructService(
            startupPolicy: .isolatedFixture
        ) {
            serviceConstructionCount += 1
            return 1
        }
        #expect(isolatedService == nil)
        #expect(serviceConstructionCount == 0)

        let standardService: Int? = RecordingsContentGenerationBoundary.constructService(
            startupPolicy: .standard
        ) {
            serviceConstructionCount += 1
            return 2
        }
        #expect(standardService == 2)
        #expect(serviceConstructionCount == 1)

        let trustedURL = try #require(URL(string: "https://zoom.us/j/123456789"))
        var externalOpenCount = 0
        let didOpen = EventDetailDirectActionBoundary.openTrustedMeetingURL(
            startupPolicy: .isolatedFixture,
            url: trustedURL
        ) { _ in
            externalOpenCount += 1
            return true
        }
        #expect(!didOpen)
        #expect(externalOpenCount == 0)

        let standardDidOpen = EventDetailDirectActionBoundary.openTrustedMeetingURL(
            startupPolicy: .standard,
            url: trustedURL
        ) { _ in
            externalOpenCount += 1
            return true
        }
        #expect(standardDidOpen)
        #expect(externalOpenCount == 1)

        var hardwareCaptureCount = 0
        let didStartCapture = EventDetailDirectActionBoundary.performHardwareCapture(
            startupPolicy: .isolatedFixture
        ) {
            hardwareCaptureCount += 1
        }
        #expect(!didStartCapture)
        #expect(hardwareCaptureCount == 0)

        let standardDidStartCapture = EventDetailDirectActionBoundary.performHardwareCapture(
            startupPolicy: .standard
        ) {
            hardwareCaptureCount += 1
        }
        #expect(standardDidStartCapture)
        #expect(hardwareCaptureCount == 1)
    }

    @Test func recordingAndEventActionsKeepUIAndDirectSinkIsolationGuards() throws {
        let recordings = try recordingsSource("RecordingsContentView.swift")
        let project = try recordingsSource("ProjectDetailView.swift")
        let detail = try recordingsSource("RecordingDetailView.swift")
        let event = try source("Cadenza/Views/Calendar/EventDetailSheet.swift")

        #expect(recordings.contains(".disabled(!appState.startupPolicy.allowsContentGeneration)"))
        #expect(textPrecedes(
            in: recordings,
            scope: "private func batchRegenerateSummaries()",
            guardText: "guard appState.startupPolicy.allowsContentGeneration else { return }",
            sink: "await appState.coordinator.generateSummary("
        ))
        #expect(textPrecedes(
            in: recordings,
            scope: "enum RecordingsContentGenerationBoundary",
            guardText: "guard startupPolicy.allowsContentGeneration else { return nil }",
            sink: "return factory()"
        ))
        #expect(!recordings.contains("makeChatService"))
        #expect(!recordings.contains("OpenAIService("))

        #expect(project.contains(".disabled(isBriefLoading || !appState.startupPolicy.allowsContentGeneration)"))
        #expect(project.contains("|| !appState.startupPolicy.allowsContentGeneration"))
        #expect(textPrecedes(
            in: project,
            scope: "private func resolveAIService()",
            guardText: "guard appState.startupPolicy.allowsContentGeneration else { return nil }",
            sink: "RecordingsContentGenerationBoundary.constructService("
        ))
        #expect(textPrecedes(
            in: project,
            scope: "RecordingsContentGenerationBoundary.constructService(",
            guardText: "startupPolicy: appState.startupPolicy",
            sink: "provider.makeChatService(apiKey: apiKey)"
        ))

        #expect(detail.contains(".disabled(!appState.startupPolicy.allowsContentGeneration)"))
        #expect(textPrecedes(
            in: detail,
            scope: "private func translateTranscript(",
            guardText: "guard appState.startupPolicy.allowsContentGeneration else { return }",
            sink: "RecordingsContentGenerationBoundary.constructService("
        ))
        #expect(textPrecedes(
            in: detail,
            scope: "RecordingsContentGenerationBoundary.constructService(",
            guardText: "startupPolicy: appState.startupPolicy",
            sink: "createAIService(provider: provider, apiKey: apiKey)"
        ))
        #expect(textPrecedes(
            in: detail,
            scope: "private func regenerateSummary(",
            guardText: "guard appState.startupPolicy.allowsContentGeneration else { return }",
            sink: "appState.generateSummary("
        ))

        #expect(event.contains("if appState.startupPolicy.externalAccessEnabled,"))
        #expect(event.contains("if appState.startupPolicy.allowsHardwareCapture"))
        #expect(textPrecedes(
            in: event,
            scope: "private func openMeetingURL(",
            guardText: "guard appState.startupPolicy.externalAccessEnabled else { return }",
            sink: "NSWorkspace.shared.open($0)"
        ))
        #expect(textPrecedes(
            in: event,
            scope: "private func startRecording()",
            guardText: "guard appState.startupPolicy.allowsHardwareCapture else { return }",
            sink: "appState.startRecording(meetingName: event.title)"
        ))
    }

    @Test func recordingAndEventSurfacesWireAdaptiveGeometryIntoProductionViews() throws {
        let detail = try recordingsSource("RecordingDetailView.swift")
        let project = try recordingsSource("ProjectDetailView.swift")
        let importSheet = try recordingsSource("ImportRecordingView.swift")
        let trash = try recordingsSource("TrashContentView.swift")
        let listRow = try recordingsSource("RecordingListRow.swift")
        let recap = try source("Cadenza/Views/Recaps/RecapDetailView.swift")
        let bubble = try source("Cadenza/Views/Components/TranscriptBubble.swift")
        let event = try source("Cadenza/Views/Calendar/EventDetailSheet.swift")

        #expect(detail.components(separatedBy: ".frame(minHeight: 32)").count - 1 >= 2)
        #expect(detail.contains(".frame(minWidth: 38, alignment: .trailing)"))
        #expect(!detail.contains(".frame(width: 38, alignment: .trailing)"))
        #expect(detail.contains("RecordingDetailTabBarLayout {"))

        #expect(project.contains(".pickerStyle(.segmented)"))
        #expect(project.contains("ProjectDetailVerticalControlGroup {"))
        #expect(project.contains("ProjectDetailSuggestionLayout {"))
        #expect(project.contains("let waveformFrame = CadenzaControlMetrics.squareIconFrame("))
        #expect(!project.contains(".frame(width: 24)"))

        #expect(importSheet.contains("ImportRecordingLayoutMetrics.sheetSize(for: uiScale)"))
        #expect(importSheet.contains("let closeControlSize = CadenzaControlMetrics.squareIconFrame("))
        #expect(importSheet.contains("ScrollView {"))
        #expect(importSheet.contains("ViewThatFits(in: .horizontal)"))
        #expect(!importSheet.contains(".frame(width: 520, height: 480)"))

        #expect(trash.contains("let controlSize = CadenzaControlMetrics.squareIconFrame("))
        #expect(recap.contains("let iconFrame = CadenzaControlMetrics.squareIconFrame("))
        #expect(listRow.contains("let iconFrame = CadenzaControlMetrics.squareIconFrame("))
        #expect(bubble.contains(".frame(minWidth: 50, alignment: .trailing)"))
        #expect(!bubble.contains(".frame(width: 50, alignment: .trailing)"))

        #expect(event.contains("EventDetailLayoutMetrics.sheetSize(for: uiScale)"))
        #expect(event.components(separatedBy: ".frame(width: metadataIconColumnWidth)").count - 1 == 3)
        #expect(!event.contains(".frame(width: 22)"))
        #expect(!event.contains(".frame(width: 400)"))
    }

    @MainActor @Test func legacyRecordingDetailToolbarOverflowsAtMinimumWindowAndMaximumTextScale() {
        let availableWidth: CGFloat = 500
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let host = NSHostingView(
            rootView: LegacyRecordingDetailTranscriptToolbarProbe()
                .environment(\.locale, Locale(identifier: "de"))
                .environment(\.dynamicTypeSize, .accessibility5)
                .environment(\.uiScale, effectiveScale)
        )
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()

        let legacyWidth = host.fittingSize.width
        NSLog(
            "[RecordingDetailToolbarProbe] legacy width %.1f, available width %.1f",
            legacyWidth,
            availableWidth
        )
        #expect(
            legacyWidth > availableWidth,
            "The former one-line toolbar must remain represented by a real overflowing probe."
        )
    }

    @MainActor @Test func legacyProjectAndDetailSelectorsOverflowAtMaximumSupportedScale() {
        let availableWidth: CGFloat = 530
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let projectSelector = fittingSize(
            AnyView(LegacyProjectDetailSelectorProbe()),
            effectiveScale: effectiveScale
        )
        let suggestions = fittingSize(
            AnyView(LegacyProjectSuggestionRowProbe()),
            effectiveScale: effectiveScale
        )
        let detailTabs = fittingSize(
            AnyView(LegacyRecordingDetailTabRowProbe()),
            effectiveScale: effectiveScale
        )
        let waveform = fittingSize(
            AnyView(Image(systemName: "waveform")
                .font(.cadenza(14, scale: effectiveScale))),
            effectiveScale: 1
        )

        NSLog(
            "[ProjectDetailAccessibilityProbe] legacy selector %.1fx%.1f; suggestions %.1fx%.1f; detail tabs %.1fx%.1f; waveform %.1fx%.1f/24",
            projectSelector.width,
            projectSelector.height,
            suggestions.width,
            suggestions.height,
            detailTabs.width,
            detailTabs.height,
            waveform.width,
            waveform.height
        )

        #expect(projectSelector.width > availableWidth)
        #expect(suggestions.width > availableWidth)
        #expect(detailTabs.width > availableWidth)
        #expect(waveform.width > 24 || waveform.height > 24)
    }

    @MainActor @Test func projectAndDetailControlsReflowInsideMinimumWidthAtMaximumScale() throws {
        let availableWidth: CGFloat = 530
        let locale = Locale(identifier: "de")
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        #expect(!ProjectDetailAdaptiveLayoutPolicy.stacksControls(for: .large))
        #expect(ProjectDetailAdaptiveLayoutPolicy.stacksControls(for: .accessibility1))

        let projectProbes = (0..<4).map { _ in LayoutControlFrameProbe() }
        let projectHost = layoutProbeHost(
            AnyView(ProjectDetailVerticalControlGroup {
                ProjectSectionControlProbe(title: "Recordings (\(999))", probe: projectProbes[0])
                ProjectSectionControlProbe(title: "Action Items (\(999))", probe: projectProbes[1])
                ProjectSectionControlProbe(title: "Decisions (\(999))", probe: projectProbes[2])
                ProjectSectionControlProbe(title: "AI Brief", probe: projectProbes[3])
            }),
            width: availableWidth,
            effectiveScale: effectiveScale,
            locale: locale
        )

        let localizedSuggestions = [
            ProjectDetailSuggestionLocalization.text("What happened last time?", locale: locale),
            ProjectDetailSuggestionLocalization.text("What should I do next?", locale: locale),
            ProjectDetailSuggestionLocalization.text("What blockers are unresolved?", locale: locale),
        ]
        let suggestionProbes = (0..<3).map { _ in LayoutControlFrameProbe() }
        let suggestionHost = layoutProbeHost(
            AnyView(ProjectDetailSuggestionLayout {
                ProjectSuggestionControlProbe(title: localizedSuggestions[0], probe: suggestionProbes[0])
                ProjectSuggestionControlProbe(title: localizedSuggestions[1], probe: suggestionProbes[1])
                ProjectSuggestionControlProbe(title: localizedSuggestions[2], probe: suggestionProbes[2])
            }),
            width: availableWidth,
            effectiveScale: effectiveScale,
            locale: locale
        )

        let tabProbes = (0..<3).map { _ in LayoutControlFrameProbe() }
        let detailTabHost = layoutProbeHost(
            AnyView(RecordingDetailTabBarLayout {
                RecordingDetailTabControlProbe(title: "Summary", icon: "sparkles", probe: tabProbes[0])
                RecordingDetailTabControlProbe(title: "Action Items", icon: "checklist", probe: tabProbes[1])
                RecordingDetailTabControlProbe(title: "Transcript", icon: "text.bubble", probe: tabProbes[2])
            }),
            width: availableWidth,
            effectiveScale: effectiveScale,
            locale: locale
        )

        try assertControls(projectProbes, areInsideAndHittableIn: projectHost)
        try assertControls(suggestionProbes, areInsideAndHittableIn: suggestionHost)
        try assertControls(tabProbes, areInsideAndHittableIn: detailTabHost)

        let waveformFrame = CadenzaControlMetrics.squareIconFrame(
            base: 24,
            symbolPointSize: 14,
            scale: effectiveScale,
            padding: 0
        )
        let waveformGlyph = fittingSize(
            AnyView(Image(systemName: "waveform")
                .font(.cadenza(14, scale: effectiveScale))),
            effectiveScale: 1
        )
        #expect(waveformFrame >= waveformGlyph.width)
        #expect(waveformFrame >= waveformGlyph.height)

        NSLog(
            "[ProjectDetailAccessibilityProbe] repaired project %.1fx%.1f; suggestions %.1fx%.1f; detail tabs %.1fx%.1f; waveform %.1f/%.1fx%.1f",
            projectHost.fittingSize.width,
            projectHost.fittingSize.height,
            suggestionHost.fittingSize.width,
            suggestionHost.fittingSize.height,
            detailTabHost.fittingSize.width,
            detailTabHost.fittingSize.height,
            waveformFrame,
            waveformGlyph.width,
            waveformGlyph.height
        )
    }

    @Test func projectQuickSuggestionsLocalizeBeforeDisplayAndSend() throws {
        let locale = Locale(identifier: "de")
        #expect(
            ProjectDetailSuggestionLocalization.text("What happened last time?", locale: locale)
                == "Was ist beim letzten Mal passiert?"
        )
        #expect(
            ProjectDetailSuggestionLocalization.text("What should I do next?", locale: locale)
                == "Was sollte ich als Nächstes tun?"
        )
        #expect(
            ProjectDetailSuggestionLocalization.text("What blockers are unresolved?", locale: locale)
                == "Welche Blockaden sind ungelöst?"
        )

        let project = try recordingsSource("ProjectDetailView.swift")
        #expect(project.contains("private func suggestionChip(_ key: String.LocalizationValue)"))
        #expect(!project.contains("private func suggestionChip(_ text: String)"))
        #expect(project.contains("aiQuery = localizedText"))
        #expect(project.contains("Text(verbatim: localizedText)"))
    }

    @MainActor @Test func recordingDetailToolbarsWrapAtMinimumWindowAndMaximumTextScale() {
        let availableWidth: CGFloat = 500
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )

        let transcriptLegacySize = fittingSize(
            AnyView(LegacyRecordingDetailTranscriptToolbarProbe()),
            effectiveScale: effectiveScale
        )
        let summaryLegacySize = fittingSize(
            AnyView(LegacyRecordingDetailSummaryToolbarProbe()),
            effectiveScale: effectiveScale
        )
        let transcriptAdaptiveSize = fittingSize(
            AnyView(AdaptiveRecordingDetailTranscriptToolbarProbe()),
            effectiveScale: effectiveScale,
            width: availableWidth
        )
        let summaryAdaptiveSize = fittingSize(
            AnyView(AdaptiveRecordingDetailSummaryToolbarProbe()),
            effectiveScale: effectiveScale,
            width: availableWidth
        )
        let pickerSize = fittingSize(
            AnyView(RecordingDetailLanguagePickerProbe(usesFixedLegacyWidth: false)),
            effectiveScale: effectiveScale
        )
        let transcriptActionColumnSize = fittingSize(
            AnyView(VStack(alignment: .leading, spacing: 8) {
                RecordingDetailTranscriptActionsProbe()
            }),
            effectiveScale: effectiveScale
        )
        let summaryActionColumnSize = fittingSize(
            AnyView(VStack(alignment: .leading, spacing: 8) {
                RecordingDetailSummaryActionsProbe()
            }),
            effectiveScale: effectiveScale
        )

        NSLog(
            "[RecordingDetailToolbarProbe] transcript %.1fx%.1f -> %.1fx%.1f; summary %.1fx%.1f -> %.1fx%.1f",
            transcriptLegacySize.width,
            transcriptLegacySize.height,
            transcriptAdaptiveSize.width,
            transcriptAdaptiveSize.height,
            summaryLegacySize.width,
            summaryLegacySize.height,
            summaryAdaptiveSize.width,
            summaryAdaptiveSize.height
        )

        #expect(transcriptLegacySize.width > availableWidth)
        #expect(summaryLegacySize.width > availableWidth)
        #expect(transcriptAdaptiveSize.width <= availableWidth)
        #expect(summaryAdaptiveSize.width <= availableWidth)
        #expect(transcriptAdaptiveSize.height > transcriptLegacySize.height)
        #expect(summaryAdaptiveSize.height > summaryLegacySize.height)
        #expect(pickerSize.width <= availableWidth)
        #expect(transcriptActionColumnSize.width <= availableWidth)
        #expect(summaryActionColumnSize.width <= availableWidth)
        #expect(transcriptAdaptiveSize.height.isFinite)
        #expect(summaryAdaptiveSize.height.isFinite)
    }

    @MainActor @Test func transcriptSegmentCopyControlContainsRealGlyphsAtMaximumTextScale() {
        let padding: CGFloat = 6
        let effectiveScale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let controlSize = CadenzaControlMetrics.squareIconFrame(
            base: 22,
            symbolPointSize: 12,
            scale: effectiveScale,
            padding: padding
        )

        #expect(
            CadenzaControlMetrics.squareIconFrame(
                base: 22,
                symbolPointSize: 12,
                scale: 1,
                padding: padding
            ) == 22
        )

        for symbol in ["doc.on.doc", "checkmark"] {
            let glyphHost = NSHostingView(
                rootView: Image(systemName: symbol)
                    .font(.cadenza(12, scale: effectiveScale))
            )
            glyphHost.sizingOptions = [.intrinsicContentSize]
            glyphHost.layoutSubtreeIfNeeded()
            let glyphSize = glyphHost.fittingSize

            #expect(controlSize >= glyphSize.width, "\(symbol) must not clip horizontally.")
            #expect(controlSize >= glyphSize.height, "\(symbol) must not clip vertically.")
        }
    }

    @MainActor @Test func recordingDetailKeepsAllRecordingsRootMountedBehindNavigationPush() throws {
        let recordingID = UUID()

        #expect(ContentView.rootDestination(for: .allRecordings) == .allRecordings)
        #expect(ContentView.rootDestination(for: .recordingDetail(recordingID)) == .allRecordings)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainWindow = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Main/MainWindow.swift"),
            encoding: .utf8
        )

        #expect(
            mainWindow.contains("NavigationStack(path: recordingDetailPath)"),
            "Recording detail should be pushed above the stable recordings root instead of replacing it."
        )
        #expect(
            mainWindow.contains(".navigationDestination(for: UUID.self)"),
            "The recording-detail route should use a typed NavigationStack destination."
        )
        #expect(
            mainWindow.contains(".navigationBarBackButtonHidden(true)"),
            "The existing toolbar close button should remain the only detail close affordance."
        )
    }

    @Test func recordingsChromeUsesToolbarGlassInsteadOfFullWidthMaterialOverlay() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tabContent = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/TabBar/TabContentView.swift"),
            encoding: .utf8
        )
        let recordingsContent = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Recordings/RecordingsContentView.swift"),
            encoding: .utf8
        )
        let mainWindow = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Main/MainWindow.swift"),
            encoding: .utf8
        )

        #expect(
            !mainWindow.contains("showRecordingsChromeControls"),
            "The recordings view/search controls should not be re-hosted as MainWindow toolbar items."
        )
        #expect(
            !mainWindow.contains("RecordingsTopBar(fillsAvailableWidth: false)"),
            "The existing recordings controls should keep their page-level architecture."
        )
        #expect(
            !mainWindow.contains("showRecordingsScrollChrome"),
            "The recordings page should own scroll-edge glass without toggling window chrome modes."
        )
        #expect(
            mainWindow.contains("titlebarAppearsTransparent: true"),
            "The titlebar should stay transparent so AppKit does not draw a hard toolbar separator over recordings."
        )
        #expect(
            !mainWindow.contains("suppressTitlebarSeparators"),
            "Window chrome should not depend on private titlebar subview suppression."
        )
        #expect(
            !tabContent.contains("RecordingsFrameGlassBridge"),
            "The recordings page should not rely on a frame-view material bridge that cannot participate in native scroll-edge compositing."
        )
        #expect(
            !tabContent.contains("RecordingsTopGlassMaterial"),
            "The top blur should not be a hand-mounted material cover."
        )
        #expect(
            !recordingsContent.contains(".ignoresSafeArea(.container, edges: .top)"),
            "The recordings ScrollView should respect the top safe-area bar so cards do not slide underneath the view/search controls."
        )
        #expect(
            !tabContent.contains("scrollIndicatorTopMargin"),
            "Scroll indicator alignment should come from the content area's real top boundary, not a manual correction."
        )
        #expect(
            !recordingsContent.contains(".contentMargins(.top, scrollIndicatorTopMargin, for: .scrollIndicators)"),
            "The recordings layout should not need a scroll-indicator-specific top patch."
        )
        #expect(
            tabContent.contains("RecordingsTopBar()"),
            "The recordings page should continue to own the existing top bar."
        )
        #expect(
            tabContent.contains(".cadenzaSafeAreaBar(edge: .top"),
            "The recordings top controls should be hosted in a native top safe-area bar so they participate in system scroll-edge compositing."
        )
        #expect(
            tabContent.contains("static let contentTopPadding: CGFloat = 0"),
            "The top safe-area bar already reserves chrome height; adding a second large content top padding leaves an oversized blank band."
        )
        #expect(
            !tabContent.contains("recordingsScrollOffset"),
            "The recordings page should not need a manual overlay driven by scroll position."
        )
        #expect(
            !recordingsContent.contains("topContentInset"),
            "RecordingsContentView should not carry layout state for the removed fake top strip."
        )
        #expect(
            !recordingsContent.contains("onScrollOffsetChange"),
            "RecordingsContentView should not expose scroll offset just to drive a manual top blur overlay."
        )
        #expect(
            recordingsContent.contains(".cadenzaSoftTopScrollEdgeEffect()"),
            "The recordings list needs an explicit native soft edge so scrolled cards remain visually separated from the floating title and controls on macOS 27."
        )
    }

    @Test func macOS26VisualAPIsStayBehindCompatibilityBoundary() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productRoot = repoRoot.appendingPathComponent("Cadenza")
        let compatibilityURL = productRoot.appendingPathComponent("Utilities/PlatformCompatibility.swift")
        let compatibilitySource = try String(contentsOf: compatibilityURL, encoding: .utf8)

        let boundarySymbols = [
            "func cadenzaGlass<",
            "struct CadenzaGlassContainer",
            "func cadenzaGlassButtonStyle()",
            "func cadenzaSafeAreaBar<",
            "func cadenzaSoftTopScrollEdgeEffect()",
        ]
        for symbol in boundarySymbols {
            #expect(compatibilitySource.contains(symbol))
        }

        let nativeCalls = [
            "glassEffect(",
            "GlassEffectContainer",
            "buttonStyle(.glass)",
            "safeAreaBar(",
            "scrollEdgeEffectStyle(",
        ]
        for nativeCall in nativeCalls {
            #expect(compatibilitySource.contains(nativeCall))
        }
        #expect(compatibilitySource.contains("scrollEdgeEffectStyle(.soft, for: .top)"))
        #expect(!compatibilitySource.contains("scrollEdgeEffectStyle(.automatic, for: .top)"))

        let enumerator = try #require(FileManager.default.enumerator(
            at: productRoot,
            includingPropertiesForKeys: nil
        ))
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard fileURL.resolvingSymlinksInPath()
                != compatibilityURL.resolvingSymlinksInPath() else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for nativeCall in nativeCalls {
                #expect(
                    !source.contains(nativeCall),
                    "\(fileURL.lastPathComponent) bypasses the macOS compatibility boundary with \(nativeCall)"
                )
            }
        }
    }

    @Test func customSidebarChromeFollowsInactiveWindowAppearance() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainWindow = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Main/MainWindow.swift"),
            encoding: .utf8
        )

        #expect(mainWindow.contains("@Environment(\\.appearsActive)"))
        #expect(
            mainWindow.components(separatedBy: ".sidebarChromeActivity()").count - 1 == 2,
            "Only the custom account banner and bottom bar should be dimmed; the native sidebar List adapts itself."
        )
        #expect(mainWindow.contains("appearsActive ? 1 : 0.5"))
    }

    @Test func speakerTimelineBuilderCreatesProportionalSegmentsAndSummaries() throws {
        let entries = [
            TranscriptEntryDTO(id: UUID(), startTime: 0, endTime: 30, text: "Intro", speaker: "SPEAKER_00"),
            TranscriptEntryDTO(id: UUID(), startTime: 30, endTime: 45, text: "Reply", speaker: "SPEAKER_01"),
            TranscriptEntryDTO(id: UUID(), startTime: 45, endTime: 60, text: "Unknown", speaker: nil),
            TranscriptEntryDTO(id: UUID(), startTime: 60, endTime: 75, text: "Bad duration", speaker: "SPEAKER_00"),
            TranscriptEntryDTO(id: UUID(), startTime: 80, endTime: 70, text: "Ignored", speaker: "SPEAKER_02")
        ]

        let data = try #require(SpeakerTimelineBuilder.build(
            entries: entries,
            recordingDuration: 90,
            displayName: { raw in raw ?? "Unknown" }
        ))

        #expect(data.totalDuration == 90)
        #expect(data.segments.count == 4)
        #expect(data.segments[0].startFraction == 0)
        #expect(abs(data.segments[0].widthFraction - (30.0 / 90.0)) < 0.0001)
        #expect(data.segments[2].speakerKey == SpeakerTimelineBuilder.unknownSpeakerKey)
        #expect(data.identifiedSpeakerCount == 2)

        let totals = Dictionary(uniqueKeysWithValues: data.speakers.map { ($0.speakerKey, $0.fraction) })
        #expect(abs((totals["SPEAKER_00"] ?? 0) - (45.0 / 75.0)) < 0.0001)
        #expect(abs((totals["SPEAKER_01"] ?? 0) - (15.0 / 75.0)) < 0.0001)
        #expect(abs((totals[SpeakerTimelineBuilder.unknownSpeakerKey] ?? 0) - (15.0 / 75.0)) < 0.0001)

        let speakerColorIndices = Set(data.speakers.map(\.colorIndex))
        #expect(
            speakerColorIndices.count == data.speakers.count,
            "Each visible speaker should get a distinct color index before colors are rendered."
        )
        for segment in data.segments {
            let summary = try #require(data.speakers.first { $0.speakerKey == segment.speakerKey })
            #expect(segment.colorIndex == summary.colorIndex)
        }
    }

    @Test func speakerTimelineBuilderAggregatesRawLabelsWithSameIdentityKey() throws {
        let entries = [
            TranscriptEntryDTO(id: UUID(), startTime: 0, endTime: 10, text: "A", speaker: "A"),
            TranscriptEntryDTO(id: UUID(), startTime: 10, endTime: 20, text: "B", speaker: "B"),
            TranscriptEntryDTO(id: UUID(), startTime: 20, endTime: 30, text: "C", speaker: "C")
        ]

        let data = try #require(SpeakerTimelineBuilder.build(
            entries: entries,
            recordingDuration: 30,
            displayName: { raw in
                switch raw {
                case "A", "B": "Caleb"
                case "C": "Andy"
                default: "Unknown"
                }
            },
            identityKey: { raw in
                switch raw {
                case "A", "B": "profile:caleb"
                case "C": "profile:andy"
                default: nil
                }
            }
        ))

        #expect(data.speakers.count == 2)
        let totals = Dictionary(uniqueKeysWithValues: data.speakers.map { ($0.speakerKey, $0.totalDuration) })
        #expect(totals["profile:caleb"] == 20)
        #expect(totals["profile:andy"] == 10)
        #expect(data.segments[0].speakerKey == "profile:caleb")
        #expect(data.segments[1].speakerKey == "profile:caleb")
        #expect(data.segments[0].colorIndex == data.segments[1].colorIndex)
    }

    @Test func recordingDetailTranscriptChromeShowsTimelineAndTextActions() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let detail = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Recordings/RecordingDetailView.swift"),
            encoding: .utf8
        )

        #expect(
            detail.contains("SpeakerTimelineBuilder.build"),
            "Transcript tab should derive a speaker activity timeline from transcript segments."
        )
        #expect(
            detail.contains("SpeakerTimelineView"),
            "Recording detail should render a speaker activity bar above transcript entries."
        )
        #expect(
            detail.contains("Label(\"Re-transcribe\"") || detail.contains("Text(\"Re-transcribe\""),
            "Transcript retry action should have visible text, not only an icon."
        )
        #expect(
            detail.contains("Label(\"Identify speakers\"") || detail.contains("Text(\"Identify speakers\""),
            "Speaker analysis action should have visible text, not only an icon."
        )
        #expect(
            detail.contains("Label(copiedTab") && detail.contains("\"Copy\""),
            "Copy action should have visible text, not only an icon."
        )
        #expect(
            detail.contains("Label(\"Export\"") || detail.contains("Text(\"Export\""),
            "Export action should have visible text, not only an icon."
        )
        #expect(
            detail.contains("IconHoverButton(title: \"Rename\""),
            "Header rename action should have visible text, not only an icon."
        )
        #expect(
            detail.contains("Label(\"Delete\", systemImage: \"trash\")"),
            "Header delete action should have visible text, not only an icon."
        )
        #expect(
            detail.contains("speakerTimelineColorPalette"),
            "Speaker timeline should use a fixed high-contrast palette instead of nearby system colors."
        )
        #expect(
            detail.contains(".frame(height: 22)"),
            "Speaker timeline bar should be tall enough to scan instead of feeling cramped."
        )
        #expect(
            detail.contains("SpeakerShareChip") && detail.contains("LazyVGrid"),
            "Speaker percentages should wrap into chips instead of squeezing into one inline legend row."
        )
        #expect(
            detail.contains("colorBySpeakerKey"),
            "Transcript speaker rows should reuse the timeline color mapping instead of rebuilding it per row."
        )
        #expect(detail.contains("let controlSize = CadenzaControlMetrics.squareIconFrame("))
        #expect(!detail.contains(".frame(width: 22, height: 22)"))
    }

    @Test func libraryRootDoesNotObserveTheCalendarMirror() throws {
        // `appState.upcomingMeetings` is rewritten by a 5 s timer. Only the
        // isolated strip may read it; a read from the library root re-runs
        // the whole grid on every tick.
        let source = try recordingsSource("RecordingsContentView.swift")
        let stripStart = try #require(source.range(of: "// MARK: - Today Strip"))
        let rootPortion = source[..<stripStart.lowerBound]
        #expect(
            !rootPortion.contains("upcomingMeetings"),
            "RecordingsContentView must not read the calendar mirror outside TodayMeetingStrip."
        )
        #expect(source.contains("TimelineView(MeetingBoundarySchedule("))
    }

    @Test func cardContextMenuResolvesSelectionLazilyAndIsolatesServiceReads() throws {
        let source = try recordingsSource("RecordingsContentView.swift")
        let menuStart = try #require(source.range(of: "// MARK: - Export Submenu"))
        let root = source[..<menuStart.lowerBound]
        // The multi-selection filter is O(recordings) and used to run for every
        // visible card on every library body pass.
        #expect(!root.contains("let affectedRecordings = affectsMultiple"))
        #expect(root.contains("let affected: () -> [RecordingDTO] = {"))
        // Per-file export progress must not be a dependency of the card builder.
        #expect(!root.contains("batchFileExporter.isBusy"))
        #expect(!root.contains("appState.notionConnected"))
        #expect(root.contains("RecordingExportMenu("))
    }

    @Test func detailPageBodyDoesNotReadThePlaybackClock() throws {
        // AudioPlayerService writes currentTime 4 times a second. Only the
        // controls bar and the two zero-size observers may read it; a read in
        // the page body re-runs the transcript filter, the speaker map and a
        // file stat on every tick.
        let detail = try recordingsSource("RecordingDetailView.swift")
        #expect(!detail.contains("audioPlayer.currentTime"))
        #expect(detail.contains("private struct PlaybackControlsBar: View"))
        #expect(detail.contains("PlaybackEntryObserver("))
        #expect(detail.contains("PlaybackChapterObserver("))
        #expect(detail.contains("ScrubberTrackCanvas(duration: duration, segments: segments, chapters: chapters)\n                        .equatable()"))
        #expect(!detail.contains("FileManager.default.fileExists(atPath: url.path) {"))
    }

    @Test func libraryDerivationsAreMemoizedOutsideViewBodies() throws {
        let tab = try source("Cadenza/Views/TabBar/TabContentView.swift")
        // Histograms and the library sort used to be rebuilt in body on every
        // keystroke; they now come from AppState's token-keyed memo.
        #expect(!tab.contains("for recording in appState.recordings"))
        #expect(tab.contains("appState.sortedLibraryRecordings(sortKey: recordingsSort)"))
        #expect(tab.contains("appState.libraryTopSpeakers(limit: 3)"))
        #expect(tab.contains("appState.libraryTagsByFrequency"))
        #expect(!tab.contains("localizedCaseInsensitiveCompare"), "Sorting lives in RecordingSorting, not in the view.")

        let library = try recordingsSource("RecordingsContentView.swift")
        #expect(library.contains("dayGroupCache.input == recordings"))
        #expect(library.contains(".onChange(of: recordings, initial: true)"))
    }

    @Test func recordingsCollectionAvoidsEagerWaterfallLayoutAtEveryCount() throws {
        let source = try recordingsSource("RecordingsContentView.swift")

        #expect(
            !source.contains("lazyWaterfallThreshold"),
            "The recordings page must not have a 79/80-item performance cliff."
        )
        #expect(
            !source.contains("shouldUseLazyWaterfallFallback"),
            "Waterfall mode should use one consistently lazy collection path."
        )
        #expect(
            !source.contains("WaterfallLayout("),
            "The eager custom Layout protocol implementation instantiates and measures every recording."
        )
    }

    @Test func recordingsCollectionDoesNotResolveCardAnchorsDuringOrdinaryScrolling() throws {
        let source = try recordingsSource("RecordingsContentView.swift")

        #expect(!source.contains("CardFrameKey"))
        #expect(!source.contains("anchorPreference"))
        #expect(!source.contains("overlayPreferenceValue"))
        #expect(
            source.components(separatedBy: "override func hitTest(_ point: NSPoint) -> NSView? { nil }").count - 1 == 2,
            "Both the card-frame probe and marquee overlay must stay transparent to AppKit hit testing."
        )
        #expect(
            source.contains("isActive: !isShowingRecordingDetail") && source.contains("func setActive(_ isActive: Bool)"),
            "The retained recordings root must uninstall its local mouse monitor while detail is pushed above it."
        )
        #expect(
            source.contains("CardFrameRegistry") && source.contains("CardFrameReporter"),
            "Marquee selection should read visible AppKit frames on pointer events without feeding geometry back into SwiftUI layout."
        )
    }

    @Test func repeatedRecordingCellsUseStaticCollectionSurfaces() throws {
        let card = try recordingsSource("RecordingCardView.swift")
        let row = try recordingsSource("RecordingListRow.swift")
        let style = try source("Cadenza/Utilities/ColorHex.swift")

        #expect(card.contains(".appCollectionCard("))
        #expect(row.contains(".appCollectionCard("))
        #expect(!card.contains(".appCard("))
        #expect(!row.contains(".appCard("))
        #expect(!card.contains(".onHover"))
        #expect(!row.contains(".onHover"))

        let collectionStyle = try #require(style.range(of: "private struct AppCollectionCardModifier"))
        let panelStyle = try #require(style.range(of: "private struct AppGlassPanelModifier"))
        let body = style[collectionStyle.lowerBound..<panelStyle.lowerBound]
        #expect(!body.contains(".glassEffect"))
        #expect(!body.contains(".scaleEffect"))
        #expect(!body.contains(".offset"))
        #expect(!body.contains(".shadow"))
    }

    @Test func primaryNavigationAndContentKeepAccessibleKeyboardSemantics() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try source("Cadenza/Views/Settings/SettingsView.swift", under: repoRoot)
        let mainWindow = try source("Cadenza/Views/Main/MainWindow.swift", under: repoRoot)
        let recordings = try source("Cadenza/Views/Recordings/RecordingsContentView.swift", under: repoRoot)
        let topBar = try source("Cadenza/Views/TabBar/TabContentView.swift", under: repoRoot)
        let calendarDay = try source("Cadenza/Views/Calendar/CalendarDayView.swift", under: repoRoot)
        let calendarWeek = try source("Cadenza/Views/Calendar/CalendarWeekView.swift", under: repoRoot)
        let calendarMonth = try source("Cadenza/Views/Calendar/CalendarMonthView.swift", under: repoRoot)
        let overlay = try source("Cadenza/Views/Main/RecordingOverlayPanel.swift", under: repoRoot)

        #expect(settings.contains("Toggle(title, isOn: $isOn)"))
        #expect(settings.contains(".accessibilityLabel(Text(title))"))
        #expect(mainWindow.contains("title: \"Settings\""))
        #expect(mainWindow.contains(".accessibilityLabel(Text(title))"))
        #expect(recordings.contains(".onKeyPress(.return)"))
        #expect(recordings.contains(".onKeyPress(.space)"))
        #expect(recordings.contains(".accessibilityAction(named: Text(\"Select\"))"))
        #expect(topBar.contains(".accessibilityLabel(\"Search\")"))
        #expect(topBar.contains(".accessibilityLabel(\"Sort\")"))
        #expect(topBar.contains(".accessibilityValue(contentViewModeRaw == mode.rawValue"))
        #expect(calendarDay.contains("Button {\n                                    onEventTap(item.event)"))
        #expect(calendarWeek.contains("Button {\n                                        onEventTap(item.event)"))
        #expect(calendarMonth.contains(".onKeyPress(.return)"))
        #expect(calendarMonth.contains(".onKeyPress(.space)"))
        #expect(calendarMonth.contains(".accessibilityAction(.default)"))
        #expect(calendarMonth.contains(".accessibilityAction(named: Text(\"Open Day\"))"))
        #expect(overlay.contains("notchExpanded || appState.autoStopCountdown > 0"))
        #expect(overlay.contains("Button(\"Keep Recording\")"))
    }

    @Test func primaryMotionSurfacesHonorReduceMotion() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in [
            "Cadenza/Views/Main/MainWindow.swift",
            "Cadenza/Views/Main/RecordingOverlayPanel.swift",
            "Cadenza/Views/Recordings/RecordingDetailView.swift",
            "Cadenza/Views/Recordings/RecordingsContentView.swift",
            "Cadenza/Views/Settings/IntegrationsSettingsView.swift",
            "Cadenza/Views/Settings/SettingsView.swift",
            "Cadenza/Views/Settings/WhisperModelPicker.swift",
        ] {
            let contents = try source(path, under: repoRoot)
            #expect(
                contents.contains("accessibilityReduceMotion"),
                "\(path) must keep a Reduce Motion gate around its primary transitions."
            )
        }

        let overlay = try source("Cadenza/Views/Main/RecordingOverlayPanel.swift", under: repoRoot)
        let detail = try source("Cadenza/Views/Recordings/RecordingDetailView.swift", under: repoRoot)
        let integrations = try source("Cadenza/Views/Settings/IntegrationsSettingsView.swift", under: repoRoot)
        let whisper = try source("Cadenza/Views/Settings/WhisperModelPicker.swift", under: repoRoot)

        #expect(!overlay.contains(".animation(.spring"))
        #expect(!overlay.contains("withAnimation {"))
        #expect(!overlay.contains("withAnimation(.easeOut"))
        #expect(!detail.contains(".transition(.move"))
        #expect(!detail.contains(".transition(.opacity.animation"))
        #expect(!detail.contains("withAnimation(.spring"))
        #expect(!detail.contains("withAnimation(.easeInOut"))
        #expect(!integrations.contains("withAnimation(.easeInOut"))
        #expect(!integrations.contains(".animation(.easeInOut"))
        #expect(!whisper.contains(".animation(.easeInOut"))
    }

    private func recordingsSource(_ filename: String) throws -> String {
        try source("Cadenza/Views/Recordings/\(filename)")
    }

    private func textPrecedes(
        in source: String,
        scope: String,
        guardText: String,
        sink: String
    ) -> Bool {
        guard let scopeRange = source.range(of: scope),
              let guardRange = source.range(
                of: guardText,
                range: scopeRange.lowerBound..<source.endIndex
              ),
              let sinkRange = source.range(
                of: sink,
                range: guardRange.upperBound..<source.endIndex
              ) else {
            return false
        }
        return guardRange.lowerBound < sinkRange.lowerBound
    }

    @MainActor
    private func fittingSize(
        _ view: AnyView,
        effectiveScale: CGFloat,
        width: CGFloat? = nil
    ) -> CGSize {
        let localized = view
            .environment(\.locale, Locale(identifier: "de"))
            .environment(\.dynamicTypeSize, .accessibility5)
            .environment(\.uiScale, effectiveScale)
        let root = if let width {
            AnyView(localized.frame(width: width, alignment: .leading))
        } else {
            AnyView(localized)
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @MainActor
    private func layoutProbeHost(
        _ view: AnyView,
        width: CGFloat,
        effectiveScale: CGFloat,
        locale: Locale
    ) -> NSHostingView<AnyView> {
        let root = view
            .environment(\.locale, locale)
            .environment(\.dynamicTypeSize, .accessibility5)
            .environment(\.uiScale, effectiveScale)
            .frame(width: width, alignment: .leading)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func assertControls(
        _ probes: [LayoutControlFrameProbe],
        areInsideAndHittableIn host: NSHostingView<AnyView>
    ) throws {
        for probe in probes {
            let view = try #require(probe.view)
            let frame = view.convert(view.bounds, to: host)
            let tolerantBounds = host.bounds.insetBy(dx: -0.5, dy: -0.5)

            #expect(frame.width > 0)
            #expect(frame.height > 0)
            #expect(tolerantBounds.contains(frame))

            let localCenter = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            #expect(view.hitTest(localCenter) === view)
        }
    }

    private func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func source(_ path: String, under root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}

@MainActor
private final class LayoutControlFrameProbe {
    var view: NSView?
}

@MainActor
private struct LayoutControlProbeView: NSViewRepresentable {
    let probe: LayoutControlFrameProbe

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        probe.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct ProjectSectionControlProbe: View {
    @Environment(\.uiScale) private var uiScale

    let title: LocalizedStringKey
    let probe: LayoutControlFrameProbe

    var body: some View {
        Button { } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .font(.cadenza(13, scale: uiScale))
                Text(title)
                    .font(.cadenza(13, weight: .medium, scale: uiScale))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background { LayoutControlProbeView(probe: probe) }
        }
        .buttonStyle(.cadenzaPlain)
    }
}

private struct ProjectSuggestionControlProbe: View {
    @Environment(\.uiScale) private var uiScale

    let title: String
    let probe: LayoutControlFrameProbe

    var body: some View {
        Button { } label: {
            Text(verbatim: title)
                .font(.cadenza(11, scale: uiScale))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.fill.quaternary, in: Capsule())
                .background { LayoutControlProbeView(probe: probe) }
        }
        .buttonStyle(.cadenzaPlain)
    }
}

private struct RecordingDetailTabControlProbe: View {
    @Environment(\.uiScale) private var uiScale

    let title: LocalizedStringKey
    let icon: String
    let probe: LayoutControlFrameProbe

    var body: some View {
        Button { } label: {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.cadenza(13, scale: uiScale))
                    Text(title)
                        .font(.cadenza(13, weight: .medium, scale: uiScale))
                }
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)

                RoundedRectangle(cornerRadius: 1)
                    .frame(height: 2)
                    .opacity(0)
            }
            .background { LayoutControlProbeView(probe: probe) }
        }
        .buttonStyle(.cadenzaPlain)
    }
}

private struct LegacyImportRecordingContentProbe: View {
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Image(systemName: "xmark")
                    .font(.cadenza(12, weight: .bold, scale: uiScale))
                    .frame(width: 26, height: 26)
            }
            .padding(.top, 16)
            .padding(.trailing, 16)

            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.plus")
                    .font(.cadenza(40, scale: uiScale))
                Text("Aufnahme importieren")
                    .font(.cadenza(20, weight: .bold, scale: uiScale))
                Text("Importieren Sie eine beliebige Audiodatei; wir transkribieren sie, erkennen Sprecher und erstellen eine strukturierte Besprechungsnotiz.")
                    .font(.cadenza(13, scale: uiScale))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .padding(.bottom, 20)

            HStack(spacing: 24) {
                picker(label: "Sprache")
                picker(label: "Sprache der Zusammenfassung")
            }
            .padding(.bottom, 20)

            VStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down")
                    .font(.cadenza(30, scale: uiScale))
                Text("Audio- oder Videodatei hier ablegen")
                    .font(.cadenza(13, weight: .medium, scale: uiScale))
                Button("Dateien durchsuchen") { }
                    .buttonStyle(.borderedProminent)
                Text("MP3, WAV, AIFF, FLAC, M4A, AAC, MP4, MOV")
                    .font(.cadenza(.caption, scale: uiScale))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func picker(label: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.cadenza(11, weight: .semibold, scale: uiScale))
            Picker("", selection: Binding.constant(TranscriptionLanguage.german)) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

private struct LegacyProjectDetailSelectorProbe: View {
    var body: some View {
        Picker("", selection: Binding.constant(0)) {
            Text("Recordings (\(999))").tag(0)
            Text("Action Items (\(999))").tag(1)
            Text("Decisions (\(999))").tag(2)
            Text("AI Brief").tag(3)
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

private struct LegacyProjectSuggestionRowProbe: View {
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        HStack(spacing: 6) {
            suggestion("What happened last time?")
            suggestion("What should I do next?")
            suggestion("What blockers are unresolved?")
        }
        .fixedSize()
    }

    private func suggestion(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.cadenza(11, scale: uiScale))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.fill.quaternary, in: Capsule())
    }
}

private struct LegacyRecordingDetailTabRowProbe: View {
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        HStack(spacing: 0) {
            tab("Summary", icon: "sparkles")
            tab("Action Items", icon: "checklist")
            tab("Transcript", icon: "text.bubble")
        }
        .fixedSize()
    }

    private func tab(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.cadenza(13, scale: uiScale))
            Text(title)
                .font(.cadenza(13, weight: .medium, scale: uiScale))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
    }
}

private struct LegacyRecordingDetailTranscriptToolbarProbe: View {
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.cadenza(13, scale: uiScale))
                Picker("", selection: Binding.constant(TranscriptionLanguage.german)) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            Spacer()

            Button { } label: {
                Label("Re-transcribe", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button { } label: {
                Label("Identify speakers", systemImage: "brain.head.profile")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button { } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu { } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.cadenza(13, scale: uiScale))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

private struct LegacyRecordingDetailSummaryToolbarProbe: View {
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        HStack(spacing: 10) {
            RecordingDetailLanguagePickerProbe(usesFixedLegacyWidth: true)
            Spacer()
            RecordingDetailSummaryActionsProbe()
        }
    }
}

private struct AdaptiveRecordingDetailTranscriptToolbarProbe: View {
    var body: some View {
        RecordingDetailToolbarLayout {
            RecordingDetailLanguagePickerProbe(usesFixedLegacyWidth: false)
        } actions: {
            RecordingDetailTranscriptActionsProbe()
        }
    }
}

private struct AdaptiveRecordingDetailSummaryToolbarProbe: View {
    var body: some View {
        RecordingDetailToolbarLayout {
            RecordingDetailLanguagePickerProbe(usesFixedLegacyWidth: false)
        } actions: {
            RecordingDetailSummaryActionsProbe()
        }
    }
}

private struct RecordingDetailLanguagePickerProbe: View {
    @Environment(\.uiScale) private var uiScale
    let usesFixedLegacyWidth: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.cadenza(13, scale: uiScale))
            Picker("", selection: Binding.constant(TranscriptionLanguage.german)) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .frame(
                minWidth: 130,
                maxWidth: usesFixedLegacyWidth ? 130 : nil
            )
        }
    }
}

private struct RecordingDetailTranscriptActionsProbe: View {
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        Button { } label: {
            Label("Re-transcribe", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button { } label: {
            Label("Identify speakers", systemImage: "brain.head.profile")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button { } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        RecordingDetailExportMenuProbe()
    }
}

private struct RecordingDetailSummaryActionsProbe: View {
    var body: some View {
        Button { } label: {
            Label("Regenerate", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button { } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        RecordingDetailExportMenuProbe()
    }
}

private struct RecordingDetailExportMenuProbe: View {
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        Menu { } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.cadenza(13, scale: uiScale))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

@Suite("Rubber-band AppKit hit testing")
struct RubberBandHitTestingTests {
    @MainActor @Test func scrollDocumentBackgroundStartsRubberBand() {
        let fixture = RubberBandHitTestFixture()
        let point = fixture.documentView.convert(NSPoint(x: 80, y: 80), to: nil)

        #expect(fixture.hitView(at: point) === fixture.documentView)
        #expect(
            RubberBandHitTesting.isScrollDocumentBackgroundHit(
                in: fixture.window,
                at: point
            )
        )
    }

    @MainActor @Test func buttonOverlayInsideDocumentPassesThrough() {
        let fixture = RubberBandHitTestFixture()
        let button = NSButton(title: "Batch action", target: nil, action: nil)
        button.frame = NSRect(x: 40, y: 40, width: 140, height: 32)
        fixture.documentView.addSubview(button)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)

        #expect(fixture.hitView(at: point) === button)
        #expect(
            !RubberBandHitTesting.isScrollDocumentBackgroundHit(
                in: fixture.window,
                at: point
            )
        )
    }

    @MainActor @Test func scrollBarPassesThrough() throws {
        let fixture = RubberBandHitTestFixture()
        let scroller = try #require(fixture.scrollView.verticalScroller)
        fixture.rootView.layoutSubtreeIfNeeded()
        let point = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)

        #expect(fixture.hitView(at: point) === scroller)
        #expect(
            !RubberBandHitTesting.isScrollDocumentBackgroundHit(
                in: fixture.window,
                at: point
            )
        )
    }

    @MainActor @Test func pageOverlayOutsideScrollViewPassesThrough() {
        let fixture = RubberBandHitTestFixture()
        let overlay = NSView(frame: NSRect(x: 80, y: 250, width: 220, height: 64))
        fixture.rootView.addSubview(overlay, positioned: .above, relativeTo: fixture.scrollView)
        let point = overlay.convert(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY), to: nil)

        #expect(fixture.hitView(at: point) === overlay)
        #expect(
            !RubberBandHitTesting.isScrollDocumentBackgroundHit(
                in: fixture.window,
                at: point
            )
        )
    }
}

@MainActor
private final class RubberBandHitTestFixture {
    let window: NSWindow
    let rootView: NSView
    let scrollView: NSScrollView
    let documentView: NSView

    init() {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        rootView = NSView(frame: frame)
        scrollView = NSScrollView(frame: frame)
        documentView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 800))

        window.contentView = rootView
        scrollView.scrollerStyle = .legacy
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.documentView = documentView
        rootView.addSubview(scrollView)
        rootView.layoutSubtreeIfNeeded()
    }

    func hitView(at locationInWindow: NSPoint) -> NSView? {
        rootView.hitTest(rootView.convert(locationInWindow, from: nil))
    }
}
