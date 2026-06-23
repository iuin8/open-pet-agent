import AgentSensing
import SwiftUI

/// 对话卡片顶层 view：玻璃分层卡 + **顶部 tab bar** + 按选中 tab 切内容 + 底部 composer。
///
/// P3.1 把卡片改成「tab 壳」：顶部三段 tab bar（Pet Chat / Claude Code / Codex），
/// 默认选中 Pet Chat。现有聊天 UI 整块抽进 `PetChatTabContent`（行为/布局零变化）；
/// Claude Code / Codex tab 走 `AgentSessionTabView`（P3.2 渲染感知到的外部会话流）。
/// tab 切换只切内容区，卡片的**锚定/tail/尺寸/进场动画在 `ChatCardView` 层，不随 tab 变**。
///
/// 进场按 `state.entranceEdge`（锚定结果）从贴 pet 的那条边 spring 放大 → "从 pet 旁弹出"。
/// 卡片**固定尺寸**（窗口侧定，`ChatCardTheme.cardWidth×cardHeight`），多轮历史靠内部
/// ScrollView 滚动 —— 绕开 `NSHostingView(sizingOptions=[])` 的动态高坑（lessons-learned §3.2）。
struct ChatCardView: View {
    @ObservedObject var state: ChatCardState
    /// 外部会话流 store（Claude Code / Codex tab 渲染源；Pet Chat tab 不读它）。
    @ObservedObject var sessionStore: AgentSessionStore
    let onSend: (String) -> Void
    let onClose: () -> Void
    var onTogglePin: () -> Void = {}

    var body: some View {
        let shape = ChatCardShape(
            tailSide: state.tailSide,
            tailPercent: state.tailPercent,
            cornerRadius: ChatCardTheme.cardRadius,
            tailHeight: ChatCardTheme.tailHeight
        )
        VStack(spacing: 0) {
            CompanionTabBar(selectedTab: $state.selectedTab, onClose: onClose, badgeFor: tabBadge,
                            isPinned: state.isPinned, onTogglePin: onTogglePin)
            tabContent
        }
        .padding(tailEdgeInsets)   // 给尖角让出空间（仅 tail 那一侧 tailHeight），窗口尺寸不变
        .frame(width: ChatCardTheme.cardWidth, height: ChatCardTheme.cardHeight)
        .background(cardBackground.clipShape(shape))
        .overlay(shape.stroke(ChatCardTheme.accent.opacity(0.22), lineWidth: 0.5))
        .background(escButton)
        // 进场：贴 pet 那条边缩放放大（controller 驱动 state.isShown，每次 show 重播 spring）。
        .scaleEffect(state.isShown ? 1 : 0.9, anchor: entranceAnchor)
        .opacity(state.isShown ? 1 : 0)
    }

    /// tab 红点:Pet Chat 恒 none;Claude Code / Codex 按 store 的外部会话活动状态。
    private func tabBadge(_ tab: CompanionTab) -> TabBadge {
        switch tab {
        case .petChat:    return .none
        case .claudeCode: return sessionStore.tabBadge(for: .claudeCode)
        case .codex:      return sessionStore.tabBadge(for: .codex)
        }
    }

    // MARK: - 按选中 tab 切内容

    @ViewBuilder
    private var tabContent: some View {
        switch state.selectedTab {
        case .petChat:
            PetChatTabContent(state: state, onSend: onSend)
        case .claudeCode:
            AgentSessionTabView(store: sessionStore, agent: .claudeCode)
        case .codex:
            AgentSessionTabView(store: sessionStore, agent: .codex)
        }
    }

    /// 尖角所在那一侧留出 tailHeight 内边距，避免内容压到尖角带。
    private var tailEdgeInsets: EdgeInsets {
        let t = ChatCardTheme.tailHeight
        switch state.tailSide {
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: t, trailing: 0)
        case .top:    return EdgeInsets(top: t, leading: 0, bottom: 0, trailing: 0)
        case .left:   return EdgeInsets(top: 0, leading: t, bottom: 0, trailing: 0)
        case .right:  return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: t)
        case .none:   return EdgeInsets()
        }
    }

    // MARK: - 背景（白底 + 玻璃 + 顶部 accent glow）

    private var cardBackground: some View {
        ZStack {
            ChatCardTheme.cardBackground
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [ChatCardTheme.accent.opacity(0.08), .clear],
                startPoint: .top, endPoint: .center
            )
        }
    }

    /// 隐形 Esc 关闭按钮（与 QuickAskView 同手法）。
    private var escButton: some View {
        Button("") { onClose() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
    }

    /// 进场缩放锚点 = 贴 pet 的那条边（above→底边、below→顶边、left→右边、right→左边）。
    private var entranceAnchor: UnitPoint {
        switch state.entranceEdge {
        case .above: return .bottom
        case .below: return .top
        case .left:  return .trailing
        case .right: return .leading
        }
    }
}
