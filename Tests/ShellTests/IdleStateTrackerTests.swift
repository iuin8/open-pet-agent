import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("IdleStateTracker — 系统空闲检测")
struct IdleStateTrackerTests {

    @Test("初始 isSleeping == false (未启动也不算 sleeping)")
    func initialNotSleeping() {
        let tracker = IdleStateTracker(idleSecondsProvider: { 0 })
        #expect(tracker.isSleeping == false)
    }

    @Test("tick: idle 秒数 >= 阈值 → 进入 sleeping + 触发 callback")
    func tickIntoSleeping() {
        var captured: [Bool] = []
        let tracker = IdleStateTracker(
            sleepThresholdSeconds: 180,
            idleSecondsProvider: { 200 }
        )
        tracker.onSleepingChanged = { captured.append($0) }

        tracker.tick()
        #expect(tracker.isSleeping == true)
        #expect(captured == [true])
    }

    @Test("tick: idle 秒数 < 阈值 → 保持非 sleeping,不触发 callback")
    func tickStaysActive() {
        var callCount = 0
        let tracker = IdleStateTracker(
            sleepThresholdSeconds: 180,
            idleSecondsProvider: { 100 }
        )
        tracker.onSleepingChanged = { _ in callCount += 1 }

        tracker.tick()
        #expect(tracker.isSleeping == false)
        #expect(callCount == 0)
    }

    @Test("tick: sleeping → 用户回来(idle 重置)→ 切回非 sleeping + callback")
    func tickWakeUp() {
        var captured: [Bool] = []
        var idleSeconds: TimeInterval = 200

        let tracker = IdleStateTracker(
            sleepThresholdSeconds: 180,
            idleSecondsProvider: { idleSeconds }
        )
        tracker.onSleepingChanged = { captured.append($0) }

        tracker.tick()    // 200s ≥ 180 → true
        idleSeconds = 5
        tracker.tick()    // 5s < 180 → false

        #expect(captured == [true, false])
        #expect(tracker.isSleeping == false)
    }

    @Test("tick: 同状态反复 tick 不重复 callback(去重)")
    func tickDeduplicates() {
        var callCount = 0
        let tracker = IdleStateTracker(
            sleepThresholdSeconds: 180,
            idleSecondsProvider: { 200 }
        )
        tracker.onSleepingChanged = { _ in callCount += 1 }

        tracker.tick()
        tracker.tick()
        tracker.tick()

        #expect(callCount == 1)  // 只第一次 true 触发
    }

    @Test("start / stop 是幂等的(start 立即 tick 一次)")
    func startStopIdempotent() {
        var callCount = 0
        let tracker = IdleStateTracker(
            sleepThresholdSeconds: 180,
            tickInterval: 10,  // 不会真正过 10s,只关心 start 后立即一次 tick
            idleSecondsProvider: { 200 }
        )
        tracker.onSleepingChanged = { _ in callCount += 1 }

        #expect(tracker.isRunning == false)
        tracker.start()
        #expect(tracker.isRunning == true)
        #expect(callCount == 1)  // start 立即 tick 一次

        tracker.start()  // 二次 start: 重置 timer 也 tick 一次但状态不变 → 不调 callback
        #expect(callCount == 1)

        tracker.stop()
        #expect(tracker.isRunning == false)
        #expect(tracker.isSleeping == true)  // stop 不重置状态

        tracker.stop()  // 二次 stop no-op
        #expect(tracker.isRunning == false)
    }

    @Test("阈值边界:idle 秒数恰好等于阈值 → sleeping = true (>= 而非 >)")
    func thresholdBoundary() {
        let tracker = IdleStateTracker(
            sleepThresholdSeconds: 180,
            idleSecondsProvider: { 180 }
        )
        tracker.tick()
        #expect(tracker.isSleeping == true)
    }
}
