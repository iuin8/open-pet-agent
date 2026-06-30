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
//   tool_call_update / usage_update)。本层只解 agent_message_chunk 的 text,未知 kind
//   退 nil 不崩(向前兼容;tool_call 等留 ACP-2)。
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
    case agentMessageChunk = "agent_message_chunk"
    case userMessageChunk = "user_message_chunk"
}

/// `session/update` 的 update payload(从 notification params 解出)。
public struct ACPSessionUpdate: Sendable, Equatable {
    public let sessionUpdate: ACPSessionUpdateKind?   // nil = 未知 kind(向前兼容)
    public let messageId: String?
    /// `content.text` 提取(agent_message_chunk 的 delta 文本;无则 nil)。
    public let textContent: String?

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
        return ACPSessionUpdate(sessionUpdate: kind, messageId: messageId, textContent: text)
    }
}

// MARK: - ACP method 名常量

public enum ACPMethod {
    public static let initialize = "initialize"
    public static let sessionNew = "session/new"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    public static let sessionUpdate = "session/update"   // notification(agent → client)
    public static let sessionRequestPermission = "session/request_permission"  // agent → client request
}
