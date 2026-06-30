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

    @Test("ACPAgentEngine.run: 流式 yield agent_message_chunk text delta 后 finish")
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

        // prompt 阶段的 update + result 在 engine 发 session/prompt 后异步推
        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            mock.push(updateChunk("Hello "))
            mock.push(updateChunk("world!"))
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
        #expect(deltas == ["Hello ", "world!"])
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
}
