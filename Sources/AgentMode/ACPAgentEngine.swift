import Foundation

// ACPAgentEngine:把 ACP client 包成 `AgentEngine`(class,connection 复用)。
//
// 一套 ACP 协议接任意 ACP 兼容 agent(opencode/gemini/...),取代 per-CLI stdout parser。
// transport 可注入(测试 mock / 生产 `ACPStdioTransport` spawn 子进程)。
//
// **生产级:connection + session 复用**(Tool Mode ON 期间一个 agent 子进程常驻):
// - 首次 run:spawn + initialize(协议协商)~2-3s 冷启动 + session/new 一次。
// - 后续 run:复用 connection + 同一 sessionId,仅 prompt(~100ms),agent 端上下文连贯。
// - 错误(connection 断/agent 崩)→ 清 client + 缓存 sessionId,下次 run 重建连接并开新 session。
// - engine 释放(router 换 engine / Tool Mode OFF)→ deinit shutdown 子进程。
//
// run(prompt) 流程(ACP v1):ensureConnected → ensureSession(首 run session/new,后续复用)→
// prompt → 流式收 agent_message_chunk → yield text delta → finish。不 shutdown(保活)。

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
    /// 每轮 ACP session/new 携带的 MCP server 列表（入参 = initialize 协商出的能力,
    /// 供按 `mcpCapabilities` 过滤 http/sse server）。默认空,保持旧调用方行为。
    private let mcpServersProvider: @Sendable (ACPAgentCapabilities) -> [ACPJSON]
    /// transport 工厂(测试注入 mock;生产 `ACPStdioTransport`)。
    public let transportFactory: @Sendable () -> any ACPTransport

    /// 权限请求回调(ACP-2:App 注入显示 PermissionCard;nil → client 安全默认 reject_once)。
    public var onPermissionRequest: (@Sendable (ACPPermissionRequest) async -> ACPPermissionOutcome)?

    /// 思考流回调(ACP-2 thought UI:`agent_thought_chunk` → App 显示「思考中」状态;nil → 忽略)。
    /// @Sendable 同步(prompt callback 内直接调,非 async);App 注入闭包内 `Task { @MainActor }` hop。
    public var onThought: (@Sendable (String) -> Void)?

    /// 用量回调(ACP-3:`usage_update` → App 显示上下文占用条;nil → 忽略)。
    /// 同 onThought:@Sendable 同步,App 注入闭包内 `Task { @MainActor }` hop 回主 actor。
    /// 本轮未收 usage_update 但 PromptResponse 带 unstable usage 时合成 fallback(opencode 1.18 路径)。
    public var onUsage: (@Sendable (ACPUsage) -> Void)?

    /// 复用的 client(首次 run 建,后续复用)。lock 保护(防并发首次建两次)。
    private var client: ACPClient?
    /// 复用的 sessionId(首个 run `session/new` 建,后续 run 复用 —— agent 端上下文连贯;
    /// 与 client 同生命周期,出错时一起清)。
    private var cachedSessionId: String?
    /// 首次 initialize 协商出的能力(与 client 同生命周期),供 provider 按能力过滤 MCP server。
    private var clientCapabilities: ACPAgentCapabilities?
    private let lock = NSLock()

    public init(
        command: [String] = ["opencode", "acp"],
        binaryPath: String? = nil,
        cwd: URL? = nil,
        mcpServersProvider: @escaping @Sendable (ACPAgentCapabilities) -> [ACPJSON] = { _ in [] },
        transportFactory: @escaping @Sendable () -> any ACPTransport = {
            ACPStdioTransport(command: ["opencode", "acp"])
        }
    ) {
        self.command = command
        self.binaryPath = binaryPath
        self.cwd = cwd
        self.mcpServersProvider = mcpServersProvider
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

    /// 懒建 + 复用 client:首次 spawn + initialize;后续直接返回已连接 client 与协商能力。
    /// 并发首次:第二个丢弃并 shutdown(保留先建者)。
    private func ensureConnected() async throws -> (ACPClient, ACPAgentCapabilities) {
        lock.lock(); let existing = client; let existingCaps = clientCapabilities; lock.unlock()
        if let existing, let existingCaps { return (existing, existingCaps) }

        let new = ACPClient(transport: transportFactory())
        await new.setOnPermissionRequest(onPermissionRequest)   // 透传权限回调(ACP-2)
        let caps = try await new.connect()   // initialize(协议协商,~2-3s 冷启动)

        lock.lock()
        if let existing = client, let existingCaps = clientCapabilities {
            // 并发首次:已有,丢弃新建
            lock.unlock()
            Task { await new.shutdown() }
            return (existing, existingCaps)
        }
        client = new
        clientCapabilities = caps
        lock.unlock()
        return (new, caps)
    }

    /// 懒建 + 复用 ACP session:首个 run `session/new`,后续 run 复用同一 sessionId
    /// (agent 端上下文连贯,不再每轮零上下文)。出错 reset 时随 client 一起清。
    /// 并发首个:第二个丢弃新建 session 用先建者(run 由 UI `isSending` 串行化,此为防御)。
    private func ensureSession(client c: ACPClient, caps: ACPAgentCapabilities) async throws -> String {
        lock.lock(); let existing = cachedSessionId; lock.unlock()
        if let existing { return existing }

        let cwdPath = cwd?.path ?? FileManager.default.currentDirectoryPath
        let sid = try await c.createSession(cwd: cwdPath, mcpServers: mcpServersProvider(caps))

        lock.lock()
        if let existing = cachedSessionId {
            // 并发首个:已有,丢弃新建(session 留在 agent 侧,随下个 full reset 清)
            lock.unlock()
            return existing
        }
        cachedSessionId = sid
        lock.unlock()
        return sid
    }

    public func run(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (c, caps) = try await ensureConnected()
                    let sid = try await ensureSession(client: c, caps: caps)
                    await c.setSessionId(sid)

                    let onThoughtHandler = onThought   // 捕获当前值(Sendable closure,run 时快照)
                    let onUsageHandler = onUsage       // 同上
                    let sawUsage = ACPUsageArrivalFlag()
                    let result = try await c.prompt(text: prompt) { update in
                        // agent_message_chunk → yield text delta(最终回复)
                        // agent_thought_chunk → onThought 回调(思考流 → App「思考中」状态;不 yield 免碎片)
                        // usage_update → onUsage 回调(上下文占用 → App 占用条;不 yield)
                        if update.sessionUpdate == .agentMessageChunk,
                           let text = update.textContent, !text.isEmpty {
                            continuation.yield(text)
                        } else if update.sessionUpdate == .agentThoughtChunk,
                                  let text = update.textContent, !text.isEmpty {
                            onThoughtHandler?(text)
                        } else if update.sessionUpdate == .usageUpdate,
                                  let usage = update.usage {
                            sawUsage.mark()
                            onUsageHandler?(usage)
                        }
                    }
                    // fallback(ACP-3):usage_update 未达但响应带 unstable usage(opencode 1.18 实测如此)
                    // → 合成 used = input + cache.read(同 opencode usage_update.used 公式);无窗口 size,
                    // UI 自适应猜。已收过 usage_update 则不重复发(精确值优先)。
                    if !sawUsage.value, let promptUsage = result.usage {
                        onUsageHandler?(ACPUsage(used: promptUsage.contextUsed, size: nil, cost: nil))
                    }
                    _ = result.stopReason   // ACP-2 按类型做 pet 反应
                    continuation.finish()
                } catch {
                    // 连接断/agent 崩 → 清 client + 缓存 sessionId,下次 run 重建连接并开新 session
                    lock.lock(); let bad = client; client = nil; cachedSessionId = nil; lock.unlock()
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

/// run 的 prompt 回调(@Sendable)与主体间共享的「本轮已收 usage_update」标志(NSLock 护;
/// box 绕 @Sendable 闭包捕获 var 的限制)。
private final class ACPUsageArrivalFlag: @unchecked Sendable {
    private var saw = false
    private let lock = NSLock()
    func mark() { lock.lock(); saw = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return saw }
}
