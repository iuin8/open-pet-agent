// Tests/OrchestratorTests/ProactiveTriggerEvaluatorTests.swift
import Foundation
import Testing
@testable import Orchestrator

@Suite("ProactiveTriggerEvaluator")
struct ProactiveTriggerEvaluatorTests {
    private func settings(_ mutate: (inout ProactiveSettings) -> Void) -> ProactiveSettings {
        var s = ProactiveSettings.default
        mutate(&s)
        return s
    }

    @Test("off → 任何 signal 都 nil")
    func offGate() {
        let s = settings { $0.level = .off }
        let sig = ProactiveSignal(kind: .appSwitch, appName: "Xcode")
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: s, hour: 12, isSleeping: false) == nil)
    }

    @Test("A 切换：开关开 + 有 appName → appSwitch；开关关 → nil")
    func appSwitch() {
        let on = settings { $0.triggerAppSwitch = true }
        let off = settings { $0.triggerAppSwitch = false }
        let sig = ProactiveSignal(kind: .appSwitch, appName: "Xcode")
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: on, hour: 12, isSleeping: false) == .appSwitch)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: off, hour: 12, isSleeping: false) == nil)
        // 开关开但 appName 为 nil → 仍不触发
        let noApp = ProactiveSignal(kind: .appSwitch, appName: nil)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: noApp, settings: on, hour: 12, isSleeping: false) == nil)
    }

    @Test("B idle：awaySeconds 边界 179 vs 180")
    func idleBoundary() {
        let s = settings { $0.triggerIdleReturn = true }
        let below = ProactiveSignal(kind: .idleReturn, awaySeconds: 179)
        let at = ProactiveSignal(kind: .idleReturn, awaySeconds: 180)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: below, settings: s, hour: 12, isSleeping: false) == nil)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: at, settings: s, hour: 12, isSleeping: false) == .idleReturn)
    }

    @Test("C dwell：阈值边界 599 vs 600 + sleeping 时不触发")
    func dwellBoundary() {
        let s = settings { $0.triggerDwell = true; $0.dwellThresholdSeconds = 600 }
        let below = ProactiveSignal(kind: .dwell, appName: "Xcode", dwellSeconds: 599)
        let at = ProactiveSignal(kind: .dwell, appName: "Xcode", dwellSeconds: 600)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: below, settings: s, hour: 12, isSleeping: false) == nil)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: at, settings: s, hour: 12, isSleeping: false) == .dwell)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: at, settings: s, hour: 12, isSleeping: true) == nil)
    }

    @Test("E autonomous：开关开 + 非睡眠 → autonomous；开关关 / 睡眠 → nil")
    func autonomous() {
        let on = settings { $0.triggerAutonomous = true }
        let off = settings { $0.triggerAutonomous = false }
        let sig = ProactiveSignal(kind: .autonomous, appName: "Notion")
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: on, hour: 14, isSleeping: false) == .autonomous)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: off, hour: 14, isSleeping: false) == nil)
        // 睡眠中 → 不打扰
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: on, hour: 14, isSleeping: true) == nil)
        // off level → nil（顶层 gate）
        let levelOff = settings { $0.triggerAutonomous = true; $0.level = .off }
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: levelOff, hour: 14, isSleeping: false) == nil)
    }

    @Test("D 深夜：跨夜窗口 hour>=23 || hour<5；22/5 不触发，23/4/0 触发")
    func lateNightWindow() {
        let s = settings { $0.triggerLateNight = true }
        let sig = ProactiveSignal(kind: .lateNight)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: s, hour: 22, isSleeping: false) == nil)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: s, hour: 5, isSleeping: false) == nil)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: s, hour: 23, isSleeping: false) == .lateNight)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: s, hour: 4, isSleeping: false) == .lateNight)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: s, hour: 0, isSleeping: false) == .lateNight)
        #expect(ProactiveTriggerEvaluator.evaluate(signal: sig, settings: s, hour: 2, isSleeping: true) == nil)
    }
}
