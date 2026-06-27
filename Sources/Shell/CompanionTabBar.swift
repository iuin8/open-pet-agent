import SwiftUI

/// 卡片顶部 tab bar：三段 tab（Pet Chat / Claude Code / Codex）+ 尾部关闭按钮。
///
/// 视觉走 `ChatCardTheme`/`ChatBubbleTheme` token（不硬编码）：
/// - 选中 tab：白底 + accent 橙强调（文字 + 底部 accent 指示条），红点位预留（`TabBadge`，P3.1 暂全 `.none`）。
/// - 未选中 tab：muted 深靛灰字，透明底。
/// 关闭按钮沿用旧 header 的 `xmark`，保证现有「点 × 关卡」行为不丢。
struct CompanionTabBar: View {
    @Binding var selectedTab: CompanionTab
    let onClose: () -> Void
    /// 每个 tab 的活动徽标(红点)provider。调用方按外部会话状态返回;缺省全 `.none`。
    var badgeFor: (CompanionTab) -> TabBadge = { _ in .none }
    /// #3 主卡钉住态 + 切换。默认钉住(常驻浮顶);取消 → 可被其他 app 盖住。
    var isPinned: Bool = true
    var onTogglePin: () -> Void = {}
    /// 「清空对话」动作。**仅 Pet Chat tab + 有消息时**由调用方传入(否则 nil → 不显示按钮);
    /// 清空只对 pet 对话有意义,Claude/Codex tab 是只读外部会话故不显示。
    var onClearConversation: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CompanionTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 4)
            if let onClearConversation { clearButton(onClearConversation) }   // 仅 Pet Chat 有消息时
            CardPinButton(isPinned: isPinned, onToggle: onTogglePin)   // #3:钉住开关(close 左侧)
            closeButton
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            // tab bar 与内容的分隔细线（hairline token，隐约不抢戏）。
            Rectangle()
                .fill(ChatCardTheme.hairline)
                .frame(height: 0.5)
                .padding(.horizontal, 10)
        }
    }

    // MARK: - 单个 tab 按钮

    private func tabButton(_ tab: CompanionTab) -> some View {
        let isSelected = (tab == selectedTab)
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Text(tab.displayName)
                    .font(ChatCardTheme.chip)
                    .foregroundStyle(
                        isSelected
                            ? ChatCardTheme.accent
                            : ChatCardTheme.textPrimary.opacity(0.4)
                    )
                badgeDot(for: tab)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tabBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.displayName)
    }

    /// 选中态白底圆角；未选中透明。
    @ViewBuilder
    private func tabBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: ChatCardTheme.bubbleRadius - 4, style: .continuous)
                .fill(ChatCardTheme.cardBackground)
                .overlay(alignment: .bottom) {
                    // 选中指示：底部 accent 橙细条。
                    RoundedRectangle(cornerRadius: 1)
                        .fill(ChatCardTheme.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                }
        } else {
            Color.clear
        }
    }

    /// 红点位：P3.1 暂以 `TabBadge` 占位驱动，全 `.none` 不显示。后续任务接外部会话状态。
    @ViewBuilder
    private func badgeDot(for tab: CompanionTab) -> some View {
        switch badge(for: tab) {
        case .none:
            EmptyView()
        case .active:
            Circle().fill(ChatCardTheme.accent).frame(width: 5, height: 5)
        case .awaiting:
            Circle()
                .fill(ChatCardTheme.accent)
                .frame(width: 5, height: 5)
                .overlay(Circle().stroke(ChatCardTheme.accent.opacity(0.3), lineWidth: 2))
        }
    }

    /// 当前 tab 的徽标状态（由调用方注入的 `badgeFor` 按外部会话状态决定）。
    private func badge(for tab: CompanionTab) -> TabBadge { badgeFor(tab) }

    // MARK: - 清空对话按钮（仅 Pet Chat tab + 有消息时显示；destructive 由 app 层确认弹窗兜）

    private func clearButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.4))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("清空对话")
    }

    // MARK: - 关闭按钮（沿用旧 header 的 xmark）

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.4))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("关闭")
    }
}

/// 主陪伴卡片 header 的「钉住」小图标按钮(#3)。钉住 = 常驻浮顶、点别处不自动关;再点取消。
/// (原 `SideCardPinButton`,侧卡机制删除后随主卡保留并改名。)
struct CardPinButton: View {
    let isPinned: Bool
    let onToggle: () -> Void
    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isPinned ? ChatCardTheme.accent : ChatCardTheme.textPrimary.opacity(0.35))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPinned ? "已钉住(点别处不自动关;再点取消)" : "钉住(不自动关,可被其他窗口挡)")
    }
}
