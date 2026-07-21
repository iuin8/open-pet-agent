import Foundation

// ACP(Agent Client Protocol)JSON-RPC 2.0 envelope + session/update 解析。
//
// 自建轻 ACP client 的消息层(纯 Codable,无 transport/外部依赖)。AgentMode 模块
// deps=[],故自备最小 `ACPJSON`(同 Orchestrator 的 JSONValue 模式,避免反依赖)。
// 消息格式核自 ACP spec v1 官方(agentclientprotocol.com/protocol/v1),2026-06 实证。
//
// 设计要点:
// - JSON-RPC 2.0 三类消息:Request(id+method+params)、Notification(method+params 无 id)、
//   Response(id+result|error)。`ACPInbound` 把收到的 raw JSON 判类后归一。
// - session/update 是 notification,其 params.update 含 sessionUpdate discriminator
//   (spec v1 共 6 类:agent_message_chunk / user_message_chunk / plan / tool_call /
//   tool_call_update / usage_update)。本层解 message/thought chunk 的 text +
//   usage_update 的 used/size/cost(ACP-3),未知 kind 退 nil 不崩(向前兼容;
//   tool_call 等留 ACP-2)。
// - PromptResponse 的 unstable `usage`(RFD end-turn-token-usage 仍 Draft)机会性解为
//   `ACPPromptUsage` —— opencode 1.18 实测不推 usage_update 只带此字段,作 fallback;
//   不依赖(agent 可合法不发)。
// - 属性 camelCase,sessionUpdate 值 snake_case(ACP spec 约定)。

// MARK: - ACPJSON(最小 JSON 值,承载 params/result)

/// 任意 JSON 值(承载 ACP params/result/content)。AgentMode 自备(模块 deps[])。
public enum ACPJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ACPJSON])
    case object([String: ACPJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // 顺序要紧:Bool 先于 Int(JSON true/false 不会误判为数);Int 先于 Double。
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([ACPJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: ACPJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法识别的 JSON 值")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: - 便捷访问 / 解析

    public var objectValue: [String: ACPJSON]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [ACPJSON]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    /// 从 JSON 字符串解析。失败 → nil。
    public static func parse(_ jsonString: String) -> ACPJSON? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ACPJSON.self, from: data)
    }
}

// MARK: - JSON-RPC 2.0 envelope(出站:Request;入站判定:ACPInbound)

/// JSON-RPC request(client → agent,带 id 等响应)。
public struct ACPRPCRequest: Encodable, Sendable {
    public let jsonrpc: String = "2.0"
    public let id: Int
    public let method: String
    public let params: ACPJSON?

    public init(id: Int, method: String, params: ACPJSON? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// JSON-RPC error object。
public struct ACPRPCError: Decodable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: ACPJSON?
}

/// 入站消息判类(按 JSON-RPC 字段组合):
/// - 有 id + (result|error) → response
/// - 有 method + id(无 result/error) → request(agent→client,如 session/request_permission)
/// - 有 method 无 id → notification(session/update 等)
public enum ACPInbound: Decodable, Sendable {
    case response(id: Int, result: ACPJSON?, error: ACPRPCError?)
    case request(id: Int, method: String, params: ACPJSON?)
    case notification(method: String, params: ACPJSON?)

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let method = try c.decodeIfPresent(String.self, forKey: .method)
        let id = try c.decodeIfPresent(Int.self, forKey: .id)

        // response:有 result 或 error + 必有 id(JSON-RPC 2.0)。id 缺失/畸形(上游不合规
        // 或 stdout 串入非协议 JSON)→ 抛错,被 parseLine 的 try? 吞掉丢弃,不错配 pending[0]
        // (审查 follow-up:原 id ?? 0 兜底会把畸形 response 错配到首个 request 卡死初始化)。
        if c.contains(.error) {
            guard let id else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "JSON-RPC response 缺 id"))
            }
            let err = try c.decodeIfPresent(ACPRPCError.self, forKey: .error)
            self = .response(id: id, result: nil, error: err)
            return
        }
        if c.contains(.result) {
            guard let id else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "JSON-RPC response 缺 id"))
            }
            let result = try c.decodeIfPresent(ACPJSON.self, forKey: .result)
            self = .response(id: id, result: result, error: nil)
            return
        }

        // request vs notification:看有无 id
        if let method {
            let params = try c.decodeIfPresent(ACPJSON.self, forKey: .params)
            if let id {
                self = .request(id: id, method: method, params: params)
            } else {
                self = .notification(method: method, params: params)
            }
            return
        }

        // 既无 method 又无 result/error:非 ACP 消息
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "非 ACP JSON-RPC 消息(缺 method/result/error)"))
    }
}

// MARK: - session/update(流式增量)

/// `session/update` notification 的 `update` discriminator 值(已知子集;未知不崩)。
public enum ACPSessionUpdateKind: String, Sendable, Equatable {
    /// 最终回复文本(给用户看的)—— engine yield 此 kind 的 text。
    case agentMessageChunk = "agent_message_chunk"
    case userMessageChunk = "user_message_chunk"
    /// 思考流(opencode/deepseek 扩展,reasoning token)—— engine 不 yield(避免 pet 显示思考碎片)。
    case agentThoughtChunk = "agent_thought_chunk"
    /// 上下文/token 用量(stable since schema 0.13.6,agent 每轮后推)—— engine 走 onUsage 回调。
    case usageUpdate = "usage_update"
}

/// `usage_update` 的用量负载:`used` 必填,`size`/`cost` 可选。
/// 核自 ACP RFD session-usage(opencode 每轮 prompt 后推)。
/// size = nil 的另一来源:PromptResponse.usage fallback(agent 未报窗口,UI 自适应猜)。
public struct ACPUsage: Sendable, Equatable {
    /// 已用 token 数(上下文占用)。
    public let used: Int
    /// 上下文窗口总大小(token)。nil = agent 未报(UI 自适应猜窗口;wiring 处 nil 不覆盖已知值)。
    public let size: Int?
    /// 累计费用(agent 未报则 nil)。
    public let cost: Cost?
    /// 该轮 token 明细(来自 PromptResponse unstable usage;usage_update 源无 → nil)。
    /// UI 用作 tooltip 明细(in/cache/out/total),不参与占用条数值。
    public let prompt: ACPPromptUsage?

    public struct Cost: Sendable, Equatable {
        public let amount: Double
        /// 币种代码(如 "USD")。
        public let currency: String

        public init(amount: Double, currency: String) {
            self.amount = amount
            self.currency = currency
        }
    }

    public init(used: Int, size: Int? = nil, cost: Cost? = nil, prompt: ACPPromptUsage? = nil) {
        self.used = used
        self.size = size
        self.cost = cost
        self.prompt = prompt
    }

    /// 从 update payload(整体 dict)解出。used 缺失或类型不符 → nil(不崩);size 可缺(宽容)。
    static func decode(from update: [String: ACPJSON]) -> ACPUsage? {
        guard let used = acpIntValue(update["used"]) else { return nil }
        var cost: Cost? = nil
        if let c = update["cost"]?.objectValue,
           let amount = acpDoubleValue(c["amount"]),
           let currency = c["currency"]?.stringValue {
            cost = Cost(amount: amount, currency: currency)
        }
        return ACPUsage(used: used, size: acpIntValue(update["size"]), cost: cost)
    }
}

/// uint64 token 数:正常走 .int;超大值被 ACPJSON 退成 .double 时兜底截断。
private func acpIntValue(_ json: ACPJSON?) -> Int? {
    switch json {
    case .int(let v): return v
    case .double(let d): return Int(d)
    default: return nil
    }
}

private func acpDoubleValue(_ json: ACPJSON?) -> Double? {
    switch json {
    case .double(let d): return d
    case .int(let i): return Double(i)
    default: return nil
    }
}

/// PromptResponse 的 unstable `usage`(RFD end-turn-token-usage 仍 Draft;机会性读取,不依赖)。
/// opencode 1.18 实测:per-turn 值(非 spec 草案的累计口径),`inputTokens + cachedReadTokens`
/// ≈ 该轮后上下文占用(与 opencode 自家 usage_update.used 同公式)。无窗口 size。
/// output/thought/total 为可选明细(tooltip 用;agent 未报则 nil)。
public struct ACPPromptUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let cachedReadTokens: Int
    public let outputTokens: Int?
    public let thoughtTokens: Int?
    public let totalTokens: Int?
    /// 上下文占用近似(= input + cache.read,同 opencode usage_update.used 公式)。
    public var contextUsed: Int { inputTokens + cachedReadTokens }

    public init(
        inputTokens: Int,
        cachedReadTokens: Int = 0,
        outputTokens: Int? = nil,
        thoughtTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.cachedReadTokens = cachedReadTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.totalTokens = totalTokens
    }

    /// 从 PromptResponse result 整体解 `usage` 字段。缺 inputTokens → nil(agent 未报,不崩)。
    static func decode(fromResult result: ACPJSON?) -> ACPPromptUsage? {
        guard let u = result?.objectValue?["usage"]?.objectValue,
              let input = acpIntValue(u["inputTokens"]) else { return nil }
        return ACPPromptUsage(
            inputTokens: input,
            cachedReadTokens: acpIntValue(u["cachedReadTokens"]) ?? 0,
            outputTokens: acpIntValue(u["outputTokens"]),
            thoughtTokens: acpIntValue(u["thoughtTokens"]),
            totalTokens: acpIntValue(u["totalTokens"])
        )
    }
}

/// session/prompt 的响应:stopReason(stable)+ usage(unstable,机会性;agent 未报则 nil)。
public struct ACPPromptResult: Sendable, Equatable {
    public let stopReason: String
    public let usage: ACPPromptUsage?

    public init(stopReason: String, usage: ACPPromptUsage? = nil) {
        self.stopReason = stopReason
        self.usage = usage
    }
}

/// `session/update` 的 update payload(从 notification params 解出)。
public struct ACPSessionUpdate: Sendable, Equatable {
    public let sessionUpdate: ACPSessionUpdateKind?   // nil = 未知 kind(向前兼容)
    public let messageId: String?
    /// `content.text` 提取(agent_message_chunk 的 delta 文本;无则 nil)。
    public let textContent: String?
    /// `usage_update` 的用量负载(仅 kind == .usageUpdate 且字段齐时非 nil)。
    public let usage: ACPUsage?

    /// 从 `session/update` notification 的 **params**(整体)解出 update 字段。
    /// params 形如 `{"sessionId":..,"update":{...}}`。
    public static func decode(from params: ACPJSON?) throws -> ACPSessionUpdate? {
        guard let params, let obj = params.objectValue, let updateJSON = obj["update"] else {
            return nil
        }
        let update = updateJSON.objectValue ?? [:]
        let kind = update["sessionUpdate"]?.stringValue.flatMap(ACPSessionUpdateKind.init(rawValue:))
        let messageId = update["messageId"]?.stringValue
        // content 形如 {"type":"text","text":"..."}
        let content = update["content"]?.objectValue
        let text = content?["text"]?.stringValue
        let usage: ACPUsage? = (kind == .usageUpdate) ? ACPUsage.decode(from: update) : nil
        return ACPSessionUpdate(sessionUpdate: kind, messageId: messageId, textContent: text, usage: usage)
    }
}

// MARK: - ACP method 名常量

public enum ACPMethod {
    public static let initialize = "initialize"
    public static let sessionNew = "session/new"
    public static let sessionLoad = "session/load"   // 回放全部历史为 session/update 后响应(loadSession 能力门控)
    public static let sessionList = "session/list"   // sessionCapabilities.list 能力门控
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    public static let sessionUpdate = "session/update"   // notification(agent → client)
    public static let sessionRequestPermission = "session/request_permission"  // agent → client request
}

// MARK: - session/list(P2)

/// `session/list` 返回的一条会话信息(schema v1.4.0 SessionInfo;title/updatedAt 可空)。
public struct ACPSessionInfo: Sendable, Equatable {
    public let sessionId: String
    public let cwd: String
    /// 人类可读标题(agent 未给则 nil,UI 兜底显示 sessionId 前缀)。
    public let title: String?
    /// ISO 8601 最近活动时间(agent 未给则 nil)。
    public let updatedAt: String?

    public init(sessionId: String, cwd: String, title: String? = nil, updatedAt: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
    }

    /// 从 sessions 数组单项解出。缺 sessionId/cwd → nil(配合数组 compactMap 容忍坏项,
    /// 对齐 schema 的 x-deserialize-skip-invalid-items)。
    static func decode(from json: ACPJSON?) -> ACPSessionInfo? {
        guard let o = json?.objectValue,
              let sid = o["sessionId"]?.stringValue,
              let cwd = o["cwd"]?.stringValue else { return nil }
        return ACPSessionInfo(
            sessionId: sid, cwd: cwd,
            title: o["title"]?.stringValue, updatedAt: o["updatedAt"]?.stringValue
        )
    }
}

/// `session/list` 的响应:sessions + 分页 cursor(无 nextCursor = 没有更多)。
public struct ACPSessionListResult: Sendable, Equatable {
    public let sessions: [ACPSessionInfo]
    public let nextCursor: String?

    public init(sessions: [ACPSessionInfo], nextCursor: String? = nil) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }

    /// 从 result 整体解出(sessions 必填,坏项跳过)。
    static func decode(from result: ACPJSON?) -> ACPSessionListResult {
        let obj = result?.objectValue ?? [:]
        let sessions = (obj["sessions"]?.arrayValue ?? []).compactMap { ACPSessionInfo.decode(from: $0) }
        return ACPSessionListResult(sessions: sessions, nextCursor: obj["nextCursor"]?.stringValue)
    }
}

// MARK: - session/request_permission(ACP-2)

/// agent → client 的权限请求(agent 执行工具前问用户授权)。核自 ACP spec v1 tool-calls。
public struct ACPPermissionRequest: Sendable, Equatable {
    public let toolCallId: String?
    public let title: String?
    /// 工具类别(read / edit / delete / move / search / execute / fetch / other)。
    public let kind: String?
    public let options: [Option]

    public init(toolCallId: String?, title: String?, kind: String?, options: [Option]) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.options = options
    }

    public struct Option: Sendable, Equatable {
        public let optionId: String
        public let name: String
        /// allow_once / allow_always / reject_once / reject_always。
        public let kind: String
        public init(optionId: String, name: String, kind: String) {
            self.optionId = optionId
            self.name = name
            self.kind = kind
        }
    }

    /// 从 session/request_permission 的 params 解出。
    public static func decode(from params: ACPJSON?) -> ACPPermissionRequest? {
        guard let params, let obj = params.objectValue else { return nil }
        let tc = obj["toolCall"]?.objectValue
        let opts: [Option] = (obj["options"]?.arrayValue ?? []).compactMap { o in
            guard let o = o.objectValue else { return nil }
            return Option(
                optionId: o["optionId"]?.stringValue ?? "",
                name: o["name"]?.stringValue ?? "",
                kind: o["kind"]?.stringValue ?? ""
            )
        }
        return ACPPermissionRequest(
            toolCallId: tc?["toolCallId"]?.stringValue,
            title: tc?["title"]?.stringValue,
            kind: tc?["kind"]?.stringValue,
            options: opts
        )
    }

    /// 安全默认(无 UI 回调时):找 reject_once 选项拒绝;无则 cancelled。
    /// 选 reject_once 而非 cancelled —— opencode 收 reject 可继续换方法,cancelled 整 turn 卡。
    public var safeDefaultOutcome: ACPPermissionOutcome {
        if let opt = options.first(where: { $0.kind == "reject_once" }) {
            return .selected(optionId: opt.optionId)
        }
        return .cancelled
    }
}

/// client 对权限请求的响应。
public enum ACPPermissionOutcome: Sendable, Equatable {
    case selected(optionId: String)
    case cancelled

    /// 编码成 session/request_permission 的完整 JSON-RPC response。
    public func responseJSON(id: Int) -> String {
        switch self {
        case .selected(let optionId):
            let opt = (try? JSONEncoder().encode(optionId)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            return #"{"jsonrpc":"2.0","id":\#(id),"result":{"outcome":{"outcome":"selected","optionId":\#(opt)}}}"#
        case .cancelled:
            return #"{"jsonrpc":"2.0","id":\#(id),"result":{"outcome":{"outcome":"cancelled"}}}"#
        }
    }
}
