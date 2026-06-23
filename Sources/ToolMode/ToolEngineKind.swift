import Foundation

/// OpenPetAgent **工具层** 支持的 engine 类型。每个 engine 是一种"让 pet 真干活"
/// 的子进程实现 —— 跟灵魂层(HTTP LLM via OpenAI/Anthropic)正交。
///
/// MVP 只声明 case,具体 engine 实现 (ClaudeCodeEngine / CodexEngine /
/// OpenCodeEngine) 留 N2.1+ 真接 subprocess 时再补。
public enum ToolEngineKind: String, Sendable, CaseIterable {
    /// `claude -p` 子进程 —— 本地读写文件 + 跑命令
    case claudeCode
    /// `codex exec -i` 子进程 —— 本地写代码 + 原生视觉
    case codex
    /// bundled opencode headless server —— DMG 内嵌, 用户无需装 CLI
    case openCode

    /// 显示名(设置面板下拉用)
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .openCode:   return "opencode"
        }
    }

    /// UserDefaults 持久化用 key
    public static let userDefaultsKey: String = "tool.engine.kind"
}
