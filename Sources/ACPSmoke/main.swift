import Foundation
import Darwin
import AgentMode

// ACP-1a 冒烟:用真 ACPStdioTransport spawn ACP agent 子进程,验证自写 ACP client 真能跟
// agent 互操作。用法:.build/.../ACPSmoke "prompt"
// 默认 `opencode acp`;env `ACP_SMOKE_CMD` 覆盖命令(P3:claude-agent-acp / codex-acp 同款冒烟)。
// 非 opencode 命令时跳过 OPENCODE_CONFIG 与 opencode MCP projection(mcpServers 传空)。
//
// 用 FileHandle.write 直接写(stdout 重定向时 print 跨线程 buffer 不 flush,会丢日志)。

@main
struct ACPSmoke {
    static func main() async {
        let prompt = CommandLine.arguments.dropFirst().first ?? "用一句话说你好"
        // P5:ACP_SMOKE_MODE=pool → @mention 引擎池冒烟(router + 真适配器双引擎);
        // 默认 single = 单引擎 ACP 协议冒烟(原路径)。
        if ProcessInfo.processInfo.environment["ACP_SMOKE_MODE"] == "pool" {
            await poolSmoke(prompt: prompt)
            return
        }
        let command = ProcessInfo.processInfo.environment["ACP_SMOKE_CMD"]
            .map { $0.split(separator: " ").map(String.init) } ?? ["opencode", "acp"]
        let isOpencode = command.first == "opencode"

        // P1d:走 ProjectStore.current()(vs 之前 shell cwd)—— 与 applySelectedAgentEngine 同路径,
        // 真互操作 verify 走 ProjectStore(冒烟工具对齐生产架构)。env 指向选中项目 opencode.json。
        ProjectStore.ensureDefaultProjectRegistered()
        let project = ProjectStore.current()
        let projectRoot = (try? ProjectConfig.ensure(for: project)) ?? project.rootURL
        log("[project] id=\(project.id) root=\(projectRoot.path) cmd=\(command)")

        var env = CLIProcessEnvironment.augmented()
        if isOpencode {
            let opencodeConfigPath = ProjectConfig.opencodeConfig(for: project).path
            env = env.merging(["OPENCODE_CONFIG": opencodeConfigPath]) { _, new in new }
        }
        let real = ACPStdioTransport(
            command: command,
            processEnvironment: env,
            currentDirectoryURL: projectRoot
        )
        let transport: any ACPTransport = LoggingTransport(wrapping: real)
        let client = ACPClient(transport: transport)
        log("[dbg] transport type = \(String(describing: type(of: transport)))")

        log("[connect] initialize…")
        var failed = false
        do {
            let caps = try await client.connect()
            log("[connect] protocolVersion=\(caps.protocolVersion) caps=\(caps.agentCapabilities.sorted())")

            let mcpServers: [ACPJSON]
            if isOpencode {
                mcpServers = ACPMCPServerProjection.supported(
                    try OpencodeProjectAdapter().loadMCPServers(for: project),
                    capabilities: caps.mcpCapabilities
                )
            } else {
                mcpServers = []   // 非 opencode 冒烟不注入项目 MCP(claude/codex 适配器各自生态)
            }
            log("[caps] loadSession=\(caps.loadSession) sessionCaps=\(caps.sessionCapabilities.map(\.rawValue).sorted()) mcpCaps=\(caps.mcpCapabilities.map(\.rawValue).sorted())")
            let sid = try await client.createSession(cwd: projectRoot.path, mcpServers: mcpServers)
            await client.setSessionId(sid)
            log("[session] \(sid)")

            log("[prompt] \(prompt)")
            let result = try await client.prompt(text: prompt) { update in
                log("[update kind=\(String(describing: update.sessionUpdate)) mid=\(update.messageId ?? "nil") text=\(update.textContent ?? "nil") usage=\(String(describing: update.usage))]")
            }
            log("[stop] \(result.stopReason) usage=\(String(describing: result.usage))")

            // ACP-3 冒烟:同 client 同 sessionId 第二轮 prompt(不重发 session/new)——
            // 验证 opencode 接受会话延续并推 usage_update(P1 会话保持的真互操作证据)。
            let followup = "第二轮:我刚才问了你什么?一句话回答"
            log("[prompt2 same-session] \(followup)")
            let result2 = try await client.prompt(text: followup) { update in
                log("[update2 kind=\(String(describing: update.sessionUpdate)) mid=\(update.messageId ?? "nil") text=\(update.textContent ?? "nil") usage=\(String(describing: update.usage))]")
            }
            log("[stop2] \(result2.stopReason) usage=\(String(describing: result2.usage))")

            // P2 冒烟(能力门控):session/list 应含当前会话;session/load 回放全部历史(跨重启恢复语义)。
            if caps.sessionCapabilities.contains(.list) {
                let page = try await client.listSessions(cwd: projectRoot.path, cursor: nil)
                log("[list] \(page.sessions.count) sessions, nextCursor=\(page.nextCursor ?? "nil")")
                for s in page.sessions.prefix(5) {
                    log("[list]   \(s.sessionId) title=\(s.title ?? "nil") updatedAt=\(s.updatedAt ?? "nil")")
                }
            } else {
                log("[list] skipped( agent 未声明 sessionCapabilities.list)")
            }
            if caps.loadSession {
                var replayed = 0
                try await client.loadSession(sessionId: sid, cwd: projectRoot.path, mcpServers: mcpServers) { update in
                    if update.sessionUpdate == .userMessageChunk || update.sessionUpdate == .agentMessageChunk,
                       let t = update.textContent, !t.isEmpty {
                        replayed += 1
                        log("[replay] \(String(describing: update.sessionUpdate)) \(t.prefix(40))")
                    }
                }
                log("[load] replayed message chunks=\(replayed)(应 ≥ 4:两轮 user+assistant)")
            } else {
                log("[load] skipped(agent 未声明 loadSession)")
            }
        } catch {
            log("[err] \(error)")
            failed = true
        }
        await client.shutdown()
        if failed { Darwin.exit(1) }
    }
}

/// 无缓冲输出(绕 stdout FILE buffer,跨线程可见)。
func log(_ s: String = "", terminator: String = "\n") {
    FileHandle.standardOutput.write(Data((s + terminator).utf8))
    if let err = FileHandle.standardError as FileHandle? { _ = err }   // no-op,保 stderr 句柄
}

/// 调试用 transport wrapper:打印每条入站 ACPInbound + 出站 raw JSON,透传给真实 transport。
final class LoggingTransport: ACPTransport, @unchecked Sendable {
    private let wrapped: ACPStdioTransport
    init(wrapping w: ACPStdioTransport) {
        self.wrapped = w
        log("[dbg] LoggingTransport init")
    }

    func send(_ jsonString: String) throws {
        log("[→ send] \(jsonString)")
        try wrapped.send(jsonString)
    }

    func start(
        onInbound: @escaping @Sendable (ACPInbound) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) async throws {
        try await wrapped.start(
            onInbound: { msg in
                log("[← recv] \(describe(msg))")
                onInbound(msg)
            },
            onEOF: { log("[← EOF]"); onEOF() }
        )
    }

    func shutdown() { wrapped.shutdown() }
}

private func describe(_ msg: ACPInbound) -> String {
    switch msg {
    case let .response(id, result, error):
        return "response(id=\(id) error=\(String(describing: error)) result=\(String(describing: result)))"
    case let .request(id, method, params):
        return "request(id=\(id) method=\(method) params=\(String(describing: params)))"
    case let .notification(method, params):
        return "notification(method=\(method) params=\(String(describing: params)))"
    }
}


// MARK: - P5 @mention 引擎池冒烟(ACP_SMOKE_MODE=pool)

/// router + 真适配器双引擎(opencode 默认 + codex-acp 池,env `ACP_SMOKE_MENTION_CMD` 可换
/// claude-agent-acp)。验证 P5 核心语义的**真互操作**版本(单测是 stub):
/// 1. `AgentMention.parse` 行首 @codex → kind + 剥离 prompt
/// 2. `runAgent(kind:)` 路由到懒建池引擎,默认引擎不受影响
/// 3. 双引擎并发各自私有 session(sessionId 不同)
/// 4. 池引擎 session 复用(两轮同 sessionId)+ prepare 钩子只跑一次
@MainActor
func poolSmoke(prompt: String) async {
    var failed = false
    ProjectStore.ensureDefaultProjectRegistered()
    let project = ProjectStore.current()
    let projectRoot = (try? ProjectConfig.ensure(for: project)) ?? project.rootURL
    let mentionCmd = ProcessInfo.processInfo.environment["ACP_SMOKE_MENTION_CMD"]
        .map { $0.split(separator: " ").map(String.init) } ?? ["codex-acp"]
    log("[pool] default=opencode mention=\(mentionCmd) root=\(projectRoot.path)")

    // opencode 默认引擎:与单引擎冒烟同款 env(OPENCODE_CONFIG 指项目 projection)。
    var env = CLIProcessEnvironment.augmented()
    let opencodeConfigPath = ProjectConfig.opencodeConfig(for: project).path
    env = env.merging(["OPENCODE_CONFIG": opencodeConfigPath]) { _, new in new }
    let defaultEngine = ACPAgentEngine(
        command: ["opencode", "acp"],
        cwd: projectRoot,
        transportFactory: {
            ACPStdioTransport(command: ["opencode", "acp"], processEnvironment: env, currentDirectoryURL: projectRoot)
        }
    )

    let router = AgentModeRouter()
    var prepared: [String] = []
    router.engineFactory = { kind in
        guard kind == .codex else { return nil }
        return CodexACPAgentEngine(command: mentionCmd, cwd: projectRoot)
    }
    router.preparePooledEngine = { kind, _ in prepared.append(kind.rawValue) }
    router.setEngine(defaultEngine)

    // 1) 无 mention → 默认引擎(opencode)
    do {
        log("[pool] run default: \(prompt)")
        var text = ""
        for try await d in router.runAgent(prompt: prompt) { text += d }
        log("[pool] default replied \(text.count) chars: \(text.prefix(60))")
    } catch { log("[pool][err] default run: \(error)"); failed = true }
    let defaultSid = defaultEngine.currentSessionId
    if defaultSid == nil { log("[pool][err] 默认引擎无 session"); failed = true }

    // 2) @codex → AgentMention 解析 + 池路由
    let mention = AgentMention.parse("@codex \(prompt)")
    log("[pool] mention parse: kind=\(String(describing: mention.kind)) prompt=\(mention.prompt)")
    if mention.kind != .codex { log("[pool][err] mention 解析失败"); failed = true }
    do {
        var text = ""
        for try await d in router.runAgent(prompt: mention.prompt, kind: mention.kind) { text += d }
        log("[pool] codex replied \(text.count) chars: \(text.prefix(60))")
    } catch { log("[pool][err] codex run: \(error)"); failed = true }

    let pooled = router.existingPooledEngine(for: .codex) as? ACPAgentEngine
    let codexSid1 = pooled?.currentSessionId
    log("[pool] sessions: default=\(defaultSid ?? "nil") codex=\(codexSid1 ?? "nil")")
    if pooled == nil { log("[pool][err] 池引擎未懒建"); failed = true }
    if codexSid1 == nil || codexSid1 == defaultSid { log("[pool][err] session 未独立"); failed = true }
    if prepared != ["codex"] { log("[pool][err] prepare 次数异常: \(prepared)"); failed = true }

    // 3) 第二个 @codex → 同 session 复用,prepare 不重复
    do {
        var text = ""
        for try await d in router.runAgent(prompt: "用一个字回答:2+2=?", kind: .codex) { text += d }
        log("[pool] codex 2nd replied \(text.count) chars: \(text.prefix(60))")
    } catch { log("[pool][err] codex 2nd run: \(error)"); failed = true }
    let codexSid2 = pooled?.currentSessionId
    if codexSid2 != codexSid1 {
        log("[pool][err] 池引擎 session 未复用: \(codexSid1 ?? "nil") → \(codexSid2 ?? "nil")")
        failed = true
    }
    if prepared != ["codex"] { log("[pool][err] prepare 重复: \(prepared)"); failed = true }

    log(failed ? "[pool] FAILED" : "[pool] OK")
    if failed { Darwin.exit(1) }
}
