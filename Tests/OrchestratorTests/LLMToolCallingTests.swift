import Testing
import Foundation
@testable import Orchestrator

// 灵魂层「自建轻 harness」P0 测试 —— provider tool-calling 通道(chatWithTools)。
// 覆盖:JSONValue 编解码;default no-op(老 provider 退化纯文本);OpenAI/Anthropic
// 工具回合解析(tool_calls / tool_use → LLMTurn)+ 请求体含 tools;stop_reason 归一。
// 用注入 httpClient 喂 canned JSON,不打真 API(镜像既有 OpenAIProviderTests 模式)。

// MARK: - 测试夹具

private func httpResponse(_ status: Int, _ urlString: String) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: urlString)!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private let openAIURL = "https://api.openai.com/v1/chat/completions"
private let anthropicURL = "https://api.anthropic.com/v1/messages"

/// 只实现 `chat` 的最简 provider —— 不覆写 `chatWithTools`,走协议 default。
private struct TextOnlyStub: LLMProvider {
    let reply: String
    func chat(_ messages: [LLMMessage]) async throws -> String { reply }
}

private let weatherTool = LLMToolDef(
    name: "get_weather",
    description: "查某城天气",
    parameters: .object([
        "type": .string("object"),
        "properties": .object(["city": .object(["type": .string("string")])]),
        "required": .array([.string("city")])
    ])
)

// MARK: - JSONValue 编解码

@Test("JSONValue: 各类型 round-trip 编解码相等(含嵌套 / int vs double)")
func jsonValueRoundTrips() throws {
    let value: JSONValue = .object([
        "s": .string("hi"),
        "i": .int(5),
        "d": .double(5.5),
        "b": .bool(true),
        "n": .null,
        "arr": .array([.int(1), .string("x")]),
        "nested": .object(["k": .bool(false)])
    ])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
}

@Test("JSONValue: parse JSON 串(int 不退化成 double,true 不误判 int)")
func jsonValueParse() {
    #expect(JSONValue.parse("5") == .int(5))
    #expect(JSONValue.parse("5.5") == .double(5.5))
    #expect(JSONValue.parse("true") == .bool(true))
    #expect(JSONValue.parse("{\"city\":\"Shanghai\"}") == .object(["city": .string("Shanghai")]))
    #expect(JSONValue.parse("not json") == nil)
}

@Test("JSONValue: encodedString → 再 parse 相等(免比字符串 key 序)")
func jsonValueEncodedStringRoundTrips() throws {
    let value: JSONValue = .object(["a": .int(1), "b": .array([.string("x")])])
    let str = try #require(value.encodedString())
    #expect(JSONValue.parse(str) == value)
}

// MARK: - 默认实现(老 provider 零改动退化纯文本)

@Test("chatWithTools default: 只实现 chat 的 provider 忽略 tools、返回纯文本 LLMTurn")
func defaultChatWithToolsIgnoresTools() async throws {
    let stub = TextOnlyStub(reply: "你好")
    let turn = try await stub.chatWithTools([LLMMessage(role: .user, content: "hi")], tools: [weatherTool])
    #expect(turn.text == "你好")
    #expect(turn.toolCalls.isEmpty)
    #expect(turn.stopReason == .stop)
}

// MARK: - OpenAI chatWithTools

@Test("OpenAI chatWithTools: tool_calls 响应 → 解析 toolCalls(arguments JSON 串→对象)+ stopReason=.toolUse")
func openAIToolCallsParsed() async throws {
    let json = """
    {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
      {"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\\"city\\":\\"Shanghai\\"}"}}
    ]},"finish_reason":"tool_calls"}]}
    """
    let provider = OpenAIProvider(apiKey: "sk-test", httpClient: { _ in
        (Data(json.utf8), httpResponse(200, openAIURL))
    })
    let turn = try await provider.chatWithTools([LLMMessage(role: .user, content: "上海天气")], tools: [weatherTool])
    #expect(turn.stopReason == .toolUse)
    #expect(turn.text == nil)
    #expect(turn.toolCalls.count == 1)
    #expect(turn.toolCalls.first?.id == "call_1")
    #expect(turn.toolCalls.first?.name == "get_weather")
    #expect(turn.toolCalls.first?.arguments.objectValue?["city"]?.stringValue == "Shanghai")
}

@Test("OpenAI chatWithTools: 纯文本响应 → text + stopReason=.stop,无 toolCalls")
func openAIToolsTextResponse() async throws {
    let json = """
    {"choices":[{"message":{"role":"assistant","content":"晴天"},"finish_reason":"stop"}]}
    """
    let provider = OpenAIProvider(apiKey: "sk-test", httpClient: { _ in
        (Data(json.utf8), httpResponse(200, openAIURL))
    })
    let turn = try await provider.chatWithTools([LLMMessage(role: .user, content: "hi")], tools: [weatherTool])
    #expect(turn.text == "晴天")
    #expect(turn.toolCalls.isEmpty)
    #expect(turn.stopReason == .stop)
}

@Test("OpenAI chatWithTools: 请求体含 tools(function 名)+ tool_choice=auto")
func openAIToolsRequestBody() async throws {
    var captured: URLRequest?
    let provider = OpenAIProvider(apiKey: "sk-test", httpClient: { req in
        captured = req
        return (Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8),
                httpResponse(200, openAIURL))
    })
    _ = try await provider.chatWithTools([LLMMessage(role: .user, content: "hi")], tools: [weatherTool])
    let body = try #require(captured?.httpBody)
    let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let tools = try #require(obj["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    let function = try #require(tools.first?["function"] as? [String: Any])
    #expect(function["name"] as? String == "get_weather")
    #expect(obj["tool_choice"] as? String == "auto")
}

@Test("OpenAI mapFinishReason: tool_calls→toolUse / stop→stop / length→maxTokens / nil 看有无工具")
func openAIMapFinishReason() {
    #expect(OpenAIProvider.mapFinishReason("tool_calls", hasToolCalls: true) == .toolUse)
    #expect(OpenAIProvider.mapFinishReason("stop", hasToolCalls: false) == .stop)
    #expect(OpenAIProvider.mapFinishReason("length", hasToolCalls: false) == .maxTokens)
    #expect(OpenAIProvider.mapFinishReason(nil, hasToolCalls: true) == .toolUse)
    #expect(OpenAIProvider.mapFinishReason(nil, hasToolCalls: false) == .stop)
}

// MARK: - Anthropic chatWithTools

@Test("Anthropic chatWithTools: tool_use 块 → 解析 toolCalls(input 已是对象)+ 共存 text + stopReason=.toolUse")
func anthropicToolUseParsed() async throws {
    let json = """
    {"content":[
      {"type":"text","text":"我查一下。"},
      {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"Shanghai"}}
    ],"stop_reason":"tool_use"}
    """
    let provider = AnthropicProvider(apiKey: "sk-ant-test", httpClient: { _ in
        (Data(json.utf8), httpResponse(200, anthropicURL))
    })
    let turn = try await provider.chatWithTools([LLMMessage(role: .user, content: "上海天气")], tools: [weatherTool])
    #expect(turn.stopReason == .toolUse)
    #expect(turn.text == "我查一下。")
    #expect(turn.toolCalls.count == 1)
    #expect(turn.toolCalls.first?.id == "toolu_1")
    #expect(turn.toolCalls.first?.name == "get_weather")
    #expect(turn.toolCalls.first?.arguments.objectValue?["city"]?.stringValue == "Shanghai")
}

@Test("Anthropic chatWithTools: 纯 text 块 → text + stopReason=.stop(end_turn)")
func anthropicToolsTextResponse() async throws {
    let json = """
    {"content":[{"type":"text","text":"晴天"}],"stop_reason":"end_turn"}
    """
    let provider = AnthropicProvider(apiKey: "sk-ant-test", httpClient: { _ in
        (Data(json.utf8), httpResponse(200, anthropicURL))
    })
    let turn = try await provider.chatWithTools([LLMMessage(role: .user, content: "hi")], tools: [weatherTool])
    #expect(turn.text == "晴天")
    #expect(turn.toolCalls.isEmpty)
    #expect(turn.stopReason == .stop)
}

@Test("Anthropic chatWithTools: 请求体含顶层 tools(input_schema)")
func anthropicToolsRequestBody() async throws {
    var captured: URLRequest?
    let provider = AnthropicProvider(apiKey: "sk-ant-test", httpClient: { req in
        captured = req
        return (Data(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#.utf8),
                httpResponse(200, anthropicURL))
    })
    _ = try await provider.chatWithTools([LLMMessage(role: .user, content: "hi")], tools: [weatherTool])
    let body = try #require(captured?.httpBody)
    let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let tools = try #require(obj["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools.first?["name"] as? String == "get_weather")
    #expect(tools.first?["input_schema"] != nil)
}

@Test("Anthropic mapStopReason: tool_use→toolUse / end_turn→stop / max_tokens→maxTokens / nil 看有无工具")
func anthropicMapStopReason() {
    #expect(AnthropicProvider.mapStopReason("tool_use", hasToolCalls: true) == .toolUse)
    #expect(AnthropicProvider.mapStopReason("end_turn", hasToolCalls: false) == .stop)
    #expect(AnthropicProvider.mapStopReason("max_tokens", hasToolCalls: false) == .maxTokens)
    #expect(AnthropicProvider.mapStopReason(nil, hasToolCalls: true) == .toolUse)
    #expect(AnthropicProvider.mapStopReason(nil, hasToolCalls: false) == .stop)
}
