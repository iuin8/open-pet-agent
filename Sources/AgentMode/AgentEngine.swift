import Foundation

/// 工具 engine 协议。每个 engine (Claude Code / Codex / opencode) conform 之。
///
/// MVP 接口最小化:仅 streaming run prompt,真 subprocess 接入 N2.1+ 在
/// 具体 conformance 里做。当前阶段(N2.0)只有 `StubClaudeCodeEngine`
/// 占位实现,用于打通灵魂层 → 工具层的路由架构。
public protocol AgentEngine: Sendable {
    /// 该 engine 的标识。
    static var kind: AgentEngineKind { get }

    /// engine 是否当前可用(CLI 已安装、版本兼容、PATH 找得到)。
    /// 由 `CLIAvailability` 探测后决定。stub 实现可直接返回 true。
    var isAvailable: Bool { get async }

    /// 用 prompt 跑一轮 task,返回流式 delta token。
    ///
    /// MVP stub 实现:yield 一条"工具引擎尚未接入"文案 + finish。
    /// 真实 engine 实现会 spawn subprocess,把 stdout 按行 yield 出去。
    func run(prompt: String) -> AsyncThrowingStream<String, Error>
}

/// 工具 engine 调用失败的错误类型。
public enum AgentEngineError: Error, Sendable, Equatable {
    /// CLI 未安装(PATH 找不到 binary)
    case cliNotInstalled(AgentEngineKind)
    /// 子进程异常退出
    case subprocessFailed(exitCode: Int32, stderr: String)
    /// 当前还没真实现这个 engine(N2.0 stub 阶段:router 无 engine 时返回此)
    case notImplemented(AgentEngineKind)
    /// 子进程超时未收尾(读流卡死兜底:watchdog 到点 SIGTERM 子进程 + finish)。
    /// 防 EOF/stream 竞态让 `for try await` 永久挂住（2026-06-04 修）。
    case timedOut(AgentEngineKind)
}
