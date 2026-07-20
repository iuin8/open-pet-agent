import Foundation
import Darwin
import AgentMode

// ACP-1a 冒烟:用真 ACPStdioTransport spawn `opencode acp`,验证自写 ACP client 真能跟
// opencode 互操作。用法:.build/.../ACPSmoke "prompt"
//
// 用 FileHandle.write 直接写(stdout 重定向时 print 跨线程 buffer 不 flush,会丢日志)。

@main
struct ACPSmoke {
    static func main() async {
        let prompt = CommandLine.arguments.dropFirst().first ?? "用一句话说你好"

        // P1d:走 ProjectStore.current()(vs 之前 shell cwd)—— 与 applySelectedAgentEngine 同路径,
        // 真互操作 verify 走 ProjectStore(冒烟工具对齐生产架构)。env 指向选中项目 opencode.json。
        ProjectStore.ensureDefaultProjectRegistered()
        let project = ProjectStore.current()
        let projectRoot = (try? ProjectConfig.ensure(for: project)) ?? project.rootURL
        let opencodeConfigPath = ProjectConfig.opencodeConfig(for: project).path
        log("[project] id=\(project.id) root=\(projectRoot.path) config=\(opencodeConfigPath)")

        let real = ACPStdioTransport(
            command: ["opencode", "acp"],
            processEnvironment: CLIProcessEnvironment.augmented()
                .merging(["OPENCODE_CONFIG": opencodeConfigPath]) { _, new in new },
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

            let mcpServers = ACPMCPServerProjection.supported(
                try OpencodeProjectAdapter().loadMCPServers(for: project),
                capabilities: caps.mcpCapabilities
            )
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
