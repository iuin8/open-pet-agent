import Foundation
import Testing
@testable import ToolMode

// MARK: - 测试辅助

/// 在 tmp 目录写一个可执行的 shell 脚本, 内容为 `codex exec --json` CLI
/// 的 JSONL stdout 模拟器。返回 binary 路径供 `CodexEngine(binaryPath:)`
/// 注入。
///
/// `body` 不带 shebang, 函数自己加 `#!/bin/bash`。
///
/// 注意:这跟 ClaudeCodeEngineTests 的 `makeStubScript` 同形,刻意各自留
/// 一份是为了让两个 suite 完全解耦 —— 测试 fixture 互不依赖,改其中一份
/// 不会意外影响另一份。
private func makeCodexStubScript(body: String) throws -> URL {
    let tmpDir = FileManager.default.temporaryDirectory
    let url = tmpDir.appendingPathComponent(
        "petagent-test-codex-stub-\(UUID().uuidString).sh"
    )
    let full = "#!/bin/bash\nset -e\n" + body + "\n"
    try full.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
    return url
}

// MARK: - parseAgentMessage 纯函数测试 (无子进程)

@Test("parseAgentMessage 提取 item.completed agent_message 的 text")
func parseAgentMessageHappyPath() {
    let line = #"{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}"#
    #expect(CodexEngine.parseAgentMessage(line) == "hi")
}

@Test("parseAgentMessage 多字段 item 也能提取 text")
func parseAgentMessageWithExtraFields() {
    let line = #"{"type":"item.completed","item":{"id":"xyz","type":"agent_message","text":"hello world","extra":42}}"#
    #expect(CodexEngine.parseAgentMessage(line) == "hello world")
}

@Test("parseAgentMessage item.type 非 agent_message 返回 nil")
func parseAgentMessageNonAgentItem() {
    // codex 常见的非 agent item: command_execution / reasoning / file_change
    let cmd = #"{"type":"item.completed","item":{"type":"command_execution","command":"ls"}}"#
    #expect(CodexEngine.parseAgentMessage(cmd) == nil)
    let reasoning = #"{"type":"item.completed","item":{"type":"reasoning","text":"thinking"}}"#
    #expect(CodexEngine.parseAgentMessage(reasoning) == nil)
}

@Test("parseAgentMessage 非 item.completed 事件返回 nil")
func parseAgentMessageNonItemCompletedType() {
    let started = #"{"type":"thread.started","thread_id":"abc"}"#
    #expect(CodexEngine.parseAgentMessage(started) == nil)
    let itemStarted = #"{"type":"item.started","item":{"type":"agent_message"}}"#
    #expect(CodexEngine.parseAgentMessage(itemStarted) == nil)
    let turnDone = #"{"type":"turn.completed"}"#
    #expect(CodexEngine.parseAgentMessage(turnDone) == nil)
}

@Test("parseAgentMessage 空 text 返回 nil")
func parseAgentMessageEmptyText() {
    let line = #"{"type":"item.completed","item":{"type":"agent_message","text":""}}"#
    #expect(CodexEngine.parseAgentMessage(line) == nil)
}

@Test("parseAgentMessage 缺 item / 缺 text 返回 nil 不崩")
func parseAgentMessageMissingFields() {
    let missingItem = #"{"type":"item.completed"}"#
    #expect(CodexEngine.parseAgentMessage(missingItem) == nil)
    let missingText = #"{"type":"item.completed","item":{"type":"agent_message"}}"#
    #expect(CodexEngine.parseAgentMessage(missingText) == nil)
}

@Test("parseAgentMessage 坏 JSON 返回 nil 不崩")
func parseAgentMessageBadJson() {
    #expect(CodexEngine.parseAgentMessage("not json") == nil)
    #expect(CodexEngine.parseAgentMessage("") == nil)
    #expect(CodexEngine.parseAgentMessage("{") == nil)
    #expect(CodexEngine.parseAgentMessage("{\"type\":\"item.completed\"") == nil)
}

// MARK: - parseErrorEvent 纯函数测试

@Test("parseErrorEvent 提取 error message")
func parseErrorEventHappyPath() {
    let line = #"{"type":"error","message":"模型超时"}"#
    #expect(CodexEngine.parseErrorEvent(line) == "模型超时")
}

@Test("parseErrorEvent 缺 message 字段返回 nil(不当错误,留给 exit code 判断)")
func parseErrorEventMissingMessage() {
    let line = #"{"type":"error"}"#
    #expect(CodexEngine.parseErrorEvent(line) == nil)
}

@Test("parseErrorEvent 非 error 行返回 nil")
func parseErrorEventNonError() {
    let line = #"{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}"#
    #expect(CodexEngine.parseErrorEvent(line) == nil)
}

@Test("parseErrorEvent 坏 JSON 返回 nil")
func parseErrorEventBadJson() {
    #expect(CodexEngine.parseErrorEvent("not json") == nil)
    #expect(CodexEngine.parseErrorEvent("") == nil)
}

// MARK: - isTurnCompleted 纯函数测试

@Test("isTurnCompleted 正确识别 turn.completed")
func isTurnCompletedHappyPath() {
    #expect(CodexEngine.isTurnCompleted(#"{"type":"turn.completed"}"#) == true)
    #expect(CodexEngine.isTurnCompleted(#"{"type":"turn.completed","usage":{"tokens":42}}"#) == true)
}

@Test("isTurnCompleted 非 turn.completed 返回 false")
func isTurnCompletedRejectsOthers() {
    #expect(CodexEngine.isTurnCompleted(#"{"type":"turn.started"}"#) == false)
    #expect(CodexEngine.isTurnCompleted(#"{"type":"item.completed","item":{"type":"agent_message"}}"#) == false)
    #expect(CodexEngine.isTurnCompleted("not json") == false)
}

// MARK: - CodexEngine 元数据

@Test("CodexEngine.kind 是 .codex")
func codexEngineKind() {
    #expect(CodexEngine.kind == .codex)
}

@Test("CodexEngine isAvailable: 注入的 binaryPath 可执行 → true")
func codexIsAvailableWithExecutableBinary() async throws {
    let stub = try makeCodexStubScript(body: "echo hi")
    let engine = CodexEngine(binaryPath: stub.path)
    #expect(await engine.isAvailable == true)
    try? FileManager.default.removeItem(at: stub)
}

@Test("CodexEngine isAvailable: 注入的 binaryPath 不存在 → false")
func codexIsAvailableWithMissingBinary() async {
    let engine = CodexEngine(
        binaryPath: "/tmp/petagent-codex-definitely-not-there-\(UUID().uuidString)"
    )
    #expect(await engine.isAvailable == false)
}

// MARK: - run(prompt:) 子进程集成测试

@Test("run yields 所有 agent_message 文本", .enabled(if: subprocessTestsEnabled))
func codexRunYieldsAgentMessages() async throws {
    // 模拟真实 codex JSONL 输出顺序:
    //   thread.started → turn.started → item.completed(agent_message) × N → turn.completed
    let stub = try makeCodexStubScript(body: """
        echo '{"type":"thread.started","thread_id":"abc"}'
        echo '{"type":"turn.started"}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":" world"}}'
        echo '{"type":"turn.completed"}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = CodexEngine(binaryPath: stub.path)
    var collected = ""
    for try await delta in engine.run(prompt: "test") {
        collected += delta
    }
    // 多段 agent_message 之间插 "\n\n" 拼接
    #expect(collected.contains("hello"))
    #expect(collected.contains(" world"))
    #expect(collected.contains("\n\n"))
}

@Test("run 静默跳过非 agent_message 事件,只 yield agent_message", .enabled(if: subprocessTestsEnabled))
func codexRunSkipsNonAgentMessageEvents() async throws {
    let stub = try makeCodexStubScript(body: """
        echo '{"type":"thread.started","thread_id":"abc"}'
        echo '{"type":"item.started","item":{"type":"command_execution","command":"ls"}}'
        echo '{"type":"item.completed","item":{"type":"command_execution","command":"ls","exit_code":0}}'
        echo '{"type":"item.completed","item":{"type":"reasoning","text":"thinking..."}}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"final answer"}}'
        echo '{"type":"turn.completed"}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = CodexEngine(binaryPath: stub.path)
    var collected = ""
    for try await delta in engine.run(prompt: "test") {
        collected += delta
    }
    #expect(collected == "final answer")
    // 不应包含 thinking 或 ls(工具事件)
    #expect(!collected.contains("thinking"))
    #expect(!collected.contains("ls"))
}

@Test("run 非 zero exit code 抛 subprocessFailed", .enabled(if: subprocessTestsEnabled))
func codexRunFailedExitThrowsSubprocessFailed() async throws {
    let stub = try makeCodexStubScript(body: """
        echo "codex fatal stderr" >&2
        exit 7
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = CodexEngine(binaryPath: stub.path)
    do {
        for try await _ in engine.run(prompt: "test") {}
        Issue.record("expected subprocessFailed but stream ended cleanly")
    } catch let ToolEngineError.subprocessFailed(code, stderr) {
        #expect(code == 7)
        #expect(stderr.contains("codex fatal stderr"))
    } catch {
        Issue.record("expected ToolEngineError.subprocessFailed, got: \(error)")
    }
}

@Test("run stderr 有内容但 exit 0 视为正常 — 不抛(codex 启动时常打 ERROR 日志)", .enabled(if: subprocessTestsEnabled))
func codexRunStderrWithExitZeroIsOk() async throws {
    // 模拟 codex 0.130.0 启动时打 ERROR 到 stderr 但 exit 0 的真实场景
    let stub = try makeCodexStubScript(body: """
        echo "ERROR token refresh failed" >&2
        echo "ERROR failed to load skill xyz" >&2
        echo '{"type":"thread.started","thread_id":"abc"}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"survived"}}'
        echo '{"type":"turn.completed"}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = CodexEngine(binaryPath: stub.path)
    var collected = ""
    for try await delta in engine.run(prompt: "test") {
        collected += delta
    }
    #expect(collected.contains("survived"))
}

@Test("run 忽略坏 JSON 行不挂掉", .enabled(if: subprocessTestsEnabled))
func codexRunIgnoresMalformedLines() async throws {
    let stub = try makeCodexStubScript(body: """
        echo 'not json at all'
        echo '{'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"survived"}}'
        echo '{"type":"turn.completed"}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = CodexEngine(binaryPath: stub.path)
    var collected = ""
    for try await delta in engine.run(prompt: "test") {
        collected += delta
    }
    #expect(collected.contains("survived"))
}

@Test("run 没有 turn.completed 但进程 exit 0 → 兜底 finish 不挂死", .enabled(if: subprocessTestsEnabled))
func codexRunNoTurnCompletedButCleanExit() async throws {
    // codex 极端边界:没打 turn.completed 直接 EOF。stream 应当兜底 finish。
    let stub = try makeCodexStubScript(body: """
        echo '{"type":"thread.started","thread_id":"abc"}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"early eof"}}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = CodexEngine(binaryPath: stub.path)
    var collected = ""
    for try await delta in engine.run(prompt: "test") {
        collected += delta
    }
    #expect(collected.contains("early eof"))
}

@Test("run 找不到 codex binary(注入不存在路径)→ Process.run 抛错", .enabled(if: subprocessTestsEnabled))
func codexRunMissingBinary() async {
    // 跟 ClaudeCodeEngineTests 同款 trade-off:binaryPath 注入路径上,
    // Process.run() 找不到 binary 时抛 NSCocoaErrorDomain 错误透传,不被
    // 包装成 cliNotInstalled。验证有 throw 即可,不验证具体类型。
    let engine = CodexEngine(
        binaryPath: "/tmp/petagent-codex-not-there-\(UUID().uuidString)"
    )
    do {
        for try await _ in engine.run(prompt: "test") {}
        Issue.record("expected throw, stream ended cleanly")
    } catch {
        #expect(Bool(true))
    }
}

// MARK: - StreamState 多段 agent_message 拼接验证

@Test("run 多段 agent_message 之间用 \\n\\n 分隔", .enabled(if: subprocessTestsEnabled))
func codexRunMultiAgentMessageSeparator() async throws {
    let stub = try makeCodexStubScript(body: """
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"first"}}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"second"}}'
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"third"}}'
        echo '{"type":"turn.completed"}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = CodexEngine(binaryPath: stub.path)
    var collected = ""
    for try await delta in engine.run(prompt: "test") {
        collected += delta
    }
    // 期望: "first\n\nsecond\n\nthird"
    #expect(collected == "first\n\nsecond\n\nthird")
}

// MARK: - B 根治:watchdog 硬超时（防 EOF/stream 竞态挂死）

@Test("run 卡死子进程(不输出不退出)→ watchdog 硬超时抛 timedOut", .enabled(if: subprocessTestsEnabled))
func codexRunTimesOutOnHangingSubprocess() async throws {
    // exec sleep 让 SIGTERM 直接杀到 sleep（不留孤儿占 pipe）。子进程不打
    // turn.completed、不退出 → 没有 watchdog 就会永久挂死。
    let stub = try makeCodexStubScript(body: "exec sleep 30")
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = CodexEngine(binaryPath: stub.path, timeoutSeconds: 0.4)
    do {
        for try await _ in engine.run(prompt: "test") {}
        Issue.record("expected timedOut but stream ended cleanly")
    } catch ToolEngineError.timedOut(let kind) {
        #expect(kind == .codex)
    } catch {
        Issue.record("expected ToolEngineError.timedOut, got: \(error)")
    }
}
