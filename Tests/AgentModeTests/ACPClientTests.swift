import Testing
import Foundation
@testable import AgentMode

/// 测试 fixture helper:把 Encodable 编码成 JSON 字符串(构造 ACP canned 消息用)。
extension JSONEncoder {
    func encodedString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// ACPClient 流程测试:用 MockACPTransport 喂完整 initialize → session/new →
// session/update ×N → session/prompt result 序列,验证 client 的 connect/createSession/
// prompt 流程 + response 配对 + session/update 回调。

private func resp(_ id: Int, _ resultJSON: String) -> ACPInbound {
    .response(id: id, result: ACPJSON.parse(resultJSON), error: nil)
}

private func update(_ sessionUpdate: String, _ text: String) -> ACPInbound {
    let json = """
    {"sessionId":"s","update":{"sessionUpdate":"\(sessionUpdate)","messageId":"m","content":{"type":"text","text":\(JSONEncoder().encodedString(text)!)}}}
    """
    return .notification(method: "session/update", params: ACPJSON.parse(json))
}

@Test("ACPClient.connect: 发 initialize,收 protocolVersion + agentCapabilities")
func clientConnect() async throws {
    let mock = MockACPTransport([
        resp(0, #"{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}"#),
    ])
    let client = ACPClient(transport: mock)
    let caps = try await client.connect()
    #expect(caps.protocolVersion == 1)
    #expect(caps.agentCapabilities.contains("loadSession"))
    // 验证发了 initialize 请求
    let sent = (mock.sentLines.first.map { ACPJSON.parse($0) ?? .null } ?? .null)
    #expect(sent.objectValue?["method"]?.stringValue == "initialize")
}

@Test("ACPClient.connect: 解析 agentCapabilities.mcpCapabilities 里 true 的 http/sse 能力")
func clientConnectMCPCapabilities() async throws {
    let mock = MockACPTransport([
        resp(0, #"{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"http":true,"sse":false}}}"#),
    ])
    let client = ACPClient(transport: mock)
    let caps = try await client.connect()
    #expect(caps.agentCapabilities.contains("mcpCapabilities"))
    #expect(caps.mcpCapabilities == [.http])
}

@Test("ACPClient.connect: 无 mcpCapabilities 时远程 MCP 能力为空")
func clientConnectNoMCPCapabilities() async throws {
    let mock = MockACPTransport([
        resp(0, #"{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}"#),
    ])
    let client = ACPClient(transport: mock)
    #expect(try await client.connect().mcpCapabilities.isEmpty)
}

@Test("ACPClient.createSession: 发 session/new,收 sessionId")
func clientCreateSession() async throws {
    let mock = MockACPTransport([
        resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
        resp(1, #"{"sessionId":"sess_xyz"}"#),
    ])
    let client = ACPClient(transport: mock)
    _ = try await client.connect()
    let sid = try await client.createSession(cwd: "/tmp", mcpServers: [])
    #expect(sid == "sess_xyz")
    // 第二条 sent 应是 session/new
    let sentNew = (mock.sentLines.dropFirst().first.map { ACPJSON.parse($0) ?? .null } ?? .null)
    #expect(sentNew.objectValue?["method"]?.stringValue == "session/new")
}

@Test("ACPClient.prompt: 收流式 agent_message_chunk → 拼 text,prompt 返回 stopReason")
func clientPromptStream() async throws {
    let mock = MockACPTransport([
        resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
        resp(1, #"{"sessionId":"sess_xyz"}"#),
        // prompt 阶段:流式 update(两条 chunk)+ 最后 result(id=2 带 stopReason)
    ])
    let client = ACPClient(transport: mock)
    _ = try await client.connect()
    _ = try await client.createSession(cwd: "/tmp", mcpServers: [])

    // update + prompt result 在 prompt 调用后异步推(MCP server 在收到 session/prompt 后)
    // 这里用 mock 的 push 模拟 agent 流式回:
    Task {
        try? await Task.sleep(nanoseconds: 50_000_000)
        mock.push(update("agent_message_chunk", "Hello "))
        mock.push(update("agent_message_chunk", "world!"))
        mock.push(resp(2, #"{"stopReason":"end_turn"}"#))
    }

    var chunks: [String] = []
    let result = try await client.prompt(text: "hi") { update in
        if let t = update.textContent { chunks.append(t) }
    }
    #expect(chunks == ["Hello ", "world!"])
    #expect(result.stopReason == "end_turn")
    #expect(result.usage == nil)   // 响应无 unstable usage(agent 未报)→ nil 不崩
}

@Test("ACPClient.prompt: 响应带 unstable usage(opencode 1.18 实测口径)→ 解出 input/cacheRead,contextUsed = 两者之和")
func clientPromptResponseUsage() async throws {
    let mock = MockACPTransport([
        resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
        resp(1, #"{"sessionId":"sess_xyz"}"#),
    ])
    let client = ACPClient(transport: mock)
    _ = try await client.connect()
    _ = try await client.createSession(cwd: "/tmp", mcpServers: [])

    Task {
        try? await Task.sleep(nanoseconds: 50_000_000)
        mock.push(resp(2, #"{"stopReason":"end_turn","usage":{"inputTokens":93,"outputTokens":8,"cachedReadTokens":29568,"thoughtTokens":58,"totalTokens":29727}}"#))
    }

    let result = try await client.prompt(text: "hi") { _ in }
    #expect(result.stopReason == "end_turn")
    #expect(result.usage == ACPPromptUsage(inputTokens: 93, cachedReadTokens: 29_568))
    #expect(result.usage?.contextUsed == 29_661)
}

@Test("ACPClient: response error 透传")
func clientResponseError() async throws {
    let mock = MockACPTransport([
        .response(id: 0, result: nil, error: .init(code: -32601, message: "nope", data: nil)),
    ])
    let client = ACPClient(transport: mock)
    await #expect(throws: ACPClientError.self) {
        _ = try await client.connect()
    }
}

@Test("ACPClient: transport EOF → pending request 唤醒 throwing(免永挂,task6/7 健壮性)")
func clientEOFWakesPending() async throws {
    let mock = MockACPTransport([
        resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
        resp(1, #"{"sessionId":"sess_eof"}"#),
    ])
    let client = ACPClient(transport: mock)
    _ = try await client.connect()
    _ = try await client.createSession(cwd: "/tmp", mcpServers: [])

    // prompt 发出后不推 result,模拟 agent 进程死 → onEOF → client 唤醒 pending
    Task {
        try? await Task.sleep(nanoseconds: 50_000_000)
        mock.simulateEOF()
    }

    await #expect(throws: ACPClientError.self) {
        _ = try await client.prompt(text: "hi") { _ in }
    }
}

@Test("ACPClient: session/request_permission → 调 onPermissionRequest 回调 → 回 outcome(ACP-2)")
func clientPermissionRequest() async throws {
    let mock = MockACPTransport([
        resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
        resp(1, #"{"sessionId":"s"}"#),
    ])
    let client = ACPClient(transport: mock)
    // 注入回调:收权限请求 → 用户选 allow-once
    var capturedReq: ACPPermissionRequest?
    await client.setOnPermissionRequest { req in
        capturedReq = req
        return .selected(optionId: "allow-once")
    }
    _ = try await client.connect()
    _ = try await client.createSession(cwd: "/tmp", mcpServers: [])

    // 模拟 agent 发 session/request_permission(id=5)
    let permJSON = #"{"sessionId":"s","toolCall":{"toolCallId":"c1","title":"Write file","kind":"edit"},"options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}"#
    mock.push(.request(id: 5, method: "session/request_permission", params: ACPJSON.parse(permJSON)))

    // 给 actor 处理时间
    try? await Task.sleep(nanoseconds: 80_000_000)

    // 回调被调 + sentLines 含 outcome selected allow-once
    #expect(capturedReq?.toolCallId == "c1")
    #expect(capturedReq?.title == "Write file")
    #expect(capturedReq?.kind == "edit")
    let outcomeSent = mock.sentLines.last ?? ""
    #expect(outcomeSent.contains("\"optionId\":\"allow-once\""))
    #expect(outcomeSent.contains("\"id\":5"))
}

@Test("ACPClient: session/request_permission 无回调 → 安全默认 reject_once(生产安全)")
func clientPermissionDefaultReject() async throws {
    let mock = MockACPTransport([
        resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
        resp(1, #"{"sessionId":"s"}"#),
    ])
    let client = ACPClient(transport: mock)   // 无 onPermissionRequest
    _ = try await client.connect()
    _ = try await client.createSession(cwd: "/tmp", mcpServers: [])

    let permJSON = #"{"sessionId":"s","toolCall":{"toolCallId":"c1","kind":"edit"},"options":[{"optionId":"allow-once","name":"Allow","kind":"allow_once"},{"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}"#
    mock.push(.request(id: 7, method: "session/request_permission", params: ACPJSON.parse(permJSON)))
    try? await Task.sleep(nanoseconds: 80_000_000)

    let outcomeSent = mock.sentLines.last ?? ""
    #expect(outcomeSent.contains("\"optionId\":\"reject-once\""), "无 UI 回调 → 安全默认 reject_once")
}

@Test("ACPClient: connect 阶段 EOF → initialize 唤醒 throwing(免初始化永挂)")
func clientEOFDuringConnect() async throws {
    // initialize 发出后不回 response,模拟 agent 立即崩 → onEOF
    let mock = MockACPTransport([])
    let client = ACPClient(transport: mock)
    Task {
        try? await Task.sleep(nanoseconds: 50_000_000)
        mock.simulateEOF()
    }
    await #expect(throws: ACPClientError.self) {
        _ = try await client.connect()
    }
}
