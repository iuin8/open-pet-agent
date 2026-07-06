import SwiftUI

/// Composer 输入框上方的「回复来源」选择器 —— 一行紧凑 segmented。
///
/// 让用户**一眼看到并切换** pet 的回复路径(灵魂层 vs Agent 层 engine),不必去
/// 设置深处找开关(§AGENTS.md 直觉可用性):可见(可供性)、点了就切(零学习)、
/// 选中态 accent 高亮(状态可见)、默认 🐾 灵魂层(开箱即用)。
///
/// 视觉与顶部 `CompanionTabBar`(内容视图)**层级区分**:本栏更紧凑(图标+短标签,
/// 嵌在输入区上方圆角托盘内),tab bar 在顶部较粗 —— 两处同名(Claude Code/Codex)
/// 时靠位置 + 视觉重量区分语义。选中态:accent 文字 + 卡底填充 + 底部 accent 指示条。
struct ReplySourceBar: View {
    @Binding var selected: ReplyTarget
    let options: [ReplyOption]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                segmentButton(option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ChatCardTheme.inputFill.opacity(0.7))
        )
    }

    // MARK: - 单段

    private func segmentButton(_ option: ReplyOption) -> some View {
        let isSelected = option.target == selected
        return Button {
            selected = option.target
        } label: {
            segmentIcon(for: option, isSelected: isSelected)
                .foregroundStyle(isSelected ? ChatCardTheme.accent : ChatCardTheme.textPrimary.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(segmentBackground(isSelected: isSelected))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(option.label) · \(option.target.isSoul ? "灵魂层 · 自然对话" : "Agent 层 · 让 pet 干活")")
    }

    /// 品牌 logo 优先(Claude/Codex),否则 SF Symbol。尺寸与 10pt 文字对齐。
    @ViewBuilder
    private func segmentIcon(for option: ReplyOption, isSelected: Bool) -> some View {
        if let logo = option.brandLogo {
            BrandLogoShape(logo: logo)
                .fill(logo.defaultColor.opacity(isSelected ? 1.0 : 0.5), style: logo.fillRule)
                .frame(width: 12, height: 12)
                .clipped()
        } else {
            Image(systemName: option.systemImage)
                .font(.system(size: 10, weight: .semibold))
        }
    }

    /// 选中:小圆角矩形 + 底部 accent 指示条(与 `CompanionTabBar.tabBackground` 风格对齐)。
    /// 外层托盘圆角 10 / 内层 segment 圆角 6 / 段间 2pt:嵌套避双层圆角叠加成椭圆。
    @ViewBuilder
    private func segmentBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: ChatCardTheme.bubbleRadius - 4, style: .continuous)
                .fill(ChatCardTheme.cardBackground)
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(ChatCardTheme.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                }
        } else {
            Color.clear
        }
    }
}
