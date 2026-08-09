import SwiftUI

// MARK: - Hit-testing Boundary
//
// SwiftUI 的 `.buttonStyle(.plain)` 只把 label **真正画出像素的地方** 算进命中区域。
// VStack 的行距、`.padding` 撑开的留白、`Spacer()`，以及 `glassEffect` 铺的玻璃背景
// 全都不参与 hit test —— 于是一张看着是整块面板的玻璃卡片，实际只有文字那几行能点中。
// （`.background(Circle().fill(...))` 这类实心填充是绘制内容，反而是可点的，所以同一个
// app 里有的按钮"整块能点"、有的"只有字能点"，行为完全不一致。）
//
// 修法只有一个位置有效：`.contentShape` 必须在 **label 内部或 style 内部**。写在
// `Button { } label: { }` 外面的 `.contentShape` 对按钮命中区毫无作用（2026-08-02
// 设置侧边栏那次就是踩在这上面）。
//
// 所以命中形状统一收进 style：全 app 一律用 `.cadenzaPlain`，新写的按钮不必再各自记得
// 补 `.contentShape`。门禁 `ButtonHitTestingTests` 扫源码禁止裸 `.buttonStyle(.plain)`。

/// 无外观按钮样式：整块 label 可点，并补上 `.plain` 缺失的按下 / 禁用反馈。
struct CadenzaPlainButtonStyle<S: Shape>: ButtonStyle {
    let shape: S

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, shape: shape)
    }

    /// `isEnabled` 只能在 View 里读，ButtonStyle 本身读不到，故套一层。
    private struct StyleBody: View {
        let configuration: Configuration
        let shape: S
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .contentShape(shape)
                .opacity(opacity)
        }

        /// `.plain` 由系统负责置灰禁用态；自定义 style 接管后必须自己还原，
        /// 否则禁用的按钮看着和可用的一模一样。
        private var opacity: Double {
            guard isEnabled else { return 0.5 }
            return configuration.isPressed ? 0.72 : 1
        }
    }
}

extension ButtonStyle where Self == CadenzaPlainButtonStyle<Rectangle> {
    /// 整块可点的无外观按钮。绝大多数场景用这个。
    static var cadenzaPlain: Self { CadenzaPlainButtonStyle(shape: Rectangle()) }
}

extension ButtonStyle {
    /// 圆形 / 胶囊等非矩形按钮：命中区跟着可见形状走，
    /// 免得矩形四角吃掉相邻控件或下层内容的点击。
    static func cadenzaPlain<S: Shape>(in shape: S) -> CadenzaPlainButtonStyle<S>
    where Self == CadenzaPlainButtonStyle<S> {
        CadenzaPlainButtonStyle(shape: shape)
    }
}
