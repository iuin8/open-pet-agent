import Foundation

/// OpenPetAgent **工具层** engine 的持久化身份 enum —— 跟灵魂层
/// `LLMProviderKind` 同款定位:只承载 rawValue(UserDefaults 存取)+ 协议
/// `static var kind` / `ToolEngineError` 携带 / `ToolModeRouter.currentKind`
/// 用。**展示名 / CLI binary 名 / 能力 / 构造逻辑已迁到 `ToolEngineRegistry`**
/// (id 取代写死 `switch kind`,镜像「形象插件化」),这里不再维护 displayName
/// 等业务分支。
///
/// 跟灵魂层(HTTP LLM via OpenAI/Anthropic)正交。
public enum ToolEngineKind: String, Sendable, CaseIterable {
    /// `claude -p` 子进程 —— 本地读写文件 + 跑命令
    case claudeCode
    /// `codex exec -i` 子进程 —— 本地写代码 + 原生视觉
    case codex
    /// bundled opencode headless server —— DMG 内嵌, 用户无需装 CLI
    case openCode

    /// UserDefaults 持久化用 key
    public static let userDefaultsKey: String = "tool.engine.kind"
}
