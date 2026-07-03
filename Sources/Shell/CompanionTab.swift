import Foundation

/// 聊天卡片顶部 tab bar 的三个分页标识。
///
/// - `petChat`：现有桌宠聊天（默认选中），UI 整块抽进 `PetChatTabContent`，行为零变化。
/// - `claudeCode` / `codex`：感知到的外部 CLI 会话视图，当前为占位（「(无活跃会话)」），
///   后续任务（AgentSensing 接线）填充。
///
/// `allCases` 顺序即 tab bar 从左到右的展示顺序：Pet Chat → Claude Code → Codex。
public enum CompanionTab: CaseIterable, Sendable {
    case petChat
    case claudeCode
    case codex

    /// tab 标题(含前缀 emoji,与 mockup 一致)。简体中文/产品惯例。
    /// 📡 + 「会话」标注 = 感知外部 CLI 会话(只读),区别于聊天面板 Composer 的 ⚡ 对话 engine
    /// (🐾 Pet Chat = 双向对话;📡 Claude/Codex 会话 = 监控外部 CLI 会话流)。
    public var displayName: String {
        switch self {
        case .petChat:    return "🐾 Pet Chat"
        case .claudeCode: return "📡 Claude 会话"
        case .codex:      return "📡 Codex 会话"
        }
    }

    /// tab tooltip(详细说明,hover 显示)。
    public var helpText: String {
        switch self {
        case .petChat:    return "Pet Chat · 双向对话(灵魂层 / Agent engine)"
        case .claudeCode: return "感知外部 Claude Code 会话(只读监控)"
        case .codex:      return "感知外部 Codex 会话(只读监控)"
        }
    }

    /// SF Symbol 名，给只显示图标的紧凑布局/无障碍用。
    public var systemImage: String {
        switch self {
        case .petChat:    return "pawprint.fill"
        case .claudeCode: return "bolt.fill"
        case .codex:      return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// tab 上的活动状态徽标（红点位）。当前仅 `petChat` 始终 `.none`；
/// `claudeCode` / `codex` 后续按外部会话状态驱动（有活跃会话→`.active`，待输入→`.awaiting`）。
public enum TabBadge: Sendable, Equatable {
    /// 无徽标。
    case none
    /// 有活跃会话（红点）。
    case active
    /// 等待用户/权限响应（强调点）。
    case awaiting
}
