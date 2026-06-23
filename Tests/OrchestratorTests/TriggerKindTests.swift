// Tests/OrchestratorTests/TriggerKindTests.swift
import Foundation
import Testing
@testable import Orchestrator

@Suite("TriggerKind")
struct TriggerKindTests {
    @Test("4 个触发类型中文 displayName")
    func displayNames() {
        #expect(TriggerKind.appSwitch.displayName == "应用切换")
        #expect(TriggerKind.idleReturn.displayName == "久未活动")
        #expect(TriggerKind.dwell.displayName == "专注中")
        #expect(TriggerKind.lateNight.displayName == "深夜")
    }

    @Test("ProactiveSignal 默认字段为 nil")
    func signalDefaults() {
        let s = ProactiveSignal(kind: .appSwitch, appName: "Xcode")
        #expect(s.kind == .appSwitch)
        #expect(s.appName == "Xcode")
        #expect(s.windowTitle == nil)
        #expect(s.awaySeconds == nil)
        #expect(s.dwellSeconds == nil)
    }
}
