import Testing
import Foundation
@testable import AgentMode

// ACPAgentEngine 端到端测试:注入 MockACPTransport,run(prompt) → 流式 yield text delta → finish。
// 验证「一套 ACP 协议接 agent」成立(engine 把 ACP client 包成 AgentEngine delta 流)。

@Suite("ACPAgentEngine")
struct ACPAgentEngineTests {

    private func resp(_ id: Int, _ resultJSON: String) -> ACPInbound {
        .response(id: id, result: ACPJSON.parse(resultJSON), error: nil)
    }

    private func updateChunk(_ text: String) -> ACPInbound {
        let json = """
        {"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":\(JSONEncoder().encodedString(text)!)}}}
        """
        return .notification(method: "session/update", params: ACPJSON.parse(json))
    }

    /// thought chunk(opencode/deepseek 扩展,思考流)—— engine 应**不** yield。
    private func thoughtChunk(_ text: String) -> ACPInbound {
        let json = """
        {"sessionId":"s","update":{"sessionUpdate":"agent_thought_chunk","messageId":"m","content":{"type":"text","text":\(JSONEncoder().encodedString(text)!)}}}
        """
        return .notification(method: "session/update", params: ACPJSON.parse(json))
    }

    /// usage_update(agent 每轮后推的上下文用量)—— engine 应**不** yield,走 onUsage。
    private func usageUpdate(used: Int, size: Int, costJSON: String? = nil) -> ACPInbound {
        let costField = costJSON.map { #","cost":"# + $0 } ?? ""
        let json = """
        {"sessionId":"s","update":{"sessionUpdate":"usage_update","used":\(used),"size":\(size)\(costField)}}
        """
        return .notification(method: "session/update", params: ACPJSON.parse(json))
    }

    /// session/load 回放 chunk(指定 kind + messageId,聚合语义的最小单元)。
    private func replayChunk(_ kind: String, mid: String, _ text: String) -> ACPInbound {
        let json = """
        {"sessionId":"s","update":{"sessionUpdate":"\(kind)","messageId":"\(mid)","content":{"type":"text","text":\(JSONEncoder().encodedString(text)!)}}}
        """
        return .notification(method: "session/update", params: ACPJSON.parse(json))
    }

    @Test("ACPAgentEngine.run: 只 yield agent_message_chunk(thought_chunk 不 yield,免 pet 显示思考碎片)")
    func runYieldsDeltas() async throws {
        // send-driven 预置(mock 每次 send 取「到下一个 response 含」组):
        // initialize(0) → session(1) → [thought(不 yield) + 2 message(yield) + prompt result(2)]。
        // 全预置取代旧 `Task.sleep(80ms) + push` —— 后者在 --parallel 全套并发下 Task 调度
        // 被抢占,偶发超 prompt 180s timeout 假红(并发 flaky,非 engine 回归)。
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            thoughtChunk("The user wants a greeting"),
            updateChunk("你好"),
            updateChunk("！"),
            resp(2, #"{"stopReason":"end_turn"}"#),
        ])
        let engine = ACPAgentEngine(
            command: ["fake", "acp"],
            binaryPath: "/usr/bin/true",
            transportFactory: { mock }
        )

        var deltas: [String] = []
        for try await delta in engine.run(prompt: "hi") {
            deltas.append(delta)
        }
        #expect(deltas == ["你好", "！"])
    }

    @Test("ACPAgentEngine.onThought: thought_chunk → onThought 回调(不 yield)")
    func thoughtChunkTriggersOnThought() async throws {
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            thoughtChunk("The user wants a greeting"),
            updateChunk("你好"),
            resp(2, #"{"stopReason":"end_turn"}"#),
        ])
        let engine = ACPAgentEngine(
            command: ["fake", "acp"],
            binaryPath: "/usr/bin/true",
            transportFactory: { mock }
        )
        var thoughts: [String] = []
        engine.onThought = { thoughts.append($0) }

        var deltas: [String] = []
        for try await delta in engine.run(prompt: "hi") {
            deltas.append(delta)
        }
        #expect(deltas == ["你好"])  // thought 不 yield(只 message)
        #expect(thoughts == ["The user wants a greeting"])  // thought → onThought 回调
    }

    @Test("ACPAgentEngine: isAvailable=true 当 binaryPath 存在")
    func availableWhenBinaryExists() async {
        let engine = ACPAgentEngine(
            command: ["true"],
            binaryPath: "/usr/bin/true",
            transportFactory: { MockACPTransport([]) }
        )
        let avail = await engine.isAvailable
        #expect(avail == true)
    }

    @Test("ACPAgentEngine: kind = .openCode")
    func kindIsOpenCode() {
        #expect(ACPAgentEngine.kind == .openCode)
    }

    @Test("ACPAgentEngine: connection + session 复用 —— 第二轮不重发 initialize / session/new,同一 sessionId 跑两轮 prompt(上下文连贯)")
    func connectionReusedAcrossRuns() async throws {
        // mock queue 按 send 顺序预置(send-driven 每次 send 取「到下一个 response 含」组):
        // initialize(0) → session_1(1) → [update "第一回" + prompt1 result(2)] →
        // prompt2(3,**无 session/new**,复用 sess_1)→ [update "第二回" + prompt2 result(3)]
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            updateChunk("第一回"),
            resp(2, #"{"stopReason":"end_turn"}"#),
            updateChunk("第二回"),
            resp(3, #"{"stopReason":"end_turn"}"#),
        ])
        let engine = ACPAgentEngine(
            command: ["fake", "acp"],
            binaryPath: "/usr/bin/true",
            transportFactory: { mock }
        )

        var first: [String] = []
        for try await d in engine.run(prompt: "a") { first.append(d) }

        var second: [String] = []
        for try await d in engine.run(prompt: "b") { second.append(d) }

        // initialize 与 session/new 各只发一次(第二轮复用 connection + session)
        let initCount = mock.sentLines.filter { $0.contains("\"initialize\"") }.count
        #expect(initCount == 1, "第二轮应复用 connection,不重发 initialize(实际 \(initCount))")
        // 按解析后的 method 计(原样字符串匹配会被 JSONEncoder 的 `\/` 转义坑:`"session\/new"`)
        let sessionNewCount = mock.sentLines
            .compactMap { ACPJSON.parse($0)?.objectValue }
            .filter { $0["method"]?.stringValue == "session/new" }
            .count
        #expect(sessionNewCount == 1, "第二轮应复用 session,不重发 session/new(实际 \(sessionNewCount))")
        // 两轮 prompt 携带同一 sessionId
        let promptSessionIds = mock.sentLines
            .compactMap { ACPJSON.parse($0)?.objectValue }
            .filter { $0["method"]?.stringValue == "session/prompt" }
            .map { $0["params"]?.objectValue?["sessionId"]?.stringValue }
        #expect(promptSessionIds == ["sess_1", "sess_1"])
        #expect(first == ["第一回"])
        #expect(second == ["第二回"])
    }

    @Test("ACPAgentEngine: run 出错 → 清 client + 缓存 session,下次 run 重 initialize + 新 session/new")
    func resetClearsCachedSession() async throws {
        // run1 正常 → run2 prompt 返回 error(engine 清 client + session)→
        // run3 新 client(request id 从 0 重计)重 initialize + 新 session。
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            updateChunk("第一回"),
            resp(2, #"{"stopReason":"end_turn"}"#),
            .response(id: 3, result: nil, error: ACPRPCError(code: -32603, message: "boom", data: nil)),
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_2"}"#),
            updateChunk("第三回"),
            resp(2, #"{"stopReason":"end_turn"}"#),
        ])
        let engine = ACPAgentEngine(
            command: ["fake", "acp"],
            binaryPath: "/usr/bin/true",
            transportFactory: { mock }
        )

        var first: [String] = []
        for try await d in engine.run(prompt: "a") { first.append(d) }
        #expect(first == ["第一回"])

        var threw = false
        do {
            for try await _ in engine.run(prompt: "b") {}
        } catch {
            threw = true
        }
        #expect(threw, "prompt error 应抛错触发 reset")

        var third: [String] = []
        for try await d in engine.run(prompt: "c") { third.append(d) }
        #expect(third == ["第三回"])

        let initCount = mock.sentLines.filter { $0.contains("\"initialize\"") }.count
        #expect(initCount == 2, "reset 后应重 initialize(实际 \(initCount))")
        let sessionNewCount = mock.sentLines
            .compactMap { ACPJSON.parse($0)?.objectValue }
            .filter { $0["method"]?.stringValue == "session/new" }
            .count
        #expect(sessionNewCount == 2, "reset 后应重开 session(实际 \(sessionNewCount))")
        let promptSessionIds = mock.sentLines
            .compactMap { ACPJSON.parse($0)?.objectValue }
            .filter { $0["method"]?.stringValue == "session/prompt" }
            .map { $0["params"]?.objectValue?["sessionId"]?.stringValue }
        #expect(promptSessionIds == ["sess_1", "sess_1", "sess_2"])
    }

    @Test("ACPAgentEngine.onUsage: usage_update → onUsage 回调带 used/size/cost(不 yield)")
    func usageUpdateTriggersOnUsage() async throws {
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            usageUpdate(used: 12_345, size: 200_000, costJSON: #"{"amount":0.0123,"currency":"USD"}"#),
            updateChunk("你好"),
            resp(2, #"{"stopReason":"end_turn"}"#),
        ])
        let engine = ACPAgentEngine(
            command: ["fake", "acp"],
            binaryPath: "/usr/bin/true",
            transportFactory: { mock }
        )
        var usages: [ACPUsage] = []
        engine.onUsage = { usages.append($0) }

        var deltas: [String] = []
        for try await d in engine.run(prompt: "hi") { deltas.append(d) }

        #expect(deltas == ["你好"])   // usage 不 yield(只 message)
        #expect(usages == [ACPUsage(used: 12_345, size: 200_000, cost: .init(amount: 0.0123, currency: "USD"))])
    }

    @Test("ACPAgentEngine.onUsage fallback: 无 usage_update 但响应带 unstable usage(opencode 1.18 口径)→ 合成 used=input+cacheRead,size=nil,prompt 明细附上")
    func usageFallbackFromPromptResponse() async throws {
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            updateChunk("你好"),
            resp(2, #"{"stopReason":"end_turn","usage":{"inputTokens":2034,"cachedReadTokens":27520,"outputTokens":49,"totalTokens":29630}}"#),
        ])
        let engine = ACPAgentEngine(
            command: ["fake", "acp"],
            binaryPath: "/usr/bin/true",
            transportFactory: { mock }
        )
        var usages: [ACPUsage] = []
        engine.onUsage = { usages.append($0) }

        var deltas: [String] = []
        for try await d in engine.run(prompt: "hi") { deltas.append(d) }

        #expect(deltas == ["你好"])
        #expect(usages == [ACPUsage(
            used: 29_554, size: nil, cost: nil,
            prompt: ACPPromptUsage(inputTokens: 2_034, cachedReadTokens: 27_520, outputTokens: 49, totalTokens: 29_630)
        )])
    }

    @Test("ACPAgentEngine.onUsage: 已收 usage_update → 响应 usage 仅补 prompt 明细(used/size/cost 不变,幂等不重复计数)")
    func promptResponseUsageOnlyAddsDetail() async throws {
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            usageUpdate(used: 29_661, size: 200_000),
            updateChunk("你好"),
            resp(2, #"{"stopReason":"end_turn","usage":{"inputTokens":93,"cachedReadTokens":29568,"totalTokens":29727}}"#),
        ])
        let engine = ACPAgentEngine(
            command: ["fake", "acp"],
            binaryPath: "/usr/bin/true",
            transportFactory: { mock }
        )
        var usages: [ACPUsage] = []
        engine.onUsage = { usages.append($0) }

        var deltas: [String] = []
        for try await d in engine.run(prompt: "hi") { deltas.append(d) }

        #expect(deltas == ["你好"])
        #expect(usages.count == 2)
        #expect(usages[0] == ACPUsage(used: 29_661, size: 200_000))                    // usage_update 精确值
        #expect(usages[1].used == 29_661 && usages[1].size == 200_000)               // 合并后数值不变
        #expect(usages[1].prompt == ACPPromptUsage(inputTokens: 93, cachedReadTokens: 29_568, totalTokens: 29_727))
    }

    // MARK: - P2 会话管理(list / load / new)

    private func makeEngine(_ mock: MockACPTransport) -> ACPAgentEngine {
        ACPAgentEngine(command: ["fake", "acp"], binaryPath: "/usr/bin/true", transportFactory: { mock })
    }

    /// 按解析后 method 统计请求数(JSONEncoder 会转义 `/`,裸字符串匹配翻车,lessons §2.7)。
    private func sentCount(_ mock: MockACPTransport, method: String) -> Int {
        mock.sentLines
            .compactMap { ACPJSON.parse($0)?.objectValue }
            .filter { $0["method"]?.stringValue == method }
            .count
    }

    @Test("ACPAgentEngine.listSessions: 跟随 nextCursor 翻页聚合(上限 5 页内)")
    func listSessionsPaginates() async throws {
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessions":[{"sessionId":"s1","cwd":"/tmp","title":"修 bug"}],"nextCursor":"c2"}"#),
            resp(2, #"{"sessions":[{"sessionId":"s2","cwd":"/tmp"}]}"#),
        ])
        let engine = makeEngine(mock)

        let sessions = try await engine.listSessions()

        #expect(sessions.map(\.sessionId) == ["s1", "s2"])
        #expect(sessions[0].title == "修 bug")
        let listSends = mock.sentLines
            .compactMap { ACPJSON.parse($0)?.objectValue }
            .filter { $0["method"]?.stringValue == "session/list" }
        #expect(listSends.count == 2)
        #expect(listSends[1]["params"]?.objectValue?["cursor"]?.stringValue == "c2")
    }

    @Test("ACPAgentEngine.loadSession: 回放按 messageId 聚合成整消息,置为当前 session,usage 走 onUsage,onSessionIdChanged 触发")
    func loadSessionReplaysTurns() async throws {
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}"#),
            replayChunk("user_message_chunk", mid: "m1", "你"),
            replayChunk("user_message_chunk", mid: "m1", "好"),
            replayChunk("agent_message_chunk", mid: "m2", "你好呀"),
            usageUpdate(used: 100, size: 200_000),
            resp(1, #"{}"#),
        ])
        let engine = makeEngine(mock)
        var usages: [ACPUsage] = []
        engine.onUsage = { usages.append($0) }
        var sids: [String] = []
        engine.onSessionIdChanged = { sids.append($0) }

        let turns = try await engine.loadSession("sess_old")

        #expect(turns == [
            ACPReplayedTurn(role: .user, text: "你好"),          // m1 两 chunk 合并
            ACPReplayedTurn(role: .assistant, text: "你好呀"),
        ])
        #expect(engine.currentSessionId == "sess_old")
        #expect(sids == ["sess_old"])
        #expect(usages == [ACPUsage(used: 100, size: 200_000)])
    }

    @Test("ACPAgentEngine.newSession: 立即 session/new 置当前 + 回调,后续 run 复用不再建")
    func newSessionCreatesAndReuses() async throws {
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_new"}"#),
            updateChunk("好"),
            resp(2, #"{"stopReason":"end_turn"}"#),
        ])
        let engine = makeEngine(mock)
        var sids: [String] = []
        engine.onSessionIdChanged = { sids.append($0) }

        let sid = try await engine.newSession()
        #expect(sid == "sess_new")
        #expect(engine.currentSessionId == "sess_new")

        var deltas: [String] = []
        for try await d in engine.run(prompt: "hi") { deltas.append(d) }
        #expect(deltas == ["好"])
        #expect(sentCount(mock, method: "session/new") == 1)   // 仅 newSession 那次
        #expect(sids == ["sess_new"])                          // 回调只触发一次
    }

    @Test("ACPAgentEngine: 首个 run 建 session 也触发 onSessionIdChanged(P2 指针持久化起点)")
    func firstRunNotifiesSessionId() async throws {
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            updateChunk("好"),
            resp(2, #"{"stopReason":"end_turn"}"#),
        ])
        let engine = makeEngine(mock)
        var sids: [String] = []
        engine.onSessionIdChanged = { sids.append($0) }

        for try await _ in engine.run(prompt: "hi") {}

        #expect(sids == ["sess_1"])
        #expect(engine.currentSessionId == "sess_1")
        #expect(engine.agentCapabilities?.protocolVersion == 1)
    }

    @Test("ACPAgentEngine.run: forwards injected mcpServers to session/new")
    func forwardsInjectedMCPServers() async throws {
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            updateChunk("ok"),
            resp(2, #"{"stopReason":"end_turn"}"#),
        ])
        let server = ACPJSON.parse(#"{"type":"local","command":["npx","-y","server"]}"#)!
        let engine = ACPAgentEngine(
            command: ["fake", "acp"],
            binaryPath: "/usr/bin/true",
            mcpServersProvider: { _ in [server] },
            transportFactory: { mock }
        )

        var deltas: [String] = []
        for try await delta in engine.run(prompt: "hi") { deltas.append(delta) }

        let sessionNew = mock.sentLines
            .compactMap { ACPJSON.parse($0)?.objectValue }
            .first { $0["method"]?.stringValue == "session/new" }
        let mcpServers = sessionNew?["params"]?.objectValue?["mcpServers"]?.arrayValue ?? []
        #expect(mcpServers.contains(server))
        #expect(deltas == ["ok"])
    }

    @Test("ACPAgentEngine.run: provider 收到 initialize 协商出的 mcpCapabilities")
    func providerReceivesNegotiatedCapabilities() async throws {
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"http":true}}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            updateChunk("ok"),
            resp(2, #"{"stopReason":"end_turn"}"#),
        ])
        final class CapsBox: @unchecked Sendable { var caps: ACPAgentCapabilities? }
        let box = CapsBox()
        let engine = ACPAgentEngine(
            command: ["fake", "acp"],
            binaryPath: "/usr/bin/true",
            mcpServersProvider: { caps in box.caps = caps; return [] },
            transportFactory: { mock }
        )

        for try await _ in engine.run(prompt: "hi") {}

        #expect(box.caps?.mcpCapabilities == [.http])
    }
}
