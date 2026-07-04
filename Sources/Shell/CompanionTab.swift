import Foundation

/// 聊天卡片顶部 tab bar 的三个分页标识。
///
/// - `petChat`：现有桌宠聊天（默认选中），UI 整块抽进 `PetChatTabContent`，行为零变化。
/// - `claudeCode` / `codex`：感知到的外部 CLI 会话视图，当前为占位（「(无活跃会话)」），
///   后续任务（AgentSensing 接线）填充。
///
/// `allCases` 顺序即 tab bar 从左到右的展示顺序：Pet Chat → Claude Code → Codex。
///
/// 图标渲染：`brandLogo` 优先（claudeCode/codex 用真品牌 SVG path,来自 cc-switch MIT 提取）;
/// `petChat` 无品牌 logo → 走 `systemImage` SF Symbol(`pawprint.fill`)。
public enum CompanionTab: CaseIterable, Sendable {
    case petChat
    case claudeCode
    case codex

    /// tab 短标签(图标为主,文字仅作辅助标识)。简体中文产品惯例。
    /// 去掉 emoji 前缀 —— 图标(`brandLogo`/`systemImage`)已代表,文字只留短名,
    /// 配合 `CompanionTabBar` 的 `fixedSize` 防换行(参考 cc-switch AppSwitcher
    /// 「图标+短文字+whitespace-nowrap」设计)。
    public var displayName: String {
        switch self {
        case .petChat:    return "Pet"
        case .claudeCode: return "Claude"
        case .codex:      return "Codex"
        }
    }

    /// tab tooltip(详细说明,hover 显示)。保留「会话」语义区分(感知外部 CLI vs 对话 engine)。
    public var helpText: String {
        switch self {
        case .petChat:    return "Pet Chat · 双向对话(灵魂层 / Agent engine)"
        case .claudeCode: return "感知外部 Claude Code 会话(只读监控)"
        case .codex:      return "感知外部 Codex 会话(只读监控)"
        }
    }

    /// SF Symbol 名(petChat 用;claudeCode/codex 作 `brandLogo` 不可用时的 fallback)。
    public var systemImage: String {
        switch self {
        case .petChat:    return "pawprint.fill"
        case .claudeCode: return "bolt.fill"
        case .codex:      return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// 品牌 logo(claudeCode/codex 用真品牌 SVG path 渲染;petChat 返回 nil 走 SF Symbol)。
    /// logo path data 来自 cc-switch(MIT)提取的品牌 SVG,经 `SVGPathParser` 转 SwiftUI Path。
    public var brandLogo: BrandLogo? {
        switch self {
        case .petChat:    return nil
        case .claudeCode: return .claude
        case .codex:      return .codex
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
