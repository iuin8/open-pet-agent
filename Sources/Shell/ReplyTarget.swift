import Foundation

/// 对话卡片的「回复来源」—— pet 用什么大脑回复用户。
///
/// 区别于 `CompanionTab`(顶部 tab bar 的**内容视图**:对话 vs 感知外部会话),
/// `ReplyTarget` 是**对话时的回复路径**选择:灵魂层 LLM(自然对话)vs Agent 层
/// engine(让 pet 调 Claude Code/Codex/opencode 干活)。两者正交:
/// - tab bar 选「看哪个视图」(Pet Chat 对话 / Claude Code·Codex 只读感知外部)
/// - replyTarget 选「pet 用什么回复」(灵魂层 / 某个 Agent engine)
///
/// 同名不混(如 tab bar 与回复来源都有「Claude Code」):位置不同(顶栏 vs 输入区)、
/// 语义不同,用户经视觉层级即可区分。
public enum ReplyTarget: Equatable, Hashable, Sendable {
    /// 灵魂层(伴侣 LLM,自然对话)。默认 —— 开箱即用。
    case soul
    /// Agent 层(engine id,对应 `AgentEngineRegistry` entry id)。
    case agent(String)

    /// 便利:是否灵魂层。
    public var isSoul: Bool { self == .soul }
}

/// 回复来源选择器(`ReplySourceBar`)的一个选项。纯展示数据(target + 标签 + 图标),
/// 由 App 从 `AgentEngineRegistry.all` 派生注入(Shell 不依赖 AgentMode,故不在本层构造)。
public struct ReplyOption: Equatable, Hashable, Sendable, Identifiable {
    public let target: ReplyTarget
    /// 紧凑展示名(segmented 上显示,如 "聊天"/"Claude"/"Codex"/"opencode")。
    public let label: String
    /// SF Symbol 图标名(无品牌 logo 时 fallback 用)。
    public let systemImage: String
    /// 品牌 logo(Claude/Codex 等),优先于 `systemImage` 渲染。
    public let brandLogo: BrandLogo?

    public var id: ReplyTarget { target }

    public init(target: ReplyTarget, label: String, systemImage: String, brandLogo: BrandLogo? = nil) {
        self.target = target
        self.label = label
        self.systemImage = systemImage
        self.brandLogo = brandLogo
    }
}
