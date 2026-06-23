import Testing
import Foundation
@testable import AgentSensing

@Suite("AgentSensingService — 轮询编排")
struct AgentSensingServiceTests {

    /// 线程安全收集 sink 产出。
    actor Collector {
        private(set) var outputs: [AgentSensingService.Output] = []
        func add(_ o: AgentSensingService.Output) { outputs.append(o) }
    }

    /// 建俩临时根(claude/codex),返回 (claudeRoot, codexRoot)。
    func tempRoots() throws -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsensing-svc-\(UUID().uuidString)", isDirectory: true)
        let claude = base.appendingPathComponent("claude", isDirectory: true)
        let codex = base.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        return (claude, codex)
    }

    func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    func makeService(claude: URL, codex: URL, enabled: Bool, collector: Collector) -> AgentSensingService {
        AgentSensingService(
            enabled: enabled,
            claudeRoot: claude,
            codexRoot: codex,
            activeWindow: 100_000,           // 测试里不让 mtime 窗口干扰
            clock: { Date() },
            sink: { o in await collector.add(o) }
        )
    }

    @Test("首次 poll 跳历史(seek 末尾)→ 不 emit 旧行")
    func bootstrapSkipsHistory() async throws {
        let (claude, codex) = try tempRoots()
        let file = claude.appendingPathComponent("sess.jsonl")
        try write(#"{"type":"assistant","sessionId":"sess","message":{"content":[{"type":"text","text":"旧的"}]}}"# + "\n", to: file)

        let collector = Collector()
        let svc = makeService(claude: claude, codex: codex, enabled: true, collector: collector)
        await svc.poll()                       // 注册 + seek 末尾
        let count = await collector.outputs.count
        #expect(count == 0)                    // 历史不回放
    }

    @Test("后续追加 → emit + 折叠出 working/idle 跃迁")
    func emitsAppendedWithTransitions() async throws {
        let (claude, codex) = try tempRoots()
        let file = claude.appendingPathComponent("sess.jsonl")
        try write("", to: file)

        let collector = Collector()
        let svc = makeService(claude: claude, codex: codex, enabled: true, collector: collector)
        await svc.poll()                       // 注册空文件

        try append(#"{"type":"assistant","sessionId":"sess","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift build"}}]}}"# + "\n", to: file)
        try append(#"{"type":"user","sessionId":"sess","message":{"content":[{"type":"tool_result","content":"ok"}]}}"# + "\n", to: file)
        await svc.poll()

        let outs = await collector.outputs
        #expect(outs.count == 2)
        // 第一条:toolUse → working 跃迁(from nil)
        #expect(outs.first?.event.kind == .toolUse(name: "Bash", summary: "swift build"))
        #expect(outs.first?.transition?.to == .working)
        // 第二条:toolResult 还是 working → 无跃迁
        #expect(outs.last?.transition == nil)
    }

    @Test("done → idle 跃迁(供庆祝)")
    func doneTransition() async throws {
        let (claude, codex) = try tempRoots()
        let file = claude.appendingPathComponent("sess.jsonl")
        try write("", to: file)
        let collector = Collector()
        let svc = makeService(claude: claude, codex: codex, enabled: true, collector: collector)
        await svc.poll()

        try append(#"{"type":"assistant","sessionId":"sess","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"x"}}]}}"# + "\n", to: file)
        try append(#"{"type":"assistant","sessionId":"sess","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"header":"发布?"}]}}]}}"# + "\n", to: file)
        await svc.poll()

        let outs = await collector.outputs
        #expect(outs.last?.event.kind == .awaitingUser(reason: .question(title: "发布?")))
        #expect(outs.last?.transition?.to == .awaitingUser)
    }

    /// 可控时钟,推进时间验静默检测。
    final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var d: Date
        init(_ start: Date) { d = start }
        var now: Date { lock.lock(); defer { lock.unlock() }; return d }
        func advance(_ s: TimeInterval) { lock.lock(); d = d.addingTimeInterval(s); lock.unlock() }
    }

    @Test("静默检测:工具在飞跳过(长工具不误判)+ toolResult 后超时 → 合成 idle(根治 Claude 不产 .done 卡死)")
    func silenceSynthesizesIdle() async throws {
        let (claude, codex) = try tempRoots()
        let file = claude.appendingPathComponent("sess.jsonl")
        try write("", to: file)
        let collector = Collector()
        let clock = MutableClock(Date())
        let svc = AgentSensingService(
            enabled: true, claudeRoot: claude, codexRoot: codex, activeWindow: 120,
            clock: { clock.now }, sink: { o in await collector.add(o) })
        await svc.poll()                       // 注册空文件
        // tool_use → working;**末事件是 toolUse(工具在飞)**
        try append(#"{"type":"assistant","sessionId":"sess","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"x"}}]}}"# + "\n", to: file)
        await svc.poll()
        #expect(await collector.outputs.contains { $0.transition?.to == .working })
        // 超时再 poll:末事件是 toolUse → **静默跳过**(长 build/test 无新行不误判成停了)
        clock.advance(9)
        await svc.poll()
        #expect(await collector.outputs.contains { $0.isSilenceIdle } == false)
        // tool_result 到达 → 末事件不再是 toolUse
        try append(#"{"type":"user","sessionId":"sess","message":{"content":[{"type":"tool_result","content":"ok"}]}}"# + "\n", to: file)
        await svc.poll()
        // 再超时 poll → 合成 idle(working→idle,标 isSilenceIdle)
        clock.advance(9)
        await svc.poll()
        let silence = await collector.outputs.first { $0.isSilenceIdle }
        #expect(silence != nil)
        #expect(silence?.transition?.to == .idle)
        // 真事件不带 isSilenceIdle(接线层据此只对合成 idle 跳过会话流/气泡)
        #expect(await collector.outputs.contains { !$0.isSilenceIdle && $0.transition?.to == .working })
        // 再 poll 仍无新行 → 不重复合成(已 idle 稳态 + 防重)
        let before = await collector.outputs.count
        clock.advance(9)
        await svc.poll()
        #expect(await collector.outputs.count == before)
    }

    @Test("disabled → poll 静默")
    func disabledSilent() async throws {
        let (claude, codex) = try tempRoots()
        let file = claude.appendingPathComponent("sess.jsonl")
        try write("", to: file)
        let collector = Collector()
        let svc = makeService(claude: claude, codex: codex, enabled: false, collector: collector)
        await svc.poll()
        try append(#"{"type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"hi"}]}}"# + "\n", to: file)
        await svc.poll()
        let count = await collector.outputs.count
        #expect(count == 0)
    }

    @Test("Codex 目录文件走 codex parser(agent=.codex)")
    func codexRouted() async throws {
        let (claude, codex) = try tempRoots()
        let file = codex.appendingPathComponent("rollout-x.jsonl")
        try write("", to: file)
        let collector = Collector()
        let svc = makeService(claude: claude, codex: codex, enabled: true, collector: collector)
        await svc.poll()

        try append(#"{"type":"event_msg","payload":{"type":"exec_command_begin","command":["ls"]}}"# + "\n", to: file)
        await svc.poll()

        let outs = await collector.outputs
        #expect(outs.count == 1)
        #expect(outs.first?.event.agent == .codex)
        #expect(outs.first?.event.kind == .toolUse(name: "exec", summary: "ls"))
    }

    @Test("Codex 工具行带自身 id(≠文件名)→ stamped 钉死 sessionId 但保留 detail")
    func stampedPreservesDetail() async throws {
        let (claude, codex) = try tempRoots()
        let file = codex.appendingPathComponent("rollout-x.jsonl")   // 文件名派生 sessionId = rollout-x
        try write("", to: file)
        let collector = Collector()
        let svc = makeService(claude: claude, codex: codex, enabled: true, collector: collector)
        await svc.poll()

        // 顶层 id "fc_999" ≠ "rollout-x" → 命中 stamped 重建分支(以前会把 detail 丢成 nil)。
        try append(#"{"type":"response_item","id":"fc_999","payload":{"type":"function_call","name":"exec_command","arguments":"{\"command\":[\"ls\",\"-la\"]}"}}"# + "\n", to: file)
        await svc.poll()

        let outs = await collector.outputs
        #expect(outs.count == 1)
        #expect(outs.first?.event.sessionId == "rollout-x")          // 钉死成文件 sessionId
        #expect(outs.first?.event.detail == "ls -la")                // detail 不被重建吞掉
    }
}
