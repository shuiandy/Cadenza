import SwiftUI

// MARK: - macOS Compatibility Boundary
//
// 单一入口：所有只存在于 macOS 26+ 的 UI API 都在本文件里做 availability 分支，
// 其余源码一律调用这里的 `cadenza*` 封装，禁止裸调用。门禁测试
// `RecordingsChromeLayoutTests.macOS26VisualAPIsStayBehindCompatibilityBoundary`
// 扫描 `Cadenza/` 全部源码强制这条边界（本文件是唯一豁免），换文件名要同步改测试里的
// `compatibilityURL`。
//
// ⚠️ **旧系统分支目前是 no-op，不是可用的降级实现。**
// deployment target 仍是 macOS 26（`project.yml`），所以 `else` 分支永远不可达，
// 写在这里只是把"真要降版本时得改哪里"钉死在一个文件内。**不要把
// `MACOSX_DEPLOYMENT_TARGET=15.0` 能编过当成"15 上能用"** —— 那样跑起来玻璃面全部消失，
// 控件没有任何背景，文字直接浮在内容上。降版本的完整待办见 ARCHITECTURE.md §8.11。

struct CadenzaGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func cadenzaGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                if let tint {
                    glassEffect(.regular.interactive().tint(tint), in: shape)
                } else {
                    glassEffect(.regular.interactive(), in: shape)
                }
            } else if let tint {
                glassEffect(.regular.tint(tint), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            // Material fallback is intentionally deferred until macOS 15 support is scheduled.
            self
        }
    }

    @ViewBuilder
    func cadenzaGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            self
        }
    }

    @ViewBuilder
    func cadenzaSafeAreaBar<BarContent: View>(
        edge: VerticalEdge,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> BarContent
    ) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: edge, alignment: alignment, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
        }
    }

    @ViewBuilder
    func cadenzaSoftTopScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
