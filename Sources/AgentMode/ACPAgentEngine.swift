import Foundation

// ACPAgentEngine:把 ACP client 包成 `AgentEngine`(class,connection 复用)。
//
// 一套 ACP 协议接任意 ACP 兼容 agent(opencode/gemini/...),取代 per-CLI stdout parser。
// transport 可注入(测试 mock / 生产 `ACPStdioTransport` spawn 子进程)。
//
// **生产级:connection 复用**(Tool Mode ON 期间一个 agent 子进程常驻):
// - 首次 run:spawn + initialize(协议协商)~2-3s 冷启动一次。
// - 后续 run:复用 connection,仅 createSession + prompt(~100ms)。
// - 错误(connection 断/agent 崩)→ 清 client,下次 run 重建(免用坏连接)。
// - engine 释放(router 换 engine / Tool Mode OFF)→ deinit shutdown 子进程。
//
// run(prompt) 流程(ACP v1):ensureConnected → createSession → prompt → 流式收
// agent_message_chunk → yield text delta → finish。不 shutdown(保活)。

/// ACP 专属错误(归一到 `AgentEngineError`,对齐既有 engine)。
public enum ACPAgentEngineError: Error, Equatable {
    case notConnected
    case client(String)
}

/// 用 ACP 协议驱动外部 agent 子进程的 `AgentEngine`(class,connection 复用)。
public final class ACPAgentEngine: AgentEngine, @unchecked Sendable {
    public static let kind: AgentEngineKind = .openCode

    /// agent 启动命令,如 ["opencode", "acp"]。
    public let command: [String]
    /// 可注入 binary 路径(nil = `CLIAvailability.locate`)。
    public let binaryPath: String?
    /// session 工作目录(nil = 进程 cwd)。
    public let cwd: URL?
    /// transport 工厂(测试注入 mock;生产 `ACPStdioTransport`)。
    public let transportFactory: @Sendable () -> any ACPTransport

    /// 权限请求回调(ACP-2:App 注入显示 PermissionCard;nil → client 安全默认 reject_once)。
    public var onPermissionRequest: (@Sendable (ACPPermissionRequest) async -> ACPPermissionOutcome)?

    /// 思考流回调(ACP-2 thought UI:`agent_thought_chunk` → App 显示「思考中」状态;nil → 忽略)。
    /// @Sendable 同步(prompt callback 内直接调,非 async);App 注入闭包内 `Task { @MainActor }` hop。
    public var onThought: (@Sendable (String) -> Void)?

    /// 复用的 client(首次 run 建,后续复用)。lock 保护(防并发首次建两次)。
    private var client: ACPClient?
    private let lock = NSLock()

    public init(
        command: [String] = ["opencode", "acp"],
        binaryPath: String? = nil,
        cwd: URL? = nil,
        transportFactory: @escaping @Sendable () -> any ACPTransport = {
            ACPStdioTransport(command: ["opencode", "acp"])
        }
    ) {
        self.command = command
        self.binaryPath = binaryPath
        self.cwd = cwd
        self.transportFactory = transportFactory
    }

    public var isAvailable: Bool {
        get async {
            if let binaryPath {
                return FileManager.default.isExecutableFile(atPath: binaryPath)
            }
            let cli = CLIAvailability()
            return await cli.locate(binary: command[0]) != nil
        }
    }

    /// 懒建 + 复用 client:首次 spawn + initialize;后续直接返回已连接 client。
    /// 并发首次:第二个丢弃并 shutdown(保留先建者)。
    private func ensureConnected() async throws -> ACPClient {
        lock.lock(); let existing = client; lock.unlock()
        if let existing { return existing }

        let new = ACPClient(transport: transportFactory())
        await new.setOnPermissionRequest(onPermissionRequest)   // 透传权限回调(ACP-2)
        _ = try await new.connect()   // initialize(协议协商,~2-3s 冷启动)

        lock.lock()
        if let existing = client {
            // 并发首次:已有,丢弃新建
            lock.unlock()
            Task { await new.shutdown() }
            return existing
        }
        client = new
        lock.unlock()
        return new
    }

    public func run(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let c = try await ensureConnected()
                    let cwdPath = cwd?.path ?? FileManager.default.currentDirectoryPath
                    let sid = try await c.createSession(cwd: cwdPath, mcpServers: [])
                    await c.setSessionId(sid)

                    let onThoughtHandler = onThought   // 捕获当前值(Sendable closure,run 时快照)
                    let stop = try await c.prompt(text: prompt) { update in
                        // agent_message_chunk → yield text delta(最终回复)
                        // agent_thought_chunk → onThought 回调(思考流 → App「思考中」状态;不 yield 免碎片)
                        if update.sessionUpdate == .agentMessageChunk,
                           let text = update.textContent, !text.isEmpty {
                            continuation.yield(text)
                        } else if update.sessionUpdate == .agentThoughtChunk,
                                  let text = update.textContent, !text.isEmpty {
                            onThoughtHandler?(text)
                        }
                    }
                    _ = stop   // ACP-2 按类型做 pet 反应
                    continuation.finish()
                } catch {
                    // 连接断/agent 崩 → 清 client,下次 run 重建(免用坏连接)
                    lock.lock(); let bad = client; client = nil; lock.unlock()
                    Task { await bad?.shutdown() }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                // 不 shutdown transport —— 保活 connection 供下次 run 复用。
                // prompt 的 cancel 响应在 ACPClient 层(withTaskCancellationHandler)。
            }
        }
    }

    deinit {
        // engine 释放(router 换 engine / Tool Mode OFF)→ shutdown 子进程,免孤儿。
        if let client {
            Task { await client.shutdown() }
        }
    }
}
