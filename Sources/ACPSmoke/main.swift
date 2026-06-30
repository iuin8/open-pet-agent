import Foundation
import AgentMode

// ACP-1a 冒烟:用真 ACPStdioTransport spawn `opencode acp`,验证自写 ACP client 真能跟
// opencode 互操作。用法:.build/.../ACPSmoke "prompt"
//
// 用 FileHandle.write 直接写(stdout 重定向时 print 跨线程 buffer 不 flush,会丢日志)。

@main
struct ACPSmoke {
    static func main() async {
        let prompt = CommandLine.arguments.dropFirst().first ?? "用一句话说你好"
        let cwd = FileManager.default.currentDirectoryPath

        let real = ACPStdioTransport(command: ["opencode", "acp"], currentDirectoryURL: URL(fileURLWithPath: cwd))
        let transport: any ACPTransport = LoggingTransport(wrapping: real)
        let client = ACPClient(transport: transport)
        log("[dbg] transport type = \(String(describing: type(of: transport)))")

        log("[connect] initialize…")
        do {
            let caps = try await client.connect()
            log("[connect] protocolVersion=\(caps.protocolVersion) caps=\(caps.agentCapabilities.sorted())")

            let sid = try await client.createSession(cwd: cwd, mcpServers: [])
            await client.setSessionId(sid)
            log("[session] \(sid)")

            log("[prompt] \(prompt)")
            let stop = try await client.prompt(text: prompt) { update in
                log("[update kind=\(String(describing: update.sessionUpdate)) mid=\(update.messageId ?? "nil") text=\(update.textContent ?? "nil")]")
            }
            log("[stop] \(stop)")
        } catch {
            log("[err] \(error)")
        }
        await client.shutdown()
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
