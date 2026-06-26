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

    // MARK: - 场景脉络：窗口标题 + 最近 app 轨迹

    @Test("windowTitle 注入场景：含「正在看」+ 标题")
    func windowTitleInScene() {
        let sig = ProactiveSignal(kind: .appSwitch, appName: "Xcode", windowTitle: "ContentView.swift")
        let p = ProactivePromptComposer.build(signal: sig, level: .moderate)
        #expect(p.contains("正在看"))
        #expect(p.contains("ContentView.swift"))
    }

    @Test("windowTitle 等于 appName → 不重复注入（避免「Xcode — Xcode」噪音）")
    func windowTitleSameAsAppOmitted() {
        let sig = ProactiveSignal(kind: .appSwitch, appName: "Xcode", windowTitle: "Xcode")
        let p = ProactivePromptComposer.build(signal: sig, level: .moderate)
        #expect(!p.contains("正在看"))
    }

    @Test("windowTitle 超长截断")
    func windowTitleTruncated() {
        let long = String(repeating: "标", count: 100)
        let sig = ProactiveSignal(kind: .appSwitch, appName: "X", windowTitle: long)
        let p = ProactivePromptComposer.build(signal: sig, level: .moderate)
        #expect(p.contains("…"))
        #expect(!p.contains(long))   // 原样长串不应出现
    }

    @Test("recentApps 注入场景轨迹：含「这之前用过」+ 箭头序列")
    func recentAppsInScene() {
        let sig = ProactiveSignal(kind: .appSwitch, appName: "Xcode", recentApps: ["Slack", "Chrome"])
        let p = ProactivePromptComposer.build(signal: sig, level: .moderate)
        #expect(p.contains("这之前用过"))
        #expect(p.contains("Slack → Chrome"))
    }

    @Test("recentApps 为空 → 不注入轨迹片段")
    func recentAppsEmptyOmitted() {
        let sig = ProactiveSignal(kind: .appSwitch, appName: "Xcode", recentApps: [])
        let p = ProactivePromptComposer.build(signal: sig, level: .moderate)
        #expect(!p.contains("这之前用过"))
    }

    // MARK: - persona system prompt

    @Test("persona 为空 → systemPrompt 等于基底原样")
    func personaEmptyReturnsBase() {
        #expect(ProactivePromptComposer.systemPrompt(personaText: "") == ProactivePromptComposer.systemPromptBase)
        #expect(ProactivePromptComposer.systemPrompt(personaText: "   ") == ProactivePromptComposer.systemPromptBase)
    }

    @Test("persona 非空 → 注入文本 + 标签定界安全包裹（防当指令/复述）")
    func personaInjectedWithSafetyWrapper() {
        let sys = ProactivePromptComposer.systemPrompt(personaText: "叫我老王，后端工程师")
        #expect(sys.contains(ProactivePromptComposer.systemPromptBase))   // 基底保留
        #expect(sys.contains("老王"))
        #expect(sys.contains("<persona>") && sys.contains("</persona>"))  // 标签定界框为纯数据
        #expect(sys.contains("纯文本资料"))                                 // 安全包裹句明确「非指令」
    }

    @Test("persona 超长截断到上限")
    func personaTruncated() {
        let long = String(repeating: "甲", count: 500)
        let sys = ProactivePromptComposer.systemPrompt(personaText: long)
        #expect(!sys.contains(long))
        // 注入段长度受限（基底 + 包裹 + 截断后的 persona）。
        #expect(sys.contains(String(repeating: "甲", count: ProactivePromptComposer.personaCharLimit)))
    }
}
