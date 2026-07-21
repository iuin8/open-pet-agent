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

/// `loadSession` 回放聚合出的一条整消息(user/assistant;chunk 已按 messageId 合并)。
public struct ACPReplayedTurn: Sendable, Equatable {
    public enum Role: Sendable, Equatable { case user, assistant }
    public let role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// 用 ACP 协议驱动外部 agent 子进程的 `AgentEngine`(class,connection 复用)。
/// 非 final + `class var kind`:P3 子类化出 claude/codex 变体(同协议同实现,kind 与默认命令不同)。
public class ACPAgentEngine: AgentEngine, @unchecked Sendable {
    /// engine kind(router 经 `type(of:).kind` 反推)。子类覆盖换 kind(opencode 默认)。
    public class var kind: AgentEngineKind { .openCode }

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

    /// sessionId 变更回调(P2:ensureSession 首建 / loadSession 恢复 / newSession 新建后触发;
    /// App 用来持久化「当前会话指针」)。@Sendable 同步,App 注入闭包内自行 hop。
    public var onSessionIdChanged: (@Sendable (String) -> Void)?

    /// 复用的 client(首次 run 建,后续复用)。lock 保护(防并发首次建两次)。
    private var client: ACPClient?
    /// 复用的 sessionId(首个 run `session/new` 建,后续 run 复用 —— agent 端上下文连贯;
    /// 与 client 同生命周期,出错时一起清)。
    private var cachedSessionId: String?
    /// 首次 initialize 协商出的能力(与 client 同生命周期),供 provider 按能力过滤 MCP server。
    private var clientCapabilities: ACPAgentCapabilities?
    private let lock = NSLock()

    /// 当前复用的 sessionId(只读;nil = 尚未建)。P2 会话恢复后也有值。
    public var currentSessionId: String? {
        lock.lock(); defer { lock.unlock() }; return cachedSessionId
    }

    /// initialize 协商出的能力(只读;nil = 尚未连接)。P2 能力门控(loadSession/list)用。
    public var agentCapabilities: ACPAgentCapabilities? {
        lock.lock(); defer { lock.unlock() }; return clientCapabilities
    }

    public init(
        command: [String] = ["opencode", "acp"],
        binaryPath: String? = nil,
        cwd: URL? = nil,
        mcpServersProvider: @escaping @Sendable (ACPAgentCapabilities) -> [ACPJSON] = { _ in [] },
        transportFactory: (@Sendable () -> any ACPTransport)? = nil
    ) {
        self.command = command
        self.binaryPath = binaryPath
        self.cwd = cwd
        self.mcpServersProvider = mcpServersProvider
        // 默认 transport 跟随 command(P3 子类安全:claude/codex 变体不传 factory 也不会
        // 错 spawn opencode);测试注入 mock / 生产注入带 env+cwd 的 factory 时覆盖。
        self.transportFactory = transportFactory ?? { ACPStdioTransport(command: command) }
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
        onSessionIdChanged?(sid)   // P2:首建也通知(App 持久化指针)
        return sid
    }

    // MARK: - 会话管理(P2:list / load / new)

    /// 连接就绪 + 返回协商能力(P2 能力门控:loadSession/list 探测)。冷启动首调 ~2-3s。
    public func ensureReady() async throws -> ACPAgentCapabilities {
        try await ensureConnected().1
    }

    /// 列出 agent 侧持久会话(当前 cwd,按 agent 返回顺序,opencode 为最近优先)。
    /// 跟随 nextCursor 翻页,上限 5 页防失控。能力缺失(agent 不支持 list)错误自然抛上。
    public func listSessions() async throws -> [ACPSessionInfo] {
        let (c, _) = try await ensureConnected()
        let cwdPath = cwd?.path ?? FileManager.default.currentDirectoryPath
        var all: [ACPSessionInfo] = []
        var cursor: String? = nil
        for _ in 0..<5 {
            let page = try await c.listSessions(cwd: cwdPath, cursor: cursor)
            all.append(contentsOf: page.sessions)
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return all
    }

    /// 载入已有 session 并回放历史(P2 跨重启/切换恢复):
    /// agent 回放全部历史为 session/update → 聚合成按序的 user/assistant 整消息返回
    /// (UI 重填消息列表);回放中的 usage_update 走 onUsage(同 run)。成功后置为当前 session。
    /// 失败(session 已被 agent 侧清掉等)抛错,client/当前 session 不动 —— 调用方决定回退。
    public func loadSession(_ sid: String) async throws -> [ACPReplayedTurn] {
        let (c, caps) = try await ensureConnected()
        let cwdPath = cwd?.path ?? FileManager.default.currentDirectoryPath
        let onUsageHandler = onUsage
        var turns: [ACPReplayedTurn] = []
        var indexByMessageId: [String: Int] = [:]
        try await c.loadSession(sessionId: sid, cwd: cwdPath, mcpServers: mcpServersProvider(caps)) { update in
            // 回放按 messageId 聚合 chunk(同一消息的多 chunk 追加合并);usage 直传。
            if update.sessionUpdate == .usageUpdate, let usage = update.usage {
                onUsageHandler?(usage)
                return
            }
            let role: ACPReplayedTurn.Role?
            switch update.sessionUpdate {
            case .userMessageChunk: role = .user
            case .agentMessageChunk: role = .assistant
            default: role = nil
            }
            guard let role, let text = update.textContent, !text.isEmpty else { return }
            if let mid = update.messageId {
                if let idx = indexByMessageId[mid] {
                    turns[idx].text += text
                } else {
                    indexByMessageId[mid] = turns.count
                    turns.append(ACPReplayedTurn(role: role, text: text))
                }
            } else {
                turns.append(ACPReplayedTurn(role: role, text: text))
            }
        }
        await c.setSessionId(sid)
        lock.lock(); cachedSessionId = sid; lock.unlock()
        onSessionIdChanged?(sid)
        return turns
    }

    /// 显式开新会话(P2「新会话」入口):立即 session/new 并置为当前,返回新 id。
    /// 立即建(而非等下个 run 懒建)让持久化指针立刻可存、列表立刻可见。
    public func newSession() async throws -> String {
        let (c, caps) = try await ensureConnected()
        let cwdPath = cwd?.path ?? FileManager.default.currentDirectoryPath
        let sid = try await c.createSession(cwd: cwdPath, mcpServers: mcpServersProvider(caps))
        await c.setSessionId(sid)
        lock.lock(); cachedSessionId = sid; lock.unlock()
        onSessionIdChanged?(sid)
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
                            sawUsage.mark(usage)
                            onUsageHandler?(usage)
                        }
                    }
                    // fallback + 明细(ACP-3):usage_update 未达(opencode 1.18)→ 合成
                    // used = input + cache.read(同 opencode usage_update.used 公式);
                    // 已达(claude/codex 推 usage_update)→ used/size/cost 不变,仅补 prompt 明细
                    // (tooltip)。两路幂等(wiring 同值覆写),不重复计数。
                    if let promptUsage = result.usage {
                        if let exact = sawUsage.lastUsage {
                            onUsageHandler?(ACPUsage(
                                used: exact.used, size: exact.size, cost: exact.cost, prompt: promptUsage))
                        } else {
                            onUsageHandler?(ACPUsage(
                                used: promptUsage.contextUsed, size: nil, cost: nil, prompt: promptUsage))
                        }
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

/// run 的 prompt 回调(@Sendable)与主体间共享的「本轮 usage」状态(NSLock 护;
/// box 绕 @Sendable 闭包捕获 var 的限制)。
private final class ACPUsageArrivalFlag: @unchecked Sendable {
    private var last: ACPUsage?
    private let lock = NSLock()
    func mark(_ usage: ACPUsage) { lock.lock(); last = usage; lock.unlock() }
    /// 本轮最近一次 usage_update(精确 used/size/cost;nil = 未收到)。
    var lastUsage: ACPUsage? { lock.lock(); defer { lock.unlock() }; return last }
}
