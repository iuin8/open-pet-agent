import Foundation

// 灵魂层「自建轻 harness」P0 —— provider tool-calling 通道的统一抽象类型。
//
// 设计来源:[docs/skill-mcp-integration-roadmap.md] §自建 harness L1。与 `chat()`/
// `streamChat()` 旧文本通道**并行**新增,绝不改旧签名;让 pet 的灵魂层(自带 key 直连
// provider)也能调工具,而非只能走 `ToolMode` 子进程。两家 API(OpenAI tool_calls /
// Anthropic tool_use)的差异关进各 Provider 内部映射,上层只见这套形象无关的统一类型。

/// 任意 JSON 值的最小可编解码表示 —— 承载工具 schema(`LLMToolDef.parameters`)与
/// 工具调用参数(`LLMToolCall.arguments`)。两家 API 的 schema/参数都是任意 JSON,
/// 用此枚举原样承载 + 编码进请求体,免给每个 schema 手写专属 Codable struct。
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // 顺序要紧:Bool 先于 Int(JSON true/false 不会误判为数);Int 先于 Double
        // (整数 schema 值如 `"minLength": 3` 保持 3,不退化成 3.0)。
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
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

    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    /// 从 JSON 字符串解析(OpenAI 的 tool_call `arguments` 是 JSON 串,需二次 parse)。
    /// 解析失败 → nil。
    public static func parse(_ jsonString: String) -> JSONValue? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// 编码回 JSON 字符串(把工具参数喂回工具 / 序列化)。
    public func encodedString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 一个工具的声明(喂给模型让它知道可调什么)。
public struct LLMToolDef: Sendable, Equatable {
    public let name: String
    public let description: String
    /// JSON Schema 对象,如 `{"type":"object","properties":{...},"required":[...]}`。
    /// 原样进请求体(OpenAI `function.parameters` / Anthropic `input_schema`)。
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// 模型发起的一次工具调用。
public struct LLMToolCall: Sendable, Equatable {
    /// provider 分配的调用 id(OpenAI `tool_call.id` / Anthropic `tool_use.id`),
    /// 回填结果时要原样带回去配对。
    public let id: String
    public let name: String
    /// 已归一为对象的调用参数(OpenAI 把 JSON 串 parse 过、Anthropic 本就是对象)。
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// 一次工具执行的结果(回填给模型继续推理;agent loop 在 P1 串联)。
public struct LLMToolResult: Sendable, Equatable {
    public let toolCallID: String
    public let content: String
    public let isError: Bool

    public init(toolCallID: String, content: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
    }
}

/// 模型为何结束这一轮 —— 归一两家的 finish_reason / stop_reason。
public enum LLMStopReason: String, Sendable, Equatable {
    /// 自然结束 / 纯文本完成。
    case stop
    /// 模型要调工具(OpenAI `tool_calls` / Anthropic `tool_use`)。
    case toolUse
    /// 触达 max_tokens 截断。
    case maxTokens
    /// 其它(过滤 / 未知)。
    case other
}

/// `chatWithTools` 的一轮返回 —— 文本 +/或 工具调用 + 结束原因。
/// (Anthropic 可在同一轮同时给 text 块和 tool_use 块,故 text 与 toolCalls 共存。)
public struct LLMTurn: Sendable, Equatable {
    public let text: String?
    public let toolCalls: [LLMToolCall]
    public let stopReason: LLMStopReason

    public init(text: String?, toolCalls: [LLMToolCall], stopReason: LLMStopReason) {
        self.text = text
        self.toolCalls = toolCalls
        self.stopReason = stopReason
    }
}
