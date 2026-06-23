// Tests/OrchestratorTests/ProactiveThrottleStateTests.swift
import Foundation
import Testing
@testable import Orchestrator

@Suite("ProactiveThrottleState")
struct ProactiveThrottleStateTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func moderate() -> ProactiveSettings { var s = ProactiveSettings.default; s.level = .moderate; return s }

    @Test("off → false")
    func off() {
        var s = ProactiveSettings.default; s.level = .off
        #expect(ProactiveThrottleState().decide(settings: s, now: t0) == false)
    }

    @Test("首次（无 lastFiredAt）→ true")
    func firstFire() {
        #expect(ProactiveThrottleState().decide(settings: moderate(), now: t0) == true)
    }

    @Test("冷却内 → false；冷却过 → true（moderate 600s）")
    func cooldown() {
        let fired = ProactiveThrottleState().recordFired(now: t0)
        #expect(fired.decide(settings: moderate(), now: t0.addingTimeInterval(599)) == false)
        #expect(fired.decide(settings: moderate(), now: t0.addingTimeInterval(601)) == true)
    }

    @Test("每小时配额打满 → false（moderate 4 条）")
    func hourlyCap() {
        var s = ProactiveThrottleState()
        for i in 0..<4 { s = s.recordFired(now: t0.addingTimeInterval(Double(i))) }
        // 4 条都在近 1h 内 → 即便冷却已过也被配额拦
        #expect(s.decide(settings: moderate(), now: t0.addingTimeInterval(700)) == false)
        // 推到 1h 后，旧的滑出窗口 → 放行
        #expect(s.decide(settings: moderate(), now: t0.addingTimeInterval(3601)) == true)
    }

    @Test("ignore-decay：攒满 threshold 次连续忽略 → 冷却乘 multiplier")
    func ignoreDecay() {
        // moderate: threshold 3, multiplier 1.5, base 600 → 攒 3 次忽略后冷却 = 900s
        var s = ProactiveThrottleState().recordFired(now: t0)
        for _ in 0..<3 { s = s.recordIgnored() }
        #expect(s.decide(settings: moderate(), now: t0.addingTimeInterval(899)) == false)
        #expect(s.decide(settings: moderate(), now: t0.addingTimeInterval(901)) == true)
    }

    @Test("decay 硬 cap 4×base")
    func decayCap() {
        // 攒巨量忽略 → 冷却不超过 4×600 = 2400s
        var s = ProactiveThrottleState().recordFired(now: t0)
        for _ in 0..<100 { s = s.recordIgnored() }
        #expect(s.decide(settings: moderate(), now: t0.addingTimeInterval(2399)) == false)
        #expect(s.decide(settings: moderate(), now: t0.addingTimeInterval(2401)) == true)
    }

    @Test("recordEngaged 归零 decay 恢复节奏")
    func engagedResets() {
        var s = ProactiveThrottleState().recordFired(now: t0)
        for _ in 0..<10 { s = s.recordIgnored() }
        s = s.recordEngaged()
        // 归零后冷却回到 base 600
        #expect(s.decide(settings: moderate(), now: t0.addingTimeInterval(601)) == true)
    }

    @Test("record* 返回新 state 不就地改原 state")
    func immutable() {
        let original = ProactiveThrottleState()
        _ = original.recordFired(now: t0)
        _ = original.recordIgnored()
        #expect(original.lastFiredAt == nil)
        #expect(original.consecutiveIgnoreCount == 0)
        #expect(original.recentFiredTimes.isEmpty)
    }
}
