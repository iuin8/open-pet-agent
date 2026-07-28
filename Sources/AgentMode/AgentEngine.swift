import Foundation

/// 工具 engine 协议。每个 engine 经 ACP 接入(P3 起 Claude Code / Codex / opencode
/// 统一 `ACPAgentEngine` 家族)。
///
/// MVP 接口最小化:仅 streaming run prompt。`StubClaudeCodeEngine` 保留作
/// 路由/编排层测试的 test double。
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

    /// P7.2:带图片附件跑一轮(ACP image content block 管线;`ChatImage`)。
    /// 非 ACP / 不支持图片的 engine 可安全降级忽略图片(见 extension 默认实现)。
    func run(prompt: String, images: [ChatImage]) -> AsyncThrowingStream<String, Error>
}

public extension AgentEngine {
    /// 默认:无图调用转发带空图片数组(P7.2 起新 conformer 只实现带图版即可)。
    func run(prompt: String) -> AsyncThrowingStream<String, Error> {
        run(prompt: prompt, images: [])
    }

    /// 默认:带图调用退化为纯文本(老 conformer 零改动,不炸)。
    /// ⚠️ conformer **必须至少实现两个 `run` 之一**,否则两个默认实现互相转发死循环。
    func run(prompt: String, images: [ChatImage]) -> AsyncThrowingStream<String, Error> {
        run(prompt: prompt)
    }
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
