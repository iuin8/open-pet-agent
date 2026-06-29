import Testing
@testable import AgentMode

@Test("StubClaudeCodeEngine.kind 是 claudeCode")
func stubClaudeCodeEngineKindIsClaudeCode() {
    #expect(StubClaudeCodeEngine.kind == .claudeCode)
}

@Test("StubClaudeCodeEngine 永远可用")
func stubClaudeCodeEngineIsAlwaysAvailable() async {
    let engine = StubClaudeCodeEngine()
    #expect(await engine.isAvailable == true)
}

@Test("StubClaudeCodeEngine run yield 占位文案后 finish")
func stubClaudeCodeEngineRunYieldsPlaceholderThenFinishes() async throws {
    let engine = StubClaudeCodeEngine()
    let stream = engine.run(prompt: "请帮我修一下登录 bug")

    var collected: [String] = []
    for try await chunk in stream {
        collected.append(chunk)
    }

    #expect(collected.count == 2)
    let joined = collected.joined()
    #expect(joined.contains("未接入"))
    #expect(joined.contains("请帮我修一下登录 bug"))
}

@Test("StubClaudeCodeEngine 截断超长 prompt 到 100 字符")
func stubClaudeCodeEngineTruncatesLongPrompt() async throws {
    let engine = StubClaudeCodeEngine()
    let longPrompt = String(repeating: "x", count: 500)
    let stream = engine.run(prompt: longPrompt)

    var joined = ""
    for try await chunk in stream {
        joined += chunk
    }

    // prompt 部分应该被截断 —— 全文 500 个 x 不该完整出现
    #expect(!joined.contains(String(repeating: "x", count: 500)))
    // 但至少 100 个 x 该在
    #expect(joined.contains(String(repeating: "x", count: 100)))
}
