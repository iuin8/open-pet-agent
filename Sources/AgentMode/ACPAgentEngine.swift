import Foundation

// ACPAgentEngine:把 ACP client 包成 `AgentEngine`。
//
// 取代 ClaudeCodeEngine/CodexEngine 的「每 engine 手写 stdout parser」—— 一套 ACP
// 协议接任意 ACP 兼容 agent(opencode/gemini/...)。transport 可注入(测试用 mock,
// 生产用 `ACPStdioTransport` spawn agent 子进程)。
//
// run(prompt) 流程(ACP v1):connect(initialize)→ createSession(session/new,拿
// sessionId)→ prompt(session/prompt,流式收 session/update 的 agent_message_chunk
// → yield text delta)→ prompt result 带 stopReason → finish。onTermination shutdown。

/// ACP 专属错误(归一到 `AgentEngineError`,对齐既有 engine)。
public enum ACPAgentEngineError: Error, Equatable {
    case notConnected
    case client(String)
}

/// 用 ACP 协议驱动外部 agent 子进程的 `AgentEngine`。
public struct ACPAgentEngine: AgentEngine {
    public static let kind: AgentEngineKind = .openCode

    /// agent 启动命令,如 ["opencode", "acp"]。
    public let command: [String]
    /// 可注入 binary 路径(nil = `CLIAvailability.locate`)。
    public let binaryPath: String?
    /// session 工作目录(nil = 进程 cwd)。
    public let cwd: URL?
    /// transport 工厂(测试注入 mock;生产 `ACPStdioTransport`)。
    public let transportFactory: @Sendable () -> any ACPTransport

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

    public func run(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let transport = transportFactory()
            let client = ACPClient(transport: transport)

            let task = Task {
                do {
                    _ = try await client.connect()
                    let cwdPath = cwd?.path ?? FileManager.default.currentDirectoryPath
                    let sid = try await client.createSession(cwd: cwdPath, mcpServers: [])
                    await client.setSessionId(sid)

                    let stop = try await client.prompt(text: prompt) { update in
                        // agent_message_chunk 的 text delta → yield(对齐 AgentEngine delta 契约)
                        if let text = update.textContent, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    _ = stop   // ACP-0 不消费 stopReason(ACP-2 按类型做 pet 反应)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await client.shutdown()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
