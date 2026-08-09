import AppKit
import SwiftUI
import Testing
@testable import Cadenza

/// 工作区面板的材质分工。
///
/// **实心内容面板浮在半透明 chrome 之上**，不是反过来。把大面积内容区做成玻璃、
/// 再拿不透明背景垫底，层次会整个塌掉（2026-08-07 对比 Craft 确认）。
///
/// 实心还绕开了 `glassEffect` 的渲染尺寸上限：面板宽到 ~1500pt（retina 3000px）时，
/// 玻璃有一条根本不画，直接露出窗口本体、右下角见桌面。窄窗口不复现、空隙宽度随窗口
/// 变宽而变宽，所以极易漏测——这也是为什么把它钉成门禁而不是靠记性。
@Suite struct WorkspacePanelSizingTests {
    private var productRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Cadenza")
    }

    /// 铺满工作区的那两个面板（普通页面 + 录音详情页）必须是实心面板。
    @Test func fullPageContentUsesTheSolidPanel() throws {
        let source = try String(
            contentsOf: productRoot.appendingPathComponent("Views/TabBar/TabContentView.swift"),
            encoding: .utf8
        )

        let solid = source.components(separatedBy: ".appWorkspacePanel(").count - 1
        #expect(
            solid == 2,
            "TabContentView 里铺满工作区的面板应有 2 处（layeredContent + RecordingDetailPage），实际 \(solid) 处"
        )
        #expect(
            !source.contains(".appGlassPanel("),
            """
            TabContentView 的全页内容区用了玻璃面板 —— 超过 ~1500pt 会有一条不绘制、\
            直接露出桌面，而且层次是反的。内容面板要实心。
            """
        )
    }

    /// 实心面板里不能混进玻璃，否则尺寸上限那条又回来了。
    @Test func solidPanelHasNoGlass() throws {
        let source = try String(
            contentsOf: productRoot.appendingPathComponent("Utilities/ColorHex.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private struct AppWorkspacePanelModifier"))
        let body = String(source[start.lowerBound...].prefix(800))

        #expect(!body.contains("cadenzaGlass"), "内容面板用了玻璃 —— 超宽时会有一条不绘制")
        #expect(body.contains("textBackgroundColor"), "内容面板要实心底色")
        #expect(body.contains("strokeBorder"), "轮廓要显式描边，不能依赖玻璃的边缘")
    }

    /// 共享玻璃组件反过来必须保持真正透明 —— 别再往里塞不透明兜底。
    /// 它同时服务 Recap 卡片 / 设置 / 集成面板 / toolbar rail。
    @Test func sharedGlassPanelStaysTransparent() throws {
        let source = try String(
            contentsOf: productRoot.appendingPathComponent("Utilities/ColorHex.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private struct AppGlassPanelModifier"))
        let body = String(source[start.lowerBound...].prefix(700))

        #expect(!body.contains("windowBackgroundColor"), "appGlassPanel 垫了不透明底，玻璃不再采样环境背景")
        #expect(!body.contains("regularMaterial"), "appGlassPanel 被换成了 material，全 app 玻璃观感会变")
        #expect(body.contains("cadenzaGlass"))
    }
}

@Suite("Main workspace maximum-scale layout")
struct MainWorkspaceMaximumScaleLayoutTests {
    private var maximumScale: CGFloat {
        CadenzaTextScale.combined(
            uiScale: UIScalePreset.large.scaleFactor,
            dynamicTypeSize: .accessibility5
        )
    }

    @MainActor @Test func everyFixedChromeFrameContainsItsRealScaledSymbol() {
        let scale = maximumScale
        let probes: [(symbol: String, pointSize: CGFloat, frame: CGFloat)] = [
            (
                "square.and.arrow.down",
                15,
                MainWindowLayoutMetrics.sidebarControlDimension(scale: scale)
            ),
            (
                "xmark",
                11,
                MainWindowLayoutMetrics.folderCloseControlDimension(scale: scale)
            ),
            (
                "folder.badge.plus",
                13,
                MainWindowLayoutMetrics.sidebarIconColumnWidth(pointSize: 13, scale: scale)
            ),
            (
                "externaldrive.connected.to.line.below",
                15,
                MainWindowLayoutMetrics.folderIconCellDimension(scale: scale)
            ),
            (
                "arrow.up.arrow.down",
                15,
                RecordingsTopBarLayoutMetrics.controlDimension(scale: scale)
            ),
            (
                "sparkles",
                10,
                RecordingOverlayLayoutMetrics.iconDimension(base: 18, fontSize: 10, scale: scale)
            ),
        ]

        for probe in probes {
            let host = NSHostingView(
                rootView: Image(systemName: probe.symbol)
                    .font(.cadenza(probe.pointSize, weight: .medium, scale: scale))
            )
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()

            #expect(host.fittingSize.width.isFinite)
            #expect(host.fittingSize.height.isFinite)
            #expect(probe.frame >= host.fittingSize.width)
            #expect(probe.frame >= host.fittingSize.height)
        }
    }

    @MainActor @Test func folderEditorUsesItsRealIntrinsicHeightInsteadOfClippingAt280Points() {
        let scale = maximumScale
        let appState = AppState(startupPolicy: .testHost)
        let root = FolderFormSheet(mode: .create, onDismiss: {})
            .environment(appState)
            .environment(\.uiScale, scale)
            .environment(\.dynamicTypeSize, .accessibility5)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()

        let size = host.fittingSize
        #expect(size.width == MainWindowLayoutMetrics.folderSheetWidth(scale: scale))
        #expect(size.height > 280)
        #expect(size.height.isFinite)
    }

    @MainActor @Test func folderIconPickerUsesAdaptiveCellsAtMaximumScale() {
        let scale = maximumScale
        let root = FolderIconPicker(selection: .constant("folder"))
            .environment(\.uiScale, scale)
            .environment(\.dynamicTypeSize, .accessibility5)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()

        let expected = MainWindowLayoutMetrics.folderIconPickerSize(scale: scale)
        #expect(host.fittingSize.width == expected.width)
        #expect(host.fittingSize.height == expected.height)

        let symbol = NSHostingView(
            rootView: Image(systemName: "externaldrive.connected.to.line.below")
                .font(.cadenza(15, scale: scale))
        )
        symbol.sizingOptions = [.intrinsicContentSize]
        symbol.layoutSubtreeIfNeeded()
        let cell = MainWindowLayoutMetrics.folderIconCellDimension(scale: scale)
        #expect(cell >= symbol.fittingSize.width)
        #expect(cell >= symbol.fittingSize.height)
    }

    @MainActor @Test func recordingsTopBarReflowsIntoTwoRowsAtMaximumScale() {
        let scale = maximumScale
        let appState = AppState(startupPolicy: .testHost)
        let width: CGFloat = 400
        let root = RecordingsTopBar()
            .environment(appState)
            .environment(\.uiScale, scale)
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: width)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()

        let control = RecordingsTopBarLayoutMetrics.controlDimension(scale: scale)
        #expect(RecordingsTopBarLayoutMetrics.usesStackedLayout(scale: scale))
        #expect(host.fittingSize.width == width)
        #expect(host.fittingSize.height >= control * 2 + 6)
        #expect(host.fittingSize.height.isFinite)
    }

    @MainActor @Test func toolbarStatusPhrasesFitWithinTwoLinesAtMaximumScale() {
        let scale = maximumScale
        let statusWidth = MainWindowLayoutMetrics.toolbarStatusMaximumWidth(scale: scale)
        #expect(MainWindowLayoutMetrics.toolbarLineLimit(scale: scale) == 2)

        for phrase in ["Generating summary...", "Transcribing 100%"] {
            let host = NSHostingView(
                rootView: Text(phrase)
                    .font(.cadenza(12, weight: .semibold, scale: scale))
                    .fixedSize()
            )
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()

            #expect(host.fittingSize.width <= statusWidth * 2)
        }
    }

    @MainActor @Test func isolatedFixtureCannotCreateRecordingOrPromptPanels() {
        let appState = AppState(startupPolicy: .isolatedFixture)
        let controller = RecordingOverlayController()

        controller.show(appState: appState)
        controller.showPrompt(appState: appState)

        #expect(!appState.startupPolicy.allowsHardwareCapture)
        #expect(!appState.startupPolicy.allowsContentGeneration)
        #expect(!controller.isShowing)
        #expect(!controller.isPromptShowing)
    }

    @Test func overlayDirectHardwareAndAIEntryPointsKeepDeepIsolationGuards() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Cadenza/Views/Main/RecordingOverlayPanel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("guard appState.startupPolicy.allowsHardwareCapture else { return [] }"))
        #expect(source.contains("guard appState.startupPolicy.allowsContentGeneration else { return [] }"))
        #expect(source.contains("guard appState.startupPolicy.allowsContentGeneration else { return nil }"))
        #expect(source.contains("guard appState.startupPolicy.allowsContentGeneration else { return }"))
        #expect(source.contains("String(localized: \"No AI provider configured. Please add an API key in Settings.\")"))
        #expect(source.contains("String(localized: \"AI response failed: \\(error.localizedDescription)\")"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
