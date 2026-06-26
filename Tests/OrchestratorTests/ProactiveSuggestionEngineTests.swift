// Tests/OrchestratorTests/ProactiveSuggestionEngineTests.swift
import Foundation
import Testing
import Context
@testable import Orchestrator

@Suite("ProactiveSuggestionEngine")
struct ProactiveSuggestionEngineTests {
    /// mock generator：同步返回固定串，可注错。
    final class MockGenerator: ProactiveSuggestionGenerating, @unchecked Sendable {
        let reply: String
        let error: Error?
        /// 捕获最近一次调用的 systemPrompt / prompt（供断言 persona 注入 + 场景脉络注入）。
        private(set) var lastSystemPrompt: String?
        private(set) var lastPrompt: String?
        init(reply: String = "建议内容", error: Error? = nil) { self.reply = reply; self.error = error }
        func generate(systemPrompt: String, prompt: String, snapshot: DesktopSnapshot?) async throws -> String {
            lastSystemPrompt = systemPrompt
            lastPrompt = prompt
            if let error { throw error }
            return reply
        }
    }

    /// sink spy：记录调用。
    actor SinkSpy {
        var calls: [(label: String, reply: String)] = []
        func record(_ label: String, _ reply: String) { calls.append((label, reply)) }
    }

    /// 可切换布尔 flag（用于运行中翻转 isStreaming 状态）。
    actor MutableFlag {
        private var v: Bool
        init(_ v: Bool) { self.v = v }
        func set(_ x: Bool) { v = x }
        func get() -> Bool { v }
    }

    private func makeEngine(
        settings: ProactiveSettings,
        generator: any ProactiveSuggestionGenerating = MockGenerator(),
        sink: SinkSpy,
        isStreaming: @escaping @Sendable () async -> Bool = { false },
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSinceReferenceDate: 1_000_000) },
        snapshot: DesktopSnapshot? = DesktopSnapshot(visibleApplicationName: "Xcode")
    ) -> ProactiveSuggestionEngine {
        ProactiveSuggestionEngine(
            settings: settings,
            snapshotProvider: { snapshot },
            generator: generator,
            sink: { label, reply in await sink.record(label, reply) },
            isStreamingProvider: isStreaming,
            now: now,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    @Test("feedAppSwitch 通过 → sink 调一次，label = 应用切换")
    func appSwitchFires() async {
        let sink = SinkSpy()
        let engine = makeEngine(settings: .default, sink: sink)
        await engine.feedAppSwitch(appName: "Xcode")
        let calls = await sink.calls
        #expect(calls.count == 1)
        #expect(calls.first?.label == "应用切换")
        #expect(calls.first?.reply == "建议内容")
    }

    @Test("persona + 窗口标题 + 最近 app 轨迹 注入到 generate")
    func personaAndSceneContextInjected() async {
        let sink = SinkSpy()
        let gen = MockGenerator()
        var s = ProactiveSettings.default
        s.personaText = "叫我老王，后端工程师"
        let snap = DesktopSnapshot(
            visibleApplicationName: "Xcode",
            visibleWindows: [VisibleWindowSnapshot(ownerName: "Xcode", bounds: .zero, title: "Foo.swift")]
        )
        var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = ProactiveSuggestionEngine(
            settings: s,
            snapshotProvider: { snap },
            generator: gen,
            sink: { l, r in await sink.record(l, r) },
            isStreamingProvider: { false },
            now: { t },
            calendar: Calendar(identifier: .gregorian)
        )
        // 建立轨迹：Slack → Chrome → Xcode，每步 > minInterval(600s) 让其都 fire 并入轨迹环。
        await engine.feedAppSwitch(appName: "Slack");  t = t.addingTimeInterval(700)
        await engine.feedAppSwitch(appName: "Chrome"); t = t.addingTimeInterval(700)
        await engine.feedAppSwitch(appName: "Xcode")
        // persona 注入 systemPrompt；windowTitle 从 snap 补全进场景 prompt；轨迹剔除当前 Xcode。
        #expect(gen.lastSystemPrompt?.contains("老王") == true)
        #expect(gen.lastPrompt?.contains("Foo.swift") == true)
        #expect(gen.lastPrompt?.contains("这之前用过") == true)
        #expect(gen.lastPrompt?.contains("Slack") == true)
        #expect(gen.lastPrompt?.contains("Chrome") == true)
        #expect(gen.lastPrompt?.contains("用户刚切换到「Xcode」") == true)
    }

    @Test("level=off → 不触发")
    func offNoFire() async {
        let sink = SinkSpy()
        var s = ProactiveSettings.default; s.level = .off
        let engine = makeEngine(settings: s, sink: sink)
        await engine.feedAppSwitch(appName: "Xcode")
        #expect(await sink.calls.isEmpty)
    }

    @Test("throttle 拒（冷却内）→ sink 不调")
    func throttleBlocks() async {
        let sink = SinkSpy()
        let engine = makeEngine(settings: .default, sink: sink)
        await engine.feedAppSwitch(appName: "Xcode")     // 第一条
        await engine.feedAppSwitch(appName: "Safari")    // 冷却内（同一 now）→ 拒
        #expect(await sink.calls.count == 1)
    }

    @Test("isStreaming=true → 跳过且不计配额；关掉 + 过去抖后下一条能触发")
    func streamingSkipsNoQuota() async {
        let sink = SinkSpy()
        let streaming = MutableFlag(true)
        var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = ProactiveSuggestionEngine(
            settings: .default,
            snapshotProvider: { DesktopSnapshot(visibleApplicationName: "Xcode") },
            generator: MockGenerator(),
            sink: { l, r in await sink.record(l, r) },
            isStreamingProvider: { await streaming.get() },
            now: { t },
            calendar: Calendar(identifier: .gregorian)
        )
        await engine.feedAppSwitch(appName: "Xcode")   // streaming=true → 跳过
        #expect(await sink.calls.isEmpty)
        await streaming.set(false)
        t = t.addingTimeInterval(5)                     // 过 3s 去抖
        await engine.feedAppSwitch(appName: "Safari")   // 配额未被首次消耗 → 应触发（throttle 无 lastFiredAt）
        #expect(await sink.calls.count == 1)
    }

    @Test("生成失败 → 静默跳过，不 sink")
    func generationErrorSilent() async {
        let sink = SinkSpy()
        let gen = MockGenerator(error: LLMProviderError.emptyResponse)
        let engine = makeEngine(settings: .default, generator: gen, sink: sink)
        await engine.feedAppSwitch(appName: "Xcode")
        #expect(await sink.calls.isEmpty)
    }

    @Test("updateSettings(off) 后不再触发")
    func updateToOff() async {
        let sink = SinkSpy()
        let engine = makeEngine(settings: .default, sink: sink)
        var off = ProactiveSettings.default; off.level = .off
        await engine.updateSettings(off)
        await engine.feedAppSwitch(appName: "Xcode")
        #expect(await sink.calls.isEmpty)
    }

    @Test("深夜 tick 触发（hour 注入 2 点）")
    func lateNightTick() async {
        let sink = SinkSpy()
        // now 设到凌晨 2 点
        var comps = DateComponents(); comps.year = 2026; comps.month = 6; comps.day = 4; comps.hour = 2
        let cal = Calendar(identifier: .gregorian)
        let night = cal.date(from: comps)!
        let engine = ProactiveSuggestionEngine(
            settings: .default,
            snapshotProvider: { DesktopSnapshot(visibleApplicationName: "Safari") },
            generator: MockGenerator(),
            sink: { l, r in await sink.record(l, r) },
            isStreamingProvider: { false },
            now: { night },
            calendar: cal
        )
        await engine.tick()
        let calls = await sink.calls
        #expect(calls.count == 1)
        #expect(calls.first?.label == "深夜")
    }

    @Test("recordEngaged 归零后高 decay 也能恢复触发节奏")
    func engagedResetsDecay() async {
        // 间接验证 recordIgnored/Engaged 走到 throttleState（黑盒：忽略后降频，engaged 后恢复）
        let sink = SinkSpy()
        var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = ProactiveSuggestionEngine(
            settings: .default,
            snapshotProvider: { DesktopSnapshot(visibleApplicationName: "Xcode") },
            generator: MockGenerator(),
            sink: { l, r in await sink.record(l, r) },
            isStreamingProvider: { false },
            now: { t },
            calendar: Calendar(identifier: .gregorian)
        )
        await engine.feedAppSwitch(appName: "A")          // fire 1
        for _ in 0..<3 { await engine.recordIgnored() }    // 攒满 moderate threshold → 冷却 900s
        t = t.addingTimeInterval(700)                      // 700s：base 600 已过但 decay 900 未过
        await engine.feedAppSwitch(appName: "B")          // 应被 decay 拒
        #expect(await sink.calls.count == 1)
        await engine.recordEngaged()                       // 归零 decay
        t = t.addingTimeInterval(50)                       // 距 fire1 共 750s > base 600
        await engine.feedAppSwitch(appName: "C")          // 应放行
        #expect(await sink.calls.count == 2)
    }

    // MARK: - 场景 B：idle 回来（wentSleepAt 计时端到端）

    @Test("feedSleepingChanged: 离开≥180s 回来 → 触发 idleReturn")
    func idleReturnFires() async {
        let sink = SinkSpy()
        var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = ProactiveSuggestionEngine(
            settings: .default,
            snapshotProvider: { DesktopSnapshot(visibleApplicationName: "Xcode") },
            generator: MockGenerator(),
            sink: { l, r in await sink.record(l, r) },
            isStreamingProvider: { false },
            now: { t },
            calendar: Calendar(identifier: .gregorian)
        )
        await engine.feedSleepingChanged(true)        // 记 wentSleepAt = t
        t = t.addingTimeInterval(200)                 // 离开 200s ≥ 180
        await engine.feedSleepingChanged(false)       // awaySeconds=200 → idleReturn
        #expect(await sink.calls.count == 1)
        #expect(await sink.calls.first?.label == "久未活动")
    }

    @Test("feedSleepingChanged: 离开 <180s 回来 → 不触发")
    func idleReturnTooShort() async {
        let sink = SinkSpy()
        var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = ProactiveSuggestionEngine(
            settings: .default,
            snapshotProvider: { DesktopSnapshot(visibleApplicationName: "Xcode") },
            generator: MockGenerator(),
            sink: { l, r in await sink.record(l, r) },
            isStreamingProvider: { false },
            now: { t },
            calendar: Calendar(identifier: .gregorian)
        )
        await engine.feedSleepingChanged(true)
        t = t.addingTimeInterval(100)                 // <180
        await engine.feedSleepingChanged(false)
        #expect(await sink.calls.isEmpty)
    }

    // MARK: - 场景 C：dwell 累积 + 锁（端到端）

    @Test("dwell: 同窗口连续 tick 累积到阈值 → 触发 dwell；触发后锁定")
    func dwellAccumulatesAndLocks() async {
        let sink = SinkSpy()
        var settings = ProactiveSettings.default
        settings.triggerDwell = true            // 默认关，测试打开
        settings.dwellThresholdSeconds = 30     // 一个 tick(30s) 累积即达阈值
        // 正午，避开深夜窗口干扰
        var comps = DateComponents(); comps.year = 2026; comps.month = 6; comps.day = 4; comps.hour = 12
        let cal = Calendar(identifier: .gregorian)
        let noon = cal.date(from: comps)!
        let engine = ProactiveSuggestionEngine(
            settings: settings,
            snapshotProvider: { DesktopSnapshot(visibleApplicationName: "Xcode") },
            generator: MockGenerator(),
            sink: { l, r in await sink.record(l, r) },
            isStreamingProvider: { false },
            now: { noon },
            calendar: cal
        )
        await engine.tick()                     // tick1: dwellSeconds=0（key 初始化）→ 不触发
        #expect(await sink.calls.isEmpty)
        await engine.tick()                     // tick2: dwellSeconds=30 ≥30 → 触发
        #expect(await sink.calls.count == 1)
        #expect(await sink.calls.first?.label == "专注中")
        await engine.tick()                     // tick3: dwellFired 已锁 → 不再触发
        #expect(await sink.calls.count == 1)
    }

    // MARK: - 自主两层（碎碎念 + LLM 自主闲聊）

    /// 构造带 quoteProvider + 固定 random（取区间下界）的引擎，now 可变。
    private func makeAutoEngine(
        settings: ProactiveSettings,
        sink: SinkSpy,
        nowBox: @escaping @Sendable () -> Date,
        quote: String? = "盯代码看好久啦",
        isStreaming: @escaping @Sendable () async -> Bool = { false },
        generator: any ProactiveSuggestionGenerating = MockGenerator()
    ) -> ProactiveSuggestionEngine {
        ProactiveSuggestionEngine(
            settings: settings,
            snapshotProvider: { DesktopSnapshot(visibleApplicationName: "Xcode") },
            generator: generator,
            sink: { l, r in await sink.record(l, r) },
            isStreamingProvider: isStreaming,
            now: nowBox,
            calendar: Calendar(identifier: .gregorian),
            quoteProvider: { _, _, _ in quote },
            random: { $0.lowerBound }   // 固定取区间下界，确定性
        )
    }

    @Test("碎碎念到期 → sink 调一次(label 碎碎念) + 不动 LLM 配额")
    func chatterFiresAndNoQuota() async {
        let sink = SinkSpy()
        // 下午 13:46（非深夜），moderate（chatterEnabled 默认 true、间隔 300...600）。
        nonisolated(unsafe) var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = makeAutoEngine(settings: .default, sink: sink, nowBox: { t })
        await engine.tick()                        // tick1：排程 nextChatterAt=t+300，未到期
        #expect(await sink.calls.isEmpty)
        t = t.addingTimeInterval(301)
        await engine.tick()                        // tick2：到期 → 冒碎碎念
        var calls = await sink.calls
        #expect(calls.count == 1)
        #expect(calls.first?.label == "碎碎念")
        #expect(calls.first?.reply == "盯代码看好久啦")
        // 碎碎念不占 LLM 配额 → 紧接 app 切换仍能触发 LLM（throttle 无 lastFiredAt）。
        await engine.feedAppSwitch(appName: "Safari")
        calls = await sink.calls
        #expect(calls.count == 2)
        #expect(calls.last?.label == "应用切换")
    }

    @Test("chatterEnabled=false → 不冒碎碎念")
    func chatterDisabled() async {
        let sink = SinkSpy()
        var s = ProactiveSettings.default; s.chatterEnabled = false
        nonisolated(unsafe) var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = makeAutoEngine(settings: s, sink: sink, nowBox: { t })
        await engine.tick(); t = t.addingTimeInterval(1000); await engine.tick()
        #expect(await sink.calls.isEmpty)
    }

    @Test("level=off → 碎碎念不触发")
    func chatterOffLevel() async {
        let sink = SinkSpy()
        var s = ProactiveSettings.default; s.level = .off
        nonisolated(unsafe) var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = makeAutoEngine(settings: s, sink: sink, nowBox: { t })
        await engine.tick(); t = t.addingTimeInterval(1000); await engine.tick()
        #expect(await sink.calls.isEmpty)
    }

    @Test("碎碎念安全门：用户对话中 → 跳过不冒")
    func chatterSafeGate() async {
        let sink = SinkSpy()
        nonisolated(unsafe) var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = makeAutoEngine(settings: .default, sink: sink, nowBox: { t }, isStreaming: { true })
        await engine.tick(); t = t.addingTimeInterval(301); await engine.tick()
        #expect(await sink.calls.isEmpty)
    }

    @Test("autonomous 到期 + triggerAutonomous → 走 LLM attempt(label 主动关心)")
    func autonomousFires() async {
        let sink = SinkSpy()
        var s = ProactiveSettings.default
        s.level = .active            // autonomousIntervalRange active 600...1200
        s.triggerAutonomous = true
        s.chatterEnabled = false     // 关碎碎念，单测 autonomous
        nonisolated(unsafe) var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = makeAutoEngine(settings: s, sink: sink, nowBox: { t })
        await engine.tick()                        // 排程 nextAutonomousAt=t+600
        #expect(await sink.calls.isEmpty)
        t = t.addingTimeInterval(601)
        await engine.tick()                        // 到期 → LLM attempt
        let calls = await sink.calls
        #expect(calls.count == 1)
        #expect(calls.first?.label == "主动关心")
    }

    @Test("triggerAutonomous=false → 不冒 LLM 自主闲聊")
    func autonomousDisabled() async {
        let sink = SinkSpy()
        var s = ProactiveSettings.default; s.level = .active; s.triggerAutonomous = false; s.chatterEnabled = false
        nonisolated(unsafe) var t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let engine = makeAutoEngine(settings: s, sink: sink, nowBox: { t })
        await engine.tick(); t = t.addingTimeInterval(2000); await engine.tick()
        #expect(await sink.calls.isEmpty)
    }
}
