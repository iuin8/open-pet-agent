import Foundation

// ACPClient:持 `ACPTransport`,实现 ACP client 角色 —— send request(配 id 等 response)、
// 收 notification(session/update)分发到 handler、收 response(id→continuation 配对)。
//
// 高层流程(ACP v1):connect(initialize 协商)→ createSession(session/new)→
// prompt(session/prompt,流式 session/update,最后 result 带 stopReason + unstable usage)。
//
// 健壮性(ACP-1a 审查 follow-up):
// - `onEOF`(transport 的 EOF/进程死通知)→ 唤醒所有 pending continuation throwing,免永挂。
// - per-request wall-clock timeout → agent 失联 response 不永挂。
// - `withTaskCancellationHandler` → consumer 取消时唤醒 pending throwing(cancel 不响应是
//   `withCheckedThrowingContinuation` 的固有限制,onCancel 兜底唤醒)。
// - inbound 保序(ACP-3):AsyncStream 串行消费,流式 chunk/response 不乱序(见 connect)。

/// ACP client 错误。
public enum ACPClientError: Error, Sendable, Equatable {
    case responseError(code: Int, message: String)
    case transport(String)
    case timeout
    case cancelled
    case notConnected
}

/// `initialize` 协商结果。
public struct ACPAgentCapabilities: Sendable, Equatable {
    public let protocolVersion: Int
    public let agentCapabilities: Set<String>
    /// `agentCapabilities.mcpCapabilities` 里值为 true 的远程 MCP transport 能力。
    /// ACP v1 用能力门控而非版本号引入 http/sse（见 protocol/initialization）：
    /// 未声明的 transport 不应出现在 `session/new` 的 `mcpServers` 里。
    public let mcpCapabilities: Set<ACPMCPCapability>

    public init(protocolVersion: Int, agentCapabilities: Set<String>, mcpCapabilities: Set<ACPMCPCapability> = []) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.mcpCapabilities = mcpCapabilities
    }
}

/// ACP v1 `mcpCapabilities` 里的远程 MCP transport 能力项。
public enum ACPMCPCapability: String, Sendable, Equatable {
    case http
    case sse
}

/// ACP client:经 transport 跟 agent 子进程通信。
public actor ACPClient {
    private let transport: any ACPTransport
    private var nextID: Int = 0
    private var pending: [Int: CheckedContinuation<ACPJSON, any Error>] = [:]
    private var updateHandler: (@Sendable (ACPSessionUpdate) -> Void)?
    /// agent → client 权限请求回调(ACP-2:App 注入显示 PermissionCard)。无则安全默认 reject。
    public var onPermissionRequest: (@Sendable (ACPPermissionRequest) async -> ACPPermissionOutcome)?
    private var didConnect = false
    private var eofHandled = false
    /// 保序 inbound 消费 Task(connect 建,shutdown 取消;见 connect 内注释)。
    private var inboundTask: Task<Void, Never>?

    /// 默认 per-request timeout(纳秒)。connect/createSession 用短,prompt 用长。
    private static let shortTimeoutNs: UInt64 = 30_000_000_000   // 30s
    private static let promptTimeoutNs: UInt64 = 180_000_000_000 // 180s(agent 思考 + 流式)

    public init(transport: any ACPTransport) {
        self.transport = transport
    }

    // MARK: - connect(initialize)

    public func connect() async throws -> ACPAgentCapabilities {
        guard !didConnect else { return ACPAgentCapabilities(protocolVersion: 1, agentCapabilities: []) }
        // 保序(ACP-3 审查发现):onInbound 每条消息各开一个 Task hop actor,调度顺序不保证,
        // 流式 chunk 可能乱序(测试实测 deltas 反转)。AsyncStream yield 保 FIFO;
        // onEOF → stream finish,在读循环结束后处理(自然排在最后一条消息之后)。
        let (inbound, inboundCont) = AsyncStream.makeStream(of: ACPInbound.self)
        try await transport.start(
            onInbound: { msg in inboundCont.yield(msg) },
            onEOF: { inboundCont.finish() }
        )
        inboundTask = Task { [weak self] in
            for await msg in inbound { await self?.handleInbound(msg) }
            await self?.handleEOF()
        }
        let id = nextRequestID()
        let params: ACPJSON = .object([
            "protocolVersion": .int(1),
            "clientCapabilities": .object([:]),
        ])
        let result = try await sendRequest(id: id, method: ACPMethod.initialize, params: params, timeoutNs: Self.shortTimeoutNs)
        let obj = result.objectValue ?? [:]
        let proto = obj["protocolVersion"]?.stringValue.flatMap(Int.init)
            ?? obj["protocolVersion"].flatMap { if case .int(let v) = $0 { return v }; return nil }
            ?? 1
        let capsKeys = obj["agentCapabilities"]?.objectValue?.keys.reduce(into: Set<String>()) { $0.insert($1) } ?? []
        let mcpCaps = (obj["agentCapabilities"]?.objectValue?["mcpCapabilities"]?.objectValue ?? [:])
            .reduce(into: Set<ACPMCPCapability>()) { caps, entry in
                guard case .bool(let supported) = entry.value, supported,
                      let capability = ACPMCPCapability(rawValue: entry.key) else { return }
                caps.insert(capability)
            }
        didConnect = true
        return ACPAgentCapabilities(protocolVersion: proto, agentCapabilities: capsKeys, mcpCapabilities: mcpCaps)
    }

    // MARK: - createSession(session/new)

    public func createSession(cwd: String, mcpServers: [ACPJSON]) async throws -> String {
        guard didConnect else { throw ACPClientError.notConnected }
        let id = nextRequestID()
        let params: ACPJSON = .object([
            "cwd": .string(cwd),
            "mcpServers": .array(mcpServers),
        ])
        let result = try await sendRequest(id: id, method: ACPMethod.sessionNew, params: params, timeoutNs: Self.shortTimeoutNs)
        guard let sid = result.objectValue?["sessionId"]?.stringValue else {
            throw ACPClientError.transport("session/new 未返回 sessionId")
        }
        return sid
    }

    // MARK: - prompt(session/prompt + 流式 update)

    public func prompt(text: String, onUpdate: @escaping @Sendable (ACPSessionUpdate) -> Void) async throws -> ACPPromptResult {
        guard didConnect else { throw ACPClientError.notConnected }
        updateHandler = onUpdate
        defer { updateHandler = nil }
        let id = nextRequestID()
        var params: [String: ACPJSON] = [
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]
        if let sessionId { params["sessionId"] = .string(sessionId) }
        let result = try await sendRequest(
            id: id, method: ACPMethod.sessionPrompt, params: .object(params), timeoutNs: Self.promptTimeoutNs)
        return ACPPromptResult(
            stopReason: result.objectValue?["stopReason"]?.stringValue ?? "",
            usage: ACPPromptUsage.decode(fromResult: result)   // unstable,机会性(opencode 1.18 带)
        )
    }

    // MARK: - 内部:request/response 配对 + timeout + cancel

    private func nextRequestID() -> Int {
        let id = nextID; nextID += 1; return id
    }

    /// 发 request + 等 response(按 id 配对)+ wall-clock timeout + cancel 兜底。
    private func sendRequest(id: Int, method: String, params: ACPJSON, timeoutNs: UInt64) async throws -> ACPJSON {
        let req = ACPRPCRequest(id: id, method: method, params: params)
        let json = String(data: try JSONEncoder().encode(req), encoding: .utf8) ?? "{}"

        // timeout Task:到点唤醒 pending throwing .timeout(self-hop)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            if !Task.isCancelled {
                await self?.failPending(id: id, error: .timeout)
            }
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ACPJSON, any Error>) in
                self.pending[id] = cont
                do {
                    try self.transport.send(json)
                } catch {
                    if let c = self.pending.removeValue(forKey: id) {
                        c.resume(throwing: ACPClientError.transport(error.localizedDescription))
                    }
                }
            }
        } onCancel: { [weak self] in
            // consumer 取消 → 唤醒 pending throwing .cancelled(continuation 本身不响应 cancel)
            Task { await self?.failPending(id: id, error: .cancelled) }
        }
    }

    // MARK: - 内部:inbound 路由 + EOF/cancel/timeout 唤醒

    private func handleInbound(_ msg: ACPInbound) async {
        switch msg {
        case let .response(id, result, error):
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let error {
                cont.resume(throwing: ACPClientError.responseError(code: error.code, message: error.message))
            } else {
                cont.resume(returning: result ?? .null)
            }
        case let .request(id, method, params):
            // agent → client request。session/request_permission → 调 onPermissionRequest
            // (App 显示 PermissionCard);无回调 → 安全默认 reject_once(opencode 可继续换方法)。
            if method == ACPMethod.sessionRequestPermission {
                let req = ACPPermissionRequest.decode(from: params)
                let outcome: ACPPermissionOutcome
                if let onPermissionRequest, let req {
                    outcome = await onPermissionRequest(req)
                } else {
                    outcome = req?.safeDefaultOutcome ?? .cancelled
                }
                try? transport.send(outcome.responseJSON(id: id))
            } else {
                // 其它 agent→client request(MVP 回空 result 免 agent 卡等)
                try? transport.send(#"{"jsonrpc":"2.0","id":\#(id),"result":null}"#)
            }
        case let .notification(method, params):
            guard method == ACPMethod.sessionUpdate else { return }
            let decoded: ACPSessionUpdate? = (try? ACPSessionUpdate.decode(from: params)) ?? nil
            if let update = decoded, let handler = updateHandler {
                handler(update)
            }
        }
    }

    /// transport EOF / 进程异常退出 → 唤醒所有 pending throwing(idempotent)。
    private func handleEOF() {
        guard !eofHandled else { return }
        eofHandled = true
        for (_, cont) in pending {
            cont.resume(throwing: ACPClientError.transport("agent 进程 EOF / 异常退出"))
        }
        pending.removeAll()
    }

    /// 唤醒某 pending(timeout / cancel)。
    private func failPending(id: Int, error: ACPClientError) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    // MARK: - session / 生命周期

    public var sessionId: String?

    public func setSessionId(_ sid: String?) {
        self.sessionId = sid
    }

    /// 设置权限请求回调(actor-isolated setter)。
    public func setOnPermissionRequest(_ handler: (@Sendable (ACPPermissionRequest) async -> ACPPermissionOutcome)?) {
        self.onPermissionRequest = handler
    }

    public func shutdown() {
        inboundTask?.cancel()
        transport.shutdown()
    }
}
