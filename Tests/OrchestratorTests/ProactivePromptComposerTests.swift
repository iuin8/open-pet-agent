// Tests/OrchestratorTests/ProactivePromptComposerTests.swift
import Testing
@testable import Orchestrator

@Suite("ProactivePromptComposer")
struct ProactivePromptComposerTests {
    @Test("appSwitch prompt 含 appName")
    func appSwitchContainsApp() {
        let sig = ProactiveSignal(kind: .appSwitch, appName: "Xcode")
        let p = ProactivePromptComposer.build(signal: sig, level: .moderate)
        #expect(p.contains("Xcode"))
    }

    @Test("字数上限随 level：克制 30 / 适度 60 / 积极 80")
    func charLimitByLevel() {
        let sig = ProactiveSignal(kind: .lateNight)
        #expect(ProactivePromptComposer.build(signal: sig, level: .restrained).contains("30"))
        #expect(ProactivePromptComposer.build(signal: sig, level: .moderate).contains("60"))
        #expect(ProactivePromptComposer.build(signal: sig, level: .active).contains("80"))
    }

    @Test("不同 kind 关键词不同")
    func kindKeywords() {
        #expect(ProactivePromptComposer.build(signal: ProactiveSignal(kind: .idleReturn), level: .moderate).contains("回到"))
        #expect(ProactivePromptComposer.build(signal: ProactiveSignal(kind: .lateNight), level: .moderate).contains("深夜"))
        #expect(ProactivePromptComposer.build(signal: ProactiveSignal(kind: .dwell, appName: "Figma", dwellSeconds: 700), level: .moderate).contains("Figma"))
    }

    @Test("autonomous：含 appName，自发开口语气")
    func autonomousContainsApp() {
        let sig = ProactiveSignal(kind: .autonomous, appName: "Notion")
        let p = ProactivePromptComposer.build(signal: sig, level: .active)
        #expect(p.contains("Notion"))
        #expect(p.contains("自发"))   // 自发开口语气（旧措辞「主动」已改为「自发」）
    }

    @Test("autonomous：appName 缺失也能组词（兜底语）")
    func autonomousNoApp() {
        let sig = ProactiveSignal(kind: .autonomous, appName: nil)
        let p = ProactivePromptComposer.build(signal: sig, level: .active)
        #expect(!p.isEmpty)
    }
}
