import Foundation

/// OpenPetAgent **工具层** engine 的持久化身份 enum —— 跟灵魂层
/// `LLMProviderKind` 同款定位:只承载 rawValue(UserDefaults 存取)+ 协议
/// `static var kind` / `AgentEngineError` 携带 / `AgentModeRouter.currentKind`
/// 用。**展示名 / CLI binary 名 / 能力 / 构造逻辑已迁到 `AgentEngineRegistry`**
/// (id 取代写死 `switch kind`,镜像「形象插件化」),这里不再维护 displayName
/// 等业务分支。
///
/// 跟灵魂层(HTTP LLM via OpenAI/Anthropic)正交。
public enum AgentEngineKind: String, Sendable, CaseIterable {
    /// `claude -p` 子进程 —— 本地读写文件 + 跑命令
    case claudeCode
    /// `codex exec -i` 子进程 —— 本地写代码 + 原生视觉
    case codex
    /// bundled opencode headless server —— DMG 内嵌, 用户无需装 CLI
    case openCode

    /// UserDefaults 持久化用 key。**值保留 legacy `tool.engine.kind`**(类型已从
    /// ToolEngineKind 改名 AgentEngineKind,但 key 串不改 → 老用户设置零迁移)。
    public static let userDefaultsKey: String = "tool.engine.kind"
}
