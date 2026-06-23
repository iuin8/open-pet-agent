import Testing
import AgentSensing
@testable import Shell

@Suite("SessionResumeCommand — 终端续聊命令")
struct SessionResumeCommandTests {
    @Test("Claude → claude --resume <id>")
    func claudeForm() {
        #expect(SessionResumeCommand.command(agent: .claudeCode, sessionId: "abc123")
                == "claude --resume abc123")
    }

    @Test("Codex → codex resume <id>(交互形态,非 exec)")
    func codexForm() {
        #expect(SessionResumeCommand.command(agent: .codex, sessionId: "xyz789")
                == "codex resume xyz789")
    }
}
