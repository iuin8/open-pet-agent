import Foundation

// ACPClient:持 `ACPTransport`,实现 ACP client 角色 —— send request(配 id 等 response)、
// 收 notification(session/update)分发到 handler、收 response(request→id 配对唤醒)。
//
// 高层流程(ACP v1):connect(initialize 协商)→ createSession(session/new 拿 sessionId)
// → prompt(session/prompt,流式收 session/update,最后 result 带 stopReason)。
//
// 并发:transport 的 onInbound 在后台线程回调;pending request 用 id→Continuation 字典
// (actor 保护);notification 同步调 handler(上层保证 handler 线程安全 / 跨 actor hop)。

/// ACP client 错误。
public enum ACPClientError: Error, Sendable, Equatable {
    case responseError(code: Int, message: String)
    case transport(String)
    case timeout
    case notConnected
}

/// `initialize` 协商结果。
public struct ACPAgentCapabilities: Sendable, Equatable {
    public let protocolVersion: Int
    /// agent 能力键集合(loadSession / sessionCapabilities.* / mcpCapabilities.* 等原始 key)。
    public let agentCapabilities: Set<String>

    public init(protocolVersion: Int, agentCapabilities: Set<String>) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
    }
}

/// ACP client:经 transport 跟 agent 子进程通信,封装 request/response 配对 + session/update 分发。
public actor ACPClient {
    private let transport: any ACPTransport
    private var nextID: Int = 0
    private var pending: [Int: CheckedContinuation<ACPJSON, any Error>] = [:]
    /// 当前 active prompt 的 update handler(单条 prompt 在飞;多 prompt 串行)。
    private var updateHandler: (@Sendable (ACPSessionUpdate) -> Void)?
    private var didConnect = false

    public init(transport: any ACPTransport) {
        self.transport = transport
    }

    // MARK: - connect(initialize)

    /// 发 `initialize` 协商协议版本 + 能力。仅一次(didConnect 守卫)。
    public func connect() async throws -> ACPAgentCapabilities {
        guard !didConnect else {
            // 已连接:不重复 initialize,直接返回(简单;真实可缓存 caps)
            return ACPAgentCapabilities(protocolVersion: 1, agentCapabilities: [])
        }
        try await transport.start { [weak self] msg in
            Task { await self?.handleInbound(msg) }
        }
        let id = nextRequestID()
        let params: ACPJSON = .object([
            "protocolVersion": .int(1),
            "clientCapabilities": .object([:]),
        ])
        let result = try await sendRequest(id: id, method: ACPMethod.initialize, params: params)
        let obj = result.objectValue ?? [:]
        let proto = obj["protocolVersion"]?.stringValue.flatMap(Int.init)
            ?? obj["protocolVersion"].flatMap { if case .int(let v) = $0 { return v }; return nil }
            ?? 1
        let capsKeys = obj["agentCapabilities"]?.objectValue?.keys.reduce(into: Set<String>()) { s, k in s.insert(k) } ?? []
        didConnect = true
        return ACPAgentCapabilities(protocolVersion: proto, agentCapabilities: capsKeys)
    }

    // MARK: - createSession(session/new)

    /// 发 `session/new` 创建会话,返回 sessionId。**须先 connect。**
    public func createSession(cwd: String, mcpServers: [ACPJSON]) async throws -> String {
        guard didConnect else { throw ACPClientError.notConnected }
        let id = nextRequestID()
        let params: ACPJSON = .object([
            "cwd": .string(cwd),
            "mcpServers": .array(mcpServers),
        ])
        let result = try await sendRequest(id: id, method: ACPMethod.sessionNew, params: params)
        guard let sid = result.objectValue?["sessionId"]?.stringValue else {
            throw ACPClientError.transport("session/new 未返回 sessionId")
        }
        return sid
    }

    // MARK: - prompt(session/prompt + 流式 update)

    /// 发 `session/prompt`,流式收 `session/update`(每条 `agent_message_chunk` 调 `onUpdate`),
    /// 等 prompt 的 result(带 stopReason)后返回 stopReason 字符串。**须先 createSession。**
    public func prompt(text: String, onUpdate: @escaping @Sendable (ACPSessionUpdate) -> Void) async throws -> String {
        guard didConnect else { throw ACPClientError.notConnected }
        updateHandler = onUpdate
        defer { updateHandler = nil }

        let id = nextRequestID()
        let result = try await sendPromptRequest(id: id, text: text)
        let stop = result.objectValue?["stopReason"]?.stringValue ?? ""
        return stop
    }

    // MARK: - 内部:request/response 配对

    private func nextRequestID() -> Int {
        let id = nextID; nextID += 1; return id
    }

    private func sendRequest(id: Int, method: String, params: ACPJSON) async throws -> ACPJSON {
        let req = ACPRPCRequest(id: id, method: method, params: params)
        let json = String(data: try JSONEncoder().encode(req), encoding: .utf8) ?? "{}"
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ACPJSON, any Error>) in
            self.pending[id] = cont
            do {
                try self.transport.send(json)
            } catch {
                if let c = self.pending.removeValue(forKey: id) {
                    c.resume(throwing: ACPClientError.transport(error.localizedDescription))
                }
            }
        }
    }

    /// session/prompt:onUpdate handler 在 result 到达**前**持续收 notification
    /// (handleInbound 里调 updateHandler)。params 带 sessionId(若已注入)+ prompt text。
    private func sendPromptRequest(id: Int, text: String) async throws -> ACPJSON {
        var promptParams: [String: ACPJSON] = [
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]
        if let sessionId { promptParams["sessionId"] = .string(sessionId) }
        let req = ACPRPCRequest(id: id, method: ACPMethod.sessionPrompt, params: .object(promptParams))
        let json = String(data: try JSONEncoder().encode(req), encoding: .utf8) ?? "{}"
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ACPJSON, any Error>) in
            self.pending[id] = cont
            do {
                try self.transport.send(json)
            } catch {
                if let c = self.pending.removeValue(forKey: id) {
                    c.resume(throwing: ACPClientError.transport(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - 内部:inbound 路由(transport 后台线程回调)

    private func handleInbound(_ msg: ACPInbound) {
        switch msg {
        case let .response(id, result, error):
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let error {
                cont.resume(throwing: ACPClientError.responseError(code: error.code, message: error.message))
            } else {
                cont.resume(returning: result ?? .null)
            }
        case let .request(id, method, params):
            // agent → client request(如 session/request_permission):MVP 不处理,回空 result
            // (ACP-2 接 PermissionCard)。fire-and-forget 回 response 免 agent 卡等。
            let res = #"{"jsonrpc":"2.0","id":\#(id),"result":null}"#
            try? transport.send(res)
            _ = method; _ = params
        case let .notification(method, params):
            guard method == ACPMethod.sessionUpdate else { return }
            // decode 返回 `ACPSessionUpdate?`(可解出但 update 字段缺失 → nil);外层 try? 吞解析异常
            let decoded: ACPSessionUpdate? = (try? ACPSessionUpdate.decode(from: params)) ?? nil
            if let update = decoded, let handler = updateHandler {
                handler(update)
            }
        }
    }

    /// 供 ACPAgentEngine 注入当前 sessionId(session/prompt params 要带)。
    public var sessionId: String?

    /// 设置当前 session id(由 ACPAgentEngine 在 createSession 后注入)。
    public func setSessionId(_ sid: String?) {
        self.sessionId = sid
    }

    public func shutdown() {
        transport.shutdown()
    }
}

// MARK: - 测试 helper(JSONEncoder 编码字符串)

extension JSONEncoder {
    /// 编码任意 Codable 为 JSON 字符串(测试 fixture 用)。
    func encodedString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
