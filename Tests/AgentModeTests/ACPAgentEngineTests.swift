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

    @Test("ACPAgentEngine.run: 只 yield agent_message_chunk(thought_chunk 不 yield,免 pet 显示思考碎片)")
    func runYieldsDeltas() async throws {
        let canned: [ACPInbound] = [
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
        ]
        let mock = MockACPTransport(canned)
        let engine = ACPAgentEngine(
            command: ["fake", "acp"],
            binaryPath: "/usr/bin/true",
            transportFactory: { mock }
        )

        // prompt 阶段:thought(不应 yield)+ 两个 message chunk(应 yield)+ result
        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            mock.push(thoughtChunk("The user wants a greeting"))
            mock.push(updateChunk("你好"))
            mock.push(updateChunk("！"))
            mock.push(resp(2, #"{"stopReason":"end_turn"}"#))
        }

        var deltas: [String] = []
        do {
            for try await delta in engine.run(prompt: "hi") {
                deltas.append(delta)
            }
        } catch {
            Issue.record("engine.run 不应抛错: \(error)")
        }
        #expect(deltas == ["你好", "！"])
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

    @Test("ACPAgentEngine: connection 复用 —— 第二次 run 不重发 initialize(生产级性能)")
    func connectionReusedAcrossRuns() async throws {
        // mock queue 按 send 顺序预置(send-driven 每次 send 取「到下一个 response 含」组):
        // initialize(0) → session_1(1) → [update "第一回" + prompt1 result(2)] →
        // session_2(3) → [update "第二回" + prompt2 result(4)]
        let mock = MockACPTransport([
            resp(0, #"{"protocolVersion":1,"agentCapabilities":{}}"#),
            resp(1, #"{"sessionId":"sess_1"}"#),
            updateChunk("第一回"),
            resp(2, #"{"stopReason":"end_turn"}"#),
            resp(3, #"{"sessionId":"sess_2"}"#),
            updateChunk("第二回"),
            resp(4, #"{"stopReason":"end_turn"}"#),
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

        // sentLines 含 initialize method 次数应 = 1(第二轮复用 connection,不重发)
        let initCount = mock.sentLines.filter { $0.contains("\"initialize\"") }.count
        #expect(initCount == 1, "第二轮应复用 connection,不重发 initialize(实际 \(initCount))")
        #expect(first == ["第一回"])
        #expect(second == ["第二回"])
    }
}
