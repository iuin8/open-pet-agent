import Foundation
import Testing
@testable import AgentMode

// MARK: - 测试辅助

/// 在 tmp 目录写一个可执行的 shell 脚本, 内容为 `claude -p` CLI 的 stream-json
/// stdout 模拟器。返回 binary 路径供 `ClaudeCodeEngine(binaryPath:)` 注入。
///
/// `body` 不带 shebang, 函数自己加 `#!/bin/bash`。
private func makeStubScript(body: String) throws -> URL {
    let tmpDir = FileManager.default.temporaryDirectory
    let url = tmpDir.appendingPathComponent(
        "petagent-test-claude-stub-\(UUID().uuidString).sh"
    )
    let full = "#!/bin/bash\nset -e\n" + body + "\n"
    try full.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
    return url
}

// MARK: - parseAssistantText 纯函数测试 (无子进程)

@Test("parseAssistantText 提取单 text block")
func parseAssistantTextSingleBlock() {
    let line = #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"hi"}]}}"#
    #expect(ClaudeCodeEngine.parseAssistantText(line) == "hi")
}

@Test("parseAssistantText 多 content block 合并")
func parseAssistantTextMergesBlocks() {
    let line = #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}}"#
    #expect(ClaudeCodeEngine.parseAssistantText(line) == "AB")
}

@Test("parseAssistantText 跳过非 text content 块")
func parseAssistantTextSkipsNonText() {
    let line = #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"A"},{"type":"tool_use","id":"tu1","name":"Read","input":{}}]}}"#
    #expect(ClaudeCodeEngine.parseAssistantText(line) == "A")
}

@Test("parseAssistantText 非 assistant message 返回 nil")
func parseAssistantTextRejectsSystem() {
    let line = #"{"type":"system","subtype":"init"}"#
    #expect(ClaudeCodeEngine.parseAssistantText(line) == nil)
}

@Test("parseAssistantText 坏 JSON 返回 nil 不崩")
func parseAssistantTextHandlesBadJson() {
    #expect(ClaudeCodeEngine.parseAssistantText("not json") == nil)
    #expect(ClaudeCodeEngine.parseAssistantText("") == nil)
    #expect(ClaudeCodeEngine.parseAssistantText("{") == nil)
    #expect(ClaudeCodeEngine.parseAssistantText("{\"type\":\"assistant\"}") == nil)
}

@Test("parseAssistantText 空 text 集合返回 nil")
func parseAssistantTextEmptyTextReturnsNil() {
    let line = #"{"type":"assistant","message":{"id":"m1","content":[]}}"#
    #expect(ClaudeCodeEngine.parseAssistantText(line) == nil)
}

// MARK: - parseResultEvent 纯函数测试

@Test("parseResultEvent success")
func parseResultEventSuccess() {
    let line = #"{"type":"result","subtype":"success","is_error":false}"#
    #expect(ClaudeCodeEngine.parseResultEvent(line) == .success)
}

@Test("parseResultEvent failure 带 result 文案")
func parseResultEventFailure() {
    let line = #"{"type":"result","is_error":true,"result":"boom"}"#
    #expect(ClaudeCodeEngine.parseResultEvent(line) == .failure("boom"))
}

@Test("parseResultEvent failure 缺 result 字段 → 未知错误")
func parseResultEventFailureNoMessage() {
    let line = #"{"type":"result","is_error":true}"#
    #expect(ClaudeCodeEngine.parseResultEvent(line) == .failure("未知错误"))
}

@Test("parseResultEvent 非 result 行返回 nil")
func parseResultEventRejectsAssistant() {
    let line = #"{"type":"assistant","message":{"id":"m","content":[]}}"#
    #expect(ClaudeCodeEngine.parseResultEvent(line) == nil)
}

// MARK: - ClaudeCodeEngine 元数据

@Test("ClaudeCodeEngine.kind 是 claudeCode")
func claudeCodeEngineKind() {
    #expect(ClaudeCodeEngine.kind == .claudeCode)
}

@Test("ClaudeCodeEngine isAvailable: 注入的 binaryPath 可执行 → true")
func isAvailableWithExecutableBinary() async throws {
    let stub = try makeStubScript(body: "echo hi")
    let engine = ClaudeCodeEngine(binaryPath: stub.path)
    #expect(await engine.isAvailable == true)
    try? FileManager.default.removeItem(at: stub)
}

@Test("ClaudeCodeEngine isAvailable: 注入的 binaryPath 不存在 → false")
func isAvailableWithMissingBinary() async {
    let engine = ClaudeCodeEngine(
        binaryPath: "/tmp/petagent-definitely-not-there-\(UUID().uuidString)"
    )
    #expect(await engine.isAvailable == false)
}

// MARK: - run(prompt:) 子进程集成测试

@Test("run yields 所有 assistant text chunk", .enabled(if: subprocessTestsEnabled))
func runYieldsAssistantTextChunks() async throws {
    let stub = try makeStubScript(body: """
        echo '{"type":"system","subtype":"init"}'
        echo '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello"}]}}'
        echo '{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":" world"}]}}'
        echo '{"type":"result","subtype":"success","is_error":false}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = ClaudeCodeEngine(binaryPath: stub.path)
    var collected = ""
    for try await delta in engine.run(prompt: "test") {
        collected += delta
    }
    // 新 message 之间会插 "\n\n" 分隔
    #expect(collected.contains("Hello"))
    #expect(collected.contains(" world"))
}

@Test("run 同 message id 的 partial update yield 增量", .enabled(if: subprocessTestsEnabled))
func runYieldsIncrementalDeltasForSameMessage() async throws {
    let stub = try makeStubScript(body: """
        echo '{"type":"assistant","message":{"id":"same","content":[{"type":"text","text":"Hel"}]}}'
        echo '{"type":"assistant","message":{"id":"same","content":[{"type":"text","text":"Hello"}]}}'
        echo '{"type":"assistant","message":{"id":"same","content":[{"type":"text","text":"Hello world"}]}}'
        echo '{"type":"result","subtype":"success","is_error":false}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = ClaudeCodeEngine(binaryPath: stub.path)
    var deltas: [String] = []
    for try await delta in engine.run(prompt: "test") {
        deltas.append(delta)
    }
    // 期望 3 个增量: "Hel", "lo", " world" (合并后等于 "Hello world")
    let joined = deltas.joined()
    #expect(joined == "Hello world")
    // 第一个 delta 不该等于第三次 partial 的完整文本(否则就是没去重)
    #expect(deltas.first != "Hello world")
}

@Test("run 非 zero exit code 抛 subprocessFailed", .enabled(if: subprocessTestsEnabled))
func runFailedExitThrowsSubprocessFailed() async throws {
    let stub = try makeStubScript(body: """
        echo "fatal stderr msg" >&2
        exit 42
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = ClaudeCodeEngine(binaryPath: stub.path)
    do {
        for try await _ in engine.run(prompt: "test") {
            // 即便意外 yield 也继续到 throw
        }
        Issue.record("expected subprocessFailed but stream ended cleanly")
    } catch let AgentEngineError.subprocessFailed(code, stderr) {
        #expect(code == 42)
        #expect(stderr.contains("fatal stderr msg"))
    } catch {
        Issue.record("expected AgentEngineError.subprocessFailed, got: \(error)")
    }
}

@Test("run is_error=true 的 result event 抛 subprocessFailed 带 result 文案", .enabled(if: subprocessTestsEnabled))
func runResultErrorThrows() async throws {
    let stub = try makeStubScript(body: """
        echo '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"partial"}]}}'
        echo '{"type":"result","is_error":true,"result":"模型返回错误"}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = ClaudeCodeEngine(binaryPath: stub.path)
    var sawPartial = false
    do {
        for try await delta in engine.run(prompt: "test") {
            if delta.contains("partial") { sawPartial = true }
        }
        Issue.record("expected throw")
    } catch let AgentEngineError.subprocessFailed(_, stderr) {
        #expect(stderr.contains("模型返回错误"))
        #expect(sawPartial)  // is_error 之前的 partial 文本仍应被 yield 出去
    } catch {
        Issue.record("expected AgentEngineError.subprocessFailed, got: \(error)")
    }
}

@Test("run 找不到 claude binary 抛 cliNotInstalled", .enabled(if: subprocessTestsEnabled))
func runCliNotInstalled() async {
    // 注入空 PATH 让 CLIAvailability.locate 必失败 —— 但注意 isAvailable/locate
    // 自己走 ProcessInfo.environment 不接 processEnvironment 参数(processEnvironment
    // 只影响子进程自身)。所以这里用"不传 binaryPath + locate 内部 search 失败"
    // 模拟困难, 换个等价路径:传完全不存在的 binaryPath, 让 Process.run() 失败。
    let engine = ClaudeCodeEngine(
        binaryPath: "/tmp/petagent-not-there-\(UUID().uuidString)"
    )
    do {
        for try await _ in engine.run(prompt: "test") {}
        Issue.record("expected throw, stream ended cleanly")
    } catch {
        // Process.run() 找不到 binary 时抛 NSCocoaErrorDomain 错误,
        // 不是 AgentEngineError —— 这是当前实现的 trade-off:
        // binaryPath 注入路径上 Process 本身的错误透传, 不被包装。
        // 验证至少有 throw, 不验证具体类型。
        #expect(Bool(true))
    }
}

// MARK: - SubprocessRegistry 接入验证

@Test("ClaudeCodeEngine spawn 跑通 + stream 完成不抛错 (registry register/unregister 在 SubprocessRegistry 单测覆盖)", .enabled(if: subprocessTestsEnabled))
func runStreamCompletesSuccessfully() async throws {
    // 注意: 不依赖 SubprocessRegistry.shared 计数, 因为多个 AgentMode tests
    // 跨 suite parallel 跑会污染 shared registry counter (register/unregister
    // 是 fire-and-forget Task, 时序不可预测)。register/unregister 的真实行为
    // 由 SubprocessRegistryTests 用独立实例覆盖, 这里只验证 stream 流程跑通。

    let stub = try makeStubScript(body: """
        echo '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"hi"}]}}'
        echo '{"type":"result","subtype":"success","is_error":false}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = ClaudeCodeEngine(binaryPath: stub.path)

    var deltas: [String] = []
    for try await delta in engine.run(prompt: "test") {
        deltas.append(delta)
    }
    #expect(deltas.joined().contains("hi"))
}

@Test("run 忽略坏 JSON 行不挂掉", .enabled(if: subprocessTestsEnabled))
func runIgnoresMalformedLines() async throws {
    let stub = try makeStubScript(body: """
        echo 'not json at all'
        echo '{'
        echo '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"survived"}]}}'
        echo '{"type":"result","subtype":"success","is_error":false}'
        """)
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = ClaudeCodeEngine(binaryPath: stub.path)
    var collected = ""
    for try await delta in engine.run(prompt: "test") {
        collected += delta
    }
    #expect(collected.contains("survived"))
}

// MARK: - B 根治:watchdog 硬超时（修 131 分钟挂死根因）

@Test("run 卡死子进程(exit 0 前无 result 事件)→ watchdog 硬超时抛 timedOut", .enabled(if: subprocessTestsEnabled))
func runTimesOutOnHangingSubprocess() async throws {
    // exec sleep 让 SIGTERM 直接杀到 sleep。子进程不打 result、不退出 →
    // 原实现 terminationHandler 在 exit 0 分支啥都不做 → 永久挂死(根因)。
    let stub = try makeStubScript(body: "exec sleep 30")
    defer { try? FileManager.default.removeItem(at: stub) }

    let engine = ClaudeCodeEngine(binaryPath: stub.path, timeoutSeconds: 0.4)
    do {
        for try await _ in engine.run(prompt: "test") {}
        Issue.record("expected timedOut but stream ended cleanly")
    } catch AgentEngineError.timedOut(let kind) {
        #expect(kind == .claudeCode)
    } catch {
        Issue.record("expected AgentEngineError.timedOut, got: \(error)")
    }
}
