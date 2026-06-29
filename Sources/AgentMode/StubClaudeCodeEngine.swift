import Foundation

/// `AgentEngine` 的 N2.0 占位实现 —— 不真 spawn `claude -p` 子进程,
/// 只 yield 一条"未接入"提示让上层链路通。N2.1 起会被真实
/// `ClaudeCodeEngine` 替换(同名或换名都行,关键是 conformance)。
///
/// 用途:让 `AgentModeRouter` / 设置 UI / 测试都能"假装有工具引擎",
/// 验证灵魂层 → 工具层路由架构,而无需真 spawn 子进程。
public struct StubClaudeCodeEngine: AgentEngine {
    public static let kind: AgentEngineKind = .claudeCode

    public var isAvailable: Bool { get async { true } }  // stub 永远可用

    public init() {}

    public func run(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("⚙️ **Claude Code 工具未接入** —— 当前是 N2.0 占位实现。")
            let preview = String(prompt.prefix(100))
            continuation.yield("\n\n收到 prompt: `\(preview)...`")
            continuation.finish()
        }
    }
}
