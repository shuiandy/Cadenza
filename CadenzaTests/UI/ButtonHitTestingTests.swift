import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Cadenza

/// 命中区域门禁。
///
/// `.buttonStyle(.plain)` 的命中区只覆盖 label 真正画出像素的地方：VStack 行距、
/// `.padding` 留白、`glassEffect` 玻璃背景都不算数。整块看着可点的卡片实际只有文字
/// 能点中——设置侧边栏（2026-08-02）和 Recaps 列表（2026-08-06）连撞两次。
///
/// 统一入口是 `CadenzaPlainButtonStyle`（`.cadenzaPlain` / `.cadenzaPlain(in:)`），
/// 命中形状写在 style 内部。裸 `.buttonStyle(.plain)` 一律拦下；确有必要的（Menu 的
/// label 不是 Button）在同一行写 `hit-test-exempt:` 加理由豁免。
@Suite struct ButtonHitTestingTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var productRoot: URL { repoRoot.appendingPathComponent("Cadenza") }
    private var styleURL: URL {
        productRoot.appendingPathComponent("Utilities/CadenzaButtonStyle.swift")
    }

    @Test func plainButtonStyleStaysBehindTheHitTestingBoundary() throws {
        let enumerator = try #require(FileManager.default.enumerator(
            at: productRoot,
            includingPropertiesForKeys: nil
        ))

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard fileURL.resolvingSymlinksInPath() != styleURL.resolvingSymlinksInPath() else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains(".buttonStyle(.plain)") else { continue }
                #expect(
                    line.contains("hit-test-exempt:"),
                    """
                    \(fileURL.lastPathComponent):\(index + 1) 用了裸 .buttonStyle(.plain)，\
                    命中区会缩到文字上。改用 .cadenzaPlain（非矩形用 .cadenzaPlain(in:)），\
                    或在同一行标注 hit-test-exempt: <理由>。
                    """
                )
            }
        }
    }

    @Test func styleOwnsContentShapeAndDisabledFeedback() throws {
        let source = try String(contentsOf: styleURL, encoding: .utf8)

        // 命中形状必须在 style body 内部——写在 Button 外面对命中区无效。
        #expect(source.contains(".contentShape(shape)"))
        #expect(source.contains("static var cadenzaPlain"))
        #expect(source.contains("static func cadenzaPlain<S: Shape>(in shape: S)"))
        // 自定义 style 接管后系统不再置灰禁用态，必须自己还原。
        #expect(source.contains("@Environment(\\.isEnabled)"))
        #expect(source.contains("configuration.isPressed"))
    }

    @Test func glassCardsCarryTheirOwnContentShape() throws {
        let source = try String(
            contentsOf: productRoot.appendingPathComponent("Utilities/ColorHex.swift"),
            encoding: .utf8
        )

        // appCard 的表面是 glassEffect（渲染效果，不参与 hit test），
        // 少了 contentShape 的话调用方的 .onHover 只在文字上触发。
        let cardModifier = try #require(source.range(of: "private struct AppCardModifier"))
        let body = source[cardModifier.lowerBound...].prefix(1600)
        #expect(body.contains(".contentShape(shape)"))
    }
}

@Suite("Scaled controls and isolated UI actions")
struct ScaledControlIsolationTests {
    private struct SymbolProbe {
        let symbol: String
        let renderedPointSize: CGFloat
        let metricPointSize: CGFloat
        let baseFrame: CGFloat
        let padding: CGFloat
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @MainActor @Test func repairedFramesContainRealSymbolsAtMaximumSupportedScale() {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let probes = [
            SymbolProbe(symbol: "plus.message", renderedPointSize: 14, metricPointSize: 14, baseFrame: 32, padding: 13),
            SymbolProbe(symbol: "sparkles", renderedPointSize: 14, metricPointSize: 14, baseFrame: 22, padding: 3),
            SymbolProbe(symbol: "bubble.left.and.bubble.right", renderedPointSize: 14, metricPointSize: 18, baseFrame: 24, padding: 0),
            SymbolProbe(symbol: "clock.arrow.circlepath", renderedPointSize: 12, metricPointSize: 12, baseFrame: 28, padding: 12),
            SymbolProbe(symbol: "sparkles", renderedPointSize: 10, metricPointSize: 10, baseFrame: 18, padding: 5),
            SymbolProbe(symbol: "at", renderedPointSize: 13, metricPointSize: 13, baseFrame: 30, padding: 13),
            SymbolProbe(symbol: "arrow.up", renderedPointSize: 13, metricPointSize: 13, baseFrame: 28, padding: 11),
            SymbolProbe(symbol: "terminal", renderedPointSize: 16, metricPointSize: 16, baseFrame: 34, padding: 13),
            SymbolProbe(symbol: "doc.richtext", renderedPointSize: 16, metricPointSize: 16, baseFrame: 34, padding: 13),
            SymbolProbe(symbol: "calendar", renderedPointSize: 17, metricPointSize: 17, baseFrame: 32, padding: 9),
            SymbolProbe(symbol: "brain", renderedPointSize: 16, metricPointSize: 16 * 1.15, baseFrame: 24, padding: 0),
        ]

        for probe in probes {
            let host = NSHostingView(
                rootView: Image(systemName: probe.symbol)
                    .font(.cadenza(probe.renderedPointSize, weight: .medium, scale: scale))
            )
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()

            let frame = CadenzaControlMetrics.squareIconFrame(
                base: probe.baseFrame,
                symbolPointSize: probe.metricPointSize,
                scale: scale,
                padding: probe.padding
            )
            let glyph = host.fittingSize

            #expect(glyph.width.isFinite)
            #expect(glyph.height.isFinite)
            #expect(frame >= glyph.width)
            #expect(frame >= glyph.height)
        }
    }

    @Test func repairedFramesPreserveDefaultControlSizesUnlessTheOldFrameAlreadyClipped() {
        #expect(CadenzaControlMetrics.squareIconFrame(base: 32, symbolPointSize: 14, scale: 1, padding: 13) == 32)
        #expect(CadenzaControlMetrics.squareIconFrame(base: 22, symbolPointSize: 14, scale: 1, padding: 3) == 22)
        #expect(CadenzaControlMetrics.squareIconFrame(base: 28, symbolPointSize: 12, scale: 1, padding: 12) == 28)
        #expect(CadenzaControlMetrics.squareIconFrame(base: 18, symbolPointSize: 10, scale: 1, padding: 5) == 18)
        #expect(CadenzaControlMetrics.squareIconFrame(base: 30, symbolPointSize: 13, scale: 1, padding: 13) == 30)
        #expect(CadenzaControlMetrics.squareIconFrame(base: 34, symbolPointSize: 16, scale: 1, padding: 13) == 34)
        #expect(CadenzaControlMetrics.squareIconFrame(base: 32, symbolPointSize: 17, scale: 1, padding: 9) == 32)

        // The double-bubble symbol was already 24pt wide in the old 20pt slot.
        #expect(CadenzaControlMetrics.squareIconFrame(base: 24, symbolPointSize: 18, scale: 1, padding: 0) == 24)
    }

    @MainActor @Test func floatingHeaderReflowsInsideItsFixedSidebarAtMaximumScale() {
        let narrow = NSHostingView(
            rootView: FloatingChatHeaderLayout {
                Color.clear.frame(width: 280, height: 110)
            } actions: {
                Color.clear.frame(width: 274, height: 61)
            }
            .frame(width: 368)
        )
        narrow.sizingOptions = [.intrinsicContentSize]
        narrow.layoutSubtreeIfNeeded()

        let wide = NSHostingView(
            rootView: FloatingChatHeaderLayout {
                Color.clear.frame(width: 280, height: 110)
            } actions: {
                Color.clear.frame(width: 274, height: 61)
            }
            .frame(width: 700)
        )
        wide.sizingOptions = [.intrinsicContentSize]
        wide.layoutSubtreeIfNeeded()

        #expect(narrow.fittingSize.width == 368)
        #expect(narrow.fittingSize.height >= 181)
        #expect(wide.fittingSize.height < narrow.fittingSize.height)
    }

    @MainActor @Test func orderedListMarkerUsesItsNaturalWidthBeyondTheMinimum() throws {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let marker = NSHostingView(
            rootView: Text("1000.")
                .font(.cadenzaBody(14, weight: .semibold, scale: scale))
        )
        marker.sizingOptions = [.intrinsicContentSize]
        marker.layoutSubtreeIfNeeded()

        let markdown = try source("Cadenza/Views/Chat/MarkdownMessageView.swift")
        #expect(marker.fittingSize.width > 18)
        #expect(markdown.contains(".frame(minWidth: 18, alignment: .trailing)"))
        #expect(!markdown.contains(".frame(width: 18, alignment: .trailing)"))
    }

    @MainActor @Test func localizedProfileActionsReflowInsideTheFixedSheetColumn() {
        let natural = NSHostingView(
            rootView: HStack {
                Button("Abbrechen") {}
                Spacer()
                Button("Dieses Profil verknüpfen") {}
                Button("Kontoprofil erstellen") {}
            }
        )
        natural.sizingOptions = [.intrinsicContentSize]
        natural.layoutSubtreeIfNeeded()

        let narrow = NSHostingView(
            rootView: ProfileLoginActionLayout {
                Button("Abbrechen") {}
            } actions: {
                Button("Dieses Profil verknüpfen") {}
                Button("Kontoprofil erstellen") {}
            }
            .frame(width: 372)
        )
        narrow.sizingOptions = [.intrinsicContentSize]
        narrow.layoutSubtreeIfNeeded()

        let wide = NSHostingView(
            rootView: ProfileLoginActionLayout {
                Button("Abbrechen") {}
            } actions: {
                Button("Dieses Profil verknüpfen") {}
                Button("Kontoprofil erstellen") {}
            }
            .frame(width: 440)
        )
        wide.sizingOptions = [.intrinsicContentSize]
        wide.layoutSubtreeIfNeeded()

        #expect(natural.fittingSize.width > 372)
        #expect(narrow.fittingSize.width == 372)
        #expect(narrow.fittingSize.height > wide.fittingSize.height)
    }

    @MainActor @Test func chatSuggestionsReflowAtMaximumScaleWithoutTruncatingLocalizedLabels() {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let initialLabels = [
            "Actions de ma dernière réunion",
            "Décisions clés cette semaine",
            "Trouver des réunions par sujet",
            "Suivis en cours",
        ]
        let followUpLabels = [
            "Wer ist für jede Aufgabe verantwortlich?",
            "Was sind die Fristen für diese Aufgaben?",
            "Gab es Einwände oder diskutierte Alternativen?",
        ]

        let naturalInitial = NSHostingView(
            rootView: HStack(spacing: 10) {
                ForEach(initialLabels, id: \.self) { label in
                    Text(label)
                        .font(.cadenza(14, scale: scale))
                        .fixedSize()
                        .padding(14)
                }
            }
        )
        naturalInitial.sizingOptions = [.intrinsicContentSize]
        naturalInitial.layoutSubtreeIfNeeded()

        let stackedInitial = NSHostingView(
            rootView: AIChatSuggestionLayout(
                stacked: true,
                spacing: 10,
                accessibleColumns: 2
            ) {
                ForEach(initialLabels, id: \.self) { label in
                    Button {} label: {
                        Text(label)
                            .font(.cadenza(14, scale: scale))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                            .padding(14)
                    }
                    .buttonStyle(.cadenzaPlain)
                }
            }
            .frame(width: 640)
        )
        stackedInitial.sizingOptions = [.intrinsicContentSize]
        stackedInitial.layoutSubtreeIfNeeded()

        let stackedFollowUps = NSHostingView(
            rootView: AIChatSuggestionLayout(stacked: true, spacing: 8) {
                ForEach(followUpLabels, id: \.self) { label in
                    Button {} label: {
                        Text(label)
                            .font(.cadenza(13, scale: scale))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.cadenzaPlain)
                }
            }
            .frame(width: 640)
        )
        stackedFollowUps.sizingOptions = [.intrinsicContentSize]
        stackedFollowUps.layoutSubtreeIfNeeded()

        #expect(naturalInitial.fittingSize.width > 640)
        #expect(stackedInitial.fittingSize.width == 640)
        #expect(stackedInitial.fittingSize.height >= CGFloat(initialLabels.count / 2) * 44)
        #expect(stackedFollowUps.fittingSize.width == 640)
        #expect(stackedFollowUps.fittingSize.height >= CGFloat(followUpLabels.count) * 44)
    }

    @MainActor @Test func chatHistoryHeaderReflowsInsideTheAccessiblePopover() throws {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let natural = NSHostingView(
            rootView: HStack {
                Text("Historique des discussions")
                    .font(.cadenza(13, weight: .semibold, scale: scale))
                    .fixedSize()
                Spacer(minLength: 12)
                Button("Tout effacer") {}
                    .font(.cadenza(12, scale: scale))
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        )
        natural.sizingOptions = [.intrinsicContentSize]
        natural.layoutSubtreeIfNeeded()

        let adaptive = NSHostingView(
            rootView: AIChatHistoryHeaderLayout {
                Text("Historique des discussions")
                    .font(.cadenza(13, weight: .semibold, scale: scale))
                    .fixedSize()
            } actions: {
                Button("Tout effacer") {}
                    .font(.cadenza(12, scale: scale))
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 320)
        )
        adaptive.sizingOptions = [.intrinsicContentSize]
        adaptive.layoutSubtreeIfNeeded()

        let source = try source("Cadenza/Views/Chat/AIChatView.swift")
        #expect(natural.fittingSize.width > 320)
        #expect(adaptive.fittingSize.width == 320)
        #expect(adaptive.fittingSize.height > natural.fittingSize.height)
        #expect(source.contains(".frame(width: usesAccessibleLayout ? 640 : 320)"))
        #expect(source.contains(".frame(maxHeight: 340)"))
    }

    @MainActor @Test func recordingStorageActionsReflowWithinTheNarrowSettingsColumn() {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let path = "/Volumes/Fictional Archive/Cadenza Recordings"
        let actions = [
            "Dossier personnalisé...",
            "Ouvrir dans le Finder",
            "Rétablir les valeurs par défaut",
        ]

        let natural = NSHostingView(
            rootView: HStack(spacing: 8) {
                Text(path)
                    .font(.cadenza(13, design: .monospaced, scale: scale))
                    .fixedSize()
                ForEach(actions, id: \.self) { label in
                    Button(label) {}
                        .fixedSize()
                }
            }
        )
        natural.sizingOptions = [.intrinsicContentSize]
        natural.layoutSubtreeIfNeeded()

        let adaptive = NSHostingView(
            rootView: RecordingStorageHeaderLayout(stacked: true) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                    Text(path)
                        .font(.cadenza(13, design: .monospaced, scale: scale))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } actions: {
                RecordingStorageActionLayout(stacked: true) {
                    ForEach(actions, id: \.self) { label in
                        Button(label) {}
                            .frame(minHeight: 44)
                    }
                }
            }
            .frame(width: 530)
        )
        adaptive.sizingOptions = [.intrinsicContentSize]
        adaptive.layoutSubtreeIfNeeded()

        #expect(natural.fittingSize.width > 530)
        #expect(adaptive.fittingSize.width == 530)
        #expect(adaptive.fittingSize.height >= CGFloat(actions.count) * 44)
    }

    @MainActor @Test func recordingPermissionReaderSkipsTCCOutsideTheStandardPolicy() {
        var reads = 0
        let reader = RecordingMicrophonePermissionReader {
            reads += 1
            return .granted
        }

        #expect(reader.status(for: .isolatedFixture) == .notDetermined)
        #expect(reader.status(for: .testHost) == .notDetermined)
        #expect(reads == 0)
        #expect(reader.status(for: .standard) == .granted)
        #expect(reads == 1)
    }

    @MainActor @Test func calendarColorSwatchContainsItsRealGlyphAndScalesItsHitFrame() {
        let scale = CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
        let glyph = NSHostingView(
            rootView: Image(systemName: "checkmark")
                .font(.cadenza(.caption2, weight: .bold, scale: scale))
        )
        glyph.sizingOptions = [.intrinsicContentSize]
        glyph.layoutSubtreeIfNeeded()

        let button = NSHostingView(
            rootView: CalendarColorSwatchButton(option: .purple, isSelected: true) {}
                .environment(\.uiScale, scale)
        )
        button.sizingOptions = [.intrinsicContentSize]
        button.layoutSubtreeIfNeeded()

        let swatchSize = CalendarColorSwatchMetrics.swatchSize(scale: scale)
        let hitSize = CalendarColorSwatchMetrics.hitSize(scale: scale)
        #expect(swatchSize >= glyph.fittingSize.width)
        #expect(swatchSize >= glyph.fittingSize.height)
        #expect(hitSize >= 44)
        #expect(button.fittingSize.width >= hitSize)
        #expect(button.fittingSize.height >= hitSize)
    }

    @MainActor @Test func whisperProgressTrackKeepsItsAuthoredWidthWithoutTextClipping() throws {
        let progress = NSHostingView(
            rootView: ProgressView(value: 0.5)
                .frame(width: 60)
        )
        progress.sizingOptions = [.intrinsicContentSize]
        progress.layoutSubtreeIfNeeded()

        let picker = try source("Cadenza/Views/Settings/WhisperModelPicker.swift")
        #expect(progress.fittingSize.width == 60)
        #expect(progress.fittingSize.height > 0)
        #expect(picker.contains("ProgressView(value: progress)\n                        .frame(width: 60)"))
    }

    @Test func isolatedFixturePolicyDisablesExternalUICapabilities() {
        let policy = AppState.StartupPolicy.isolatedFixture
        #expect(!policy.allowsContentGeneration)
        #expect(!policy.allowsHardwareCapture)
        #expect(!policy.externalAccessEnabled)
    }

    @Test func chatServiceConstructionIsGuardedByTheRuntimePolicy() throws {
        let fullPage = try source("Cadenza/Views/Chat/AIChatView.swift")
        let floating = try source("Cadenza/Views/Chat/FloatingAIChatButton.swift")
        let modelMenu = try source("Cadenza/Views/Chat/AIChatModelMenu.swift")

        #expect(try guardPrecedesSink(
            in: fullPage,
            scope: "private func resolveAIService()",
            guardText: "guard appState.startupPolicy.allowsContentGeneration else { return nil }",
            sink: "selectedProvider.makeChatService"
        ))
        #expect(try guardPrecedesSink(
            in: floating,
            scope: "private func sendMessage(",
            guardText: "guard appState.startupPolicy.allowsContentGeneration else { return }",
            sink: "resolveAIService()"
        ))
        #expect(try guardPrecedesSink(
            in: floating,
            scope: "private func resolveAIService()",
            guardText: "guard appState.startupPolicy.allowsContentGeneration else { return nil }",
            sink: "selectedProvider.makeChatService"
        ))
        #expect(try guardPrecedesSink(
            in: modelMenu,
            scope: "private func refreshModels",
            guardText: "guard appState.startupPolicy.allowsContentGeneration else { return }",
            sink: "let modelListService = AIChatModelListService()"
        ))
        #expect(!modelMenu.contains("private let modelListService = AIChatModelListService()"))
        #expect(fullPage.contains(".disabled(streamState.isActive || !appState.startupPolicy.allowsContentGeneration)"))
        #expect(floating.contains(".disabled(streamState.isActive || !appState.startupPolicy.allowsContentGeneration)"))
    }

    @Test func settingsSensitiveActionsAreGuardedAtUIAndSinkBoundaries() throws {
        let settings = try source("Cadenza/Views/Settings/SettingsView.swift")
        let connections = try source("Cadenza/Views/Settings/ConnectionsSection.swift")
        let integrations = try source("Cadenza/Views/Settings/IntegrationsSettingsView.swift")

        #expect(try guardPrecedesSink(
            in: settings,
            scope: "private func requestMicrophoneAccess",
            guardText: "guard appState.startupPolicy.allowsHardwareCapture else { return }",
            sink: "Permissions.requestMicrophone()"
        ))
        #expect(try guardPrecedesSink(
            in: settings,
            scope: "private struct ScreenRecordingPermissionRow",
            guardText: "guard appState.startupPolicy.allowsHardwareCapture else { return }",
            sink: "Permissions.requestScreenRecording()"
        ))
        #expect(try guardPrecedesSink(
            in: settings,
            scope: "private struct SystemAudioCapturePreparationRow",
            guardText: "guard appState.startupPolicy.allowsHardwareCapture else { return }",
            sink: "Permissions.openSystemAudioRecordingSettings()"
        ))
        #expect(try guardPrecedesSink(
            in: settings,
            scope: "struct ConnectionsInline",
            guardText: "guard appState.startupPolicy.externalAccessEnabled else { return }",
            sink: "Permissions.requestOrRecoverCalendarAccess("
        ))
        #expect(try guardPrecedesSink(
            in: connections,
            scope: "struct ConnectionsSection",
            guardText: "guard appState.startupPolicy.externalAccessEnabled else { return }",
            sink: "Permissions.requestOrRecoverCalendarAccess("
        ))
        #expect(try guardPrecedesSink(
            in: settings,
            scope: "private func chooseDirectory()",
            guardText: "guard appState.startupPolicy != .isolatedFixture else { return }",
            sink: "let panel = NSOpenPanel()"
        ))
        #expect(try guardPrecedesSink(
            in: settings,
            scope: "private func applyNewDirectory",
            guardText: "guard appState.startupPolicy != .isolatedFixture else",
            sink: "StorageMigrationGate.shared.claimMigration()"
        ))
        #expect(try guardPrecedesSink(
            in: integrations,
            scope: "private struct ProviderRow",
            guardText: "guard appState.startupPolicy.externalAccessEnabled else { return }",
            sink: "let credentialValidator = AIProviderCredentialValidator()"
        ))

        #expect(settings.contains(".disabled(!appState.startupPolicy.allowsHardwareCapture)"))
        #expect(settings.contains(".disabled(!appState.startupPolicy.externalAccessEnabled)"))
        #expect(settings.contains("if appState.startupPolicy.externalAccessEnabled {\n                DiagnosticsSection"))
        #expect(settings.contains("launchAtLogin = SMAppService.mainApp.status == .enabled"))
        #expect(!settings.contains("@State private var microphoneStatus = Permissions.microphoneStatus"))
        #expect(settings.contains("guard startupPolicy.checksPermissions else { return .notDetermined }"))
        #expect(settings.contains("guard appState.startupPolicy.checksPermissions else"))
        #expect(integrations.contains(".disabled(!appState.startupPolicy.externalAccessEnabled)"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func guardPrecedesSink(
        in source: String,
        scope: String,
        guardText: String,
        sink: String
    ) throws -> Bool {
        let scopeRange = try #require(source.range(of: scope))
        let scopedSource = source[scopeRange.lowerBound...]
        let guardRange = try #require(scopedSource.range(of: guardText))
        let sinkRange = try #require(scopedSource.range(of: sink))
        return guardRange.lowerBound < sinkRange.lowerBound
    }
}
