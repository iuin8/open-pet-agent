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
