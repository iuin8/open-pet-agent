import Testing
import Foundation
@testable import AgentMode

// ACP(Agent Client Protocol)JSON-RPC 2.0 envelope + session/update 解析单测。
// 纯编解码逻辑,无 transport。canned JSON 来自 ACP spec v1 官方示例。

// MARK: - ACPJSON 编解码

@Test("ACPJSON: 各类型 round-trip(int 不退化 double / true 不误判 int)")
func acpJSONRoundTrips() throws {
    let value: ACPJSON = .object([
        "s": .string("hi"),
        "i": .int(5),
        "d": .double(5.5),
        "b": .bool(true),
        "n": .null,
        "arr": .array([.int(1), .string("x")]),
        "nested": .object(["k": .bool(false)]),
    ])
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(ACPJSON.self, from: data)
    #expect(decoded == value)
}

@Test("ACPJSON: parse JSON 串(arguments 场景)")
func acpJSONParse() {
    #expect(ACPJSON.parse("5") == .int(5))
    #expect(ACPJSON.parse("true") == .bool(true))
    #expect(ACPJSON.parse(#"{"city":"Shanghai"}"#) == .object(["city": .string("Shanghai")]))
    #expect(ACPJSON.parse("not json") == nil)
}

// MARK: - JSON-RPC envelope 编码(request)

@Test("ACPRPCRequest 编码: 含 jsonrpc/id/method/params 四字段")
func rpcRequestEncodes() throws {
    let req = ACPRPCRequest(id: 0, method: "initialize", params: .object(["protocolVersion": .int(1)]))
    let data = try JSONEncoder().encode(req)
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["jsonrpc"] as? String == "2.0")
    #expect(obj["id"] as? Int == 0)
    #expect(obj["method"] as? String == "initialize")
    #expect((obj["params"] as? [String: Any])?["protocolVersion"] as? Int == 1)
}

// MARK: - JSON-RPC 解码 + 区分(request/notification/response)

@Test("ACPInbound: response 缺 id(畸形/不合规)→ decode 抛错,被 parseLine 丢弃(不错配 pending[0])")
func inboundResponseNoID() {
    // 有 result 无 id → 不合法 response(JSON-RPC 2.0 response 必带 id)
    let withResult = Data(#"{"jsonrpc":"2.0","result":{"sessionId":"x"}}"#.utf8)
    let decoded: ACPInbound? = try? JSONDecoder().decode(ACPInbound.self, from: withResult)
    #expect(decoded == nil)
    #expect(ACPLineParser.parseLine(withResult) == nil)
    // 有 error 无 id → 同样丢弃
    let withError = Data(#"{"jsonrpc":"2.0","error":{"code":-1,"message":"x"}}"#.utf8)
    #expect(ACPLineParser.parseLine(withError) == nil)
}

@Test("ACPInbound: 有 id + method → request")
func inboundRequest() throws {
    let json = #"{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"tools":["fs"]}}"#
    let msg = try JSONDecoder().decode(ACPInbound.self, from: Data(json.utf8))
    guard case let .request(id, method, _) = msg else {
        Issue.record("应为 request"); return
    }
    #expect(id == 7)
    #expect(method == "session/request_permission")
}

@Test("ACPInbound: 有 method 无 id → notification")
func inboundNotification() throws {
    let json = #"{"jsonrpc":"2.0","method":"session/update","params":{}}"#
    let msg = try JSONDecoder().decode(ACPInbound.self, from: Data(json.utf8))
    if case .notification = msg { } else { Issue.record("应为 notification") }
}

@Test("ACPInbound: 有 id + result → response(success)")
func inboundResponseResult() throws {
    let json = #"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"sess_abc"}}"#
    let msg = try JSONDecoder().decode(ACPInbound.self, from: Data(json.utf8))
    guard case let .response(id, result, error) = msg else {
        Issue.record("应为 response"); return
    }
    #expect(id == 1)
    #expect(error == nil)
    #expect(result?.objectValue?["sessionId"]?.stringValue == "sess_abc")
}

@Test("ACPInbound: 有 id + error → response(error)")
func inboundResponseError() throws {
    let json = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"method not found"}}"#
    let msg = try JSONDecoder().decode(ACPInbound.self, from: Data(json.utf8))
    guard case let .response(_, _, error) = msg else {
        Issue.record("应为 response"); return
    }
    #expect(error?.code == -32601)
    #expect(error?.message == "method not found")
}

// MARK: - session/update 解析(agent_message_chunk)

@Test("ACPSessionUpdate: agent_message_chunk → 提取 text")
func sessionUpdateAgentMessageChunk() throws {
    // spec v1 session-setup 官方示例格式
    let json = """
    {
      "jsonrpc": "2.0",
      "method": "session/update",
      "params": {
        "sessionId": "sess_789xyz",
        "update": {
          "sessionUpdate": "agent_message_chunk",
          "messageId": "msg_agent_c42b9",
          "content": { "type": "text", "text": "The capital of France is Paris." }
        }
      }
    }
    """
    let msg = try JSONDecoder().decode(ACPInbound.self, from: Data(json.utf8))
    guard case let .notification(method, params) = msg else {
        Issue.record("应为 notification"); return
    }
    #expect(method == "session/update")
    let update = try #require(try ACPSessionUpdate.decode(from: params))
    #expect(update.sessionUpdate == .agentMessageChunk)
    #expect(update.messageId == "msg_agent_c42b9")
    #expect(update.textContent == "The capital of France is Paris.")
}

@Test("ACPSessionUpdate: user_message_chunk 也能识别(无 text 提取则 nil)")
func sessionUpdateUserMessageChunk() throws {
    let json = """
    {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","messageId":"u","content":{"type":"text","text":"q"}}}}
    """
    let msg = try JSONDecoder().decode(ACPInbound.self, from: Data(json.utf8))
    guard case let .notification(_, params) = msg else { Issue.record("应为 notification"); return }
    let update = try #require(try ACPSessionUpdate.decode(from: params))
    #expect(update.sessionUpdate == .userMessageChunk)
    #expect(update.textContent == "q")
}

@Test("ACPSessionUpdate: agent_thought_chunk(opencode 扩展)识别为 .agentThoughtChunk + text")
func sessionUpdateThoughtChunk() throws {
    let json = """
    {"sessionId":"s","update":{"sessionUpdate":"agent_thought_chunk","messageId":"m","content":{"type":"text","text":"thinking..."}}}
    """
    let params = try #require(ACPJSON.parse(json))
    let update = try #require(try ACPSessionUpdate.decode(from: params))
    #expect(update.sessionUpdate == .agentThoughtChunk)
    #expect(update.textContent == "thinking...")
}

@Test("ACPSessionUpdate: 未知 sessionUpdate 类型不崩(向前兼容, future-proof)")
func sessionUpdateUnknownKind() throws {
    let json = """
    {"sessionId":"s","update":{"sessionUpdate":"action_log","messageId":"m","content":{"type":"text","text":"ran cmd"}}}
    """
    // 直接解 params(非 envelope)
    let params = try #require(ACPJSON.parse(json))
    let update = try #require(try ACPSessionUpdate.decode(from: params))
    #expect(update.messageId == "m")
    #expect(update.textContent == "ran cmd")
    // 未知 kind 不在 enum 内但不抛错(forward compat)
}

@Test("ACPSessionUpdate: usage_update 解码 used/size/cost(stable since 0.13.6)")
func sessionUpdateUsageWithCost() throws {
    let json = """
    {"sessionId":"s","update":{"sessionUpdate":"usage_update","used":12345,"size":200000,"cost":{"amount":0.0123,"currency":"USD"}}}
    """
    let params = try #require(ACPJSON.parse(json))
    let update = try #require(try ACPSessionUpdate.decode(from: params))
    #expect(update.sessionUpdate == .usageUpdate)
    let usage = try #require(update.usage)
    #expect(usage.used == 12_345)
    #expect(usage.size == 200_000)
    #expect(usage.cost == ACPUsage.Cost(amount: 0.0123, currency: "USD"))
    #expect(update.textContent == nil)   // usage_update 无 text
}

@Test("ACPSessionUpdate: usage_update 无 cost(可选)→ cost=nil,used/size 仍解出")
func sessionUpdateUsageWithoutCost() throws {
    let json = """
    {"sessionId":"s","update":{"sessionUpdate":"usage_update","used":42000,"size":1000000}}
    """
    let params = try #require(ACPJSON.parse(json))
    let update = try #require(try ACPSessionUpdate.decode(from: params))
    #expect(update.sessionUpdate == .usageUpdate)
    let usage = try #require(update.usage)
    #expect(usage.used == 42_000)
    #expect(usage.size == 1_000_000)
    #expect(usage.cost == nil)
}

@Test("ACPSessionUpdate: usage_update 缺 used(畸形)→ usage=nil 不崩")
func sessionUpdateUsageMalformed() throws {
    let json = """
    {"sessionId":"s","update":{"sessionUpdate":"usage_update","size":200000}}
    """
    let params = try #require(ACPJSON.parse(json))
    let update = try #require(try ACPSessionUpdate.decode(from: params))
    #expect(update.sessionUpdate == .usageUpdate)
    #expect(update.usage == nil)
}

@Test("ACPSessionUpdate: usage_update 缺 size(宽容)→ used 解出,size=nil(fallback 同形)")
func sessionUpdateUsageWithoutSize() throws {
    let json = """
    {"sessionId":"s","update":{"sessionUpdate":"usage_update","used":123}}
    """
    let params = try #require(ACPJSON.parse(json))
    let update = try #require(try ACPSessionUpdate.decode(from: params))
    let usage = try #require(update.usage)
    #expect(usage.used == 123)
    #expect(usage.size == nil)
    #expect(usage.cost == nil)
}

@Test("ACPPromptUsage: 从 PromptResponse result 解 unstable usage(明细 output/total 带上;缺 cachedReadTokens → 0)")
func promptUsageDecode() throws {
    let result = try #require(ACPJSON.parse(#"{"stopReason":"end_turn","usage":{"inputTokens":93,"cachedReadTokens":29568,"outputTokens":8,"totalTokens":29727}}"#))
    let usage = try #require(ACPPromptUsage.decode(fromResult: result))
    #expect(usage == ACPPromptUsage(inputTokens: 93, cachedReadTokens: 29_568, outputTokens: 8, totalTokens: 29_727))
    #expect(usage.contextUsed == 29_661)

    let noCache = try #require(ACPJSON.parse(#"{"usage":{"inputTokens":100}}"#))
    #expect(ACPPromptUsage.decode(fromResult: noCache) == ACPPromptUsage(inputTokens: 100, cachedReadTokens: 0))
}

@Test("ACPPromptUsage: result 无 usage / 缺 inputTokens → nil(agent 未报不崩)")
func promptUsageDecodeAbsent() throws {
    #expect(ACPPromptUsage.decode(fromResult: ACPJSON.parse(#"{"stopReason":"end_turn"}"#)) == nil)
    #expect(ACPPromptUsage.decode(fromResult: ACPJSON.parse(#"{"usage":{"outputTokens":8}}"#)) == nil)
    #expect(ACPPromptUsage.decode(fromResult: nil) == nil)
}
