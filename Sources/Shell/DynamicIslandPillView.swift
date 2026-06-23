import SwiftUI
import Weather

/// 灵动岛 SwiftUI 内容视图(借鉴 HermesPet `DynamicIslandPillView` 路线)。
///
/// 跟随当前 weather condition 显示对应 SF Symbol 图标。idle 状态(无 weather wire
/// 或 condition 未知)显示纯黑胶囊,跟之前 NSView 路径视觉一致。
///
/// **关键架构决策**:用 `NSHostingController` 而不是 `NSHostingView` 装载本视图。
/// `NSHostingView` 在 macOS 26 上即便 `sizingOptions = []` 仍会通过
/// `updateAnimatedWindowSize` 在 CA transaction commit 期间反推 NSWindow.setFrame
/// → 跟灵动岛的 `EmbeddableIslandPanel.constrainFrameRect` override 强冲突 → 必崩。
/// `NSHostingController.sizingOptions = []` 能真正禁掉那条路径(HermesPet v1.2.4
/// 实测决策)。
@MainActor
struct DynamicIslandPillView: View {
    @ObservedObject var viewModel: DynamicIslandPillViewModel

    var body: some View {
        ZStack {
            // 贴合物理刘海的形状: 顶部直角(跟物理屏顶 / 刘海无缝衔接)+ 底部
            // 圆角(微大于物理刘海底部圆角形成"包裹感"耳朵效果)。
            //
            // 跟之前 Capsule (全圆角)的视觉差异:
            // - Capsule 顶部也是半圆 → 跟物理屏顶有 ~半个高度的"空白弧" → 灵
            //   动岛跟刘海是分离的两个形状
            // - UnevenRoundedRectangle 顶直角 → panel 顶贴物理屏顶 → 灵动岛
            //   看起来是物理刘海的延伸 (iPhone 16 灵动岛同款视觉)
            //
            // macOS 13.0+ UnevenRoundedRectangle 原生支持。
            // bottomRadius 用 .infinity 让 SwiftUI 自己算出 min(width, height)/2
            // 是不对的 — 此值会让两个底角的弧合并成一整个半圆。这里显式给
            // pillHeight 的一半作为底圆角半径, 跟物理刘海底圆角接近 (~14pt)。
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: viewModel.bottomCornerRadius,
                bottomTrailingRadius: viewModel.bottomCornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)

            // 中心 SF Symbol — 仅当 weather wire 推了 icon 时显示。
            // idle/未知 condition 不画 icon, 保持纯黑胶囊 = 跟旧 NSView 视觉对齐。
            if let icon = viewModel.iconSymbolName {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(viewModel.iconColor)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        // 视图必须撑满 panel.contentView 的 frame, 否则 SwiftUI intrinsic
        // content size 会让胶囊缩到 SF Symbol 大小。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 灵动岛内容状态。`@Published` 字段变化时 SwiftUI 自动 re-render,
/// `DynamicIslandController.updateWeather(_:)` 在 weather refresh 时调用。
@MainActor
final class DynamicIslandPillViewModel: ObservableObject {
    /// 当前显示的 SF Symbol 名;nil = 不显示(idle / 纯黑胶囊)。
    @Published var iconSymbolName: String?

    /// icon 颜色。雪用淡蓝 / 雨用蓝 / 晴用黄 / 多云用白。
    @Published var iconColor: Color = .white

    /// 胶囊底部两侧的圆角半径 (顶部固定直角)。
    /// 由 controller 在 init 时按 panel 高度算好 (= pillHeight / 2),
    /// 跟物理刘海底圆角 (~14pt for MBP 14"/16") 接近, 形成"耳朵包裹"感。
    @Published var bottomCornerRadius: CGFloat = 18

    init(bottomCornerRadius: CGFloat = 18) {
        self.bottomCornerRadius = bottomCornerRadius
    }

    /// 按 weather condition 设 icon + color。nil = 清空 (idle)。
    func applyCondition(_ condition: WeatherConditionKind?) {
        guard let condition else {
            iconSymbolName = nil
            iconColor = .white
            return
        }
        switch condition {
        case .sunny:
            iconSymbolName = "sun.max.fill"
            iconColor = .yellow
        case .cloudy:
            iconSymbolName = "cloud.fill"
            iconColor = .white.opacity(0.85)
        case .rainy:
            iconSymbolName = "cloud.rain.fill"
            iconColor = Color(red: 0.55, green: 0.78, blue: 1.0)
        case .snowy:
            iconSymbolName = "snowflake"
            iconColor = Color(red: 0.78, green: 0.92, blue: 1.0)
        case .windy:
            iconSymbolName = "wind"
            iconColor = .white.opacity(0.85)
        }
    }
}
