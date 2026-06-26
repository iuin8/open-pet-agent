// Tests/OrchestratorTests/ProactiveSettingsTests.swift
import Foundation
import Testing
@testable import Orchestrator

@Suite("ProactiveSettings")
struct ProactiveSettingsTests {
    @Test("default = moderate + A/B/D 开、C 关、dwell 600；chatter 开、autonomous 关")
    func defaults() {
        let s = ProactiveSettings.default
        #expect(s.level == .moderate)
        #expect(s.triggerAppSwitch == true)
        #expect(s.triggerIdleReturn == true)
        #expect(s.triggerDwell == false)
        #expect(s.triggerLateNight == true)
        #expect(s.dwellThresholdSeconds == 600)
        #expect(s.chatterEnabled == true)        // 生命感低风险，默认开
        #expect(s.triggerAutonomous == false)    // LLM 自主更费/更易烦，opt-in
        #expect(s.personaText == "")             // 默认无 persona
    }

    @Test("chatter 间隔随 level 查表：off/restrained 不触发，moderate 5-10min，active 2-5min")
    func chatterIntervalRange() {
        var s = ProactiveSettings.default
        s.level = .off
        #expect(s.chatterIntervalRange == nil)
        s.level = .restrained
        #expect(s.chatterIntervalRange == nil)
        s.level = .moderate
        #expect(s.chatterIntervalRange == 300...600)
        s.level = .active
        #expect(s.chatterIntervalRange == 120...300)
    }

    @Test("autonomous 间隔随 level 查表：off/restrained/moderate 不触发，active 10-20min")
    func autonomousIntervalRange() {
        var s = ProactiveSettings.default
        s.level = .off
        #expect(s.autonomousIntervalRange == nil)
        s.level = .restrained
        #expect(s.autonomousIntervalRange == nil)
        s.level = .moderate
        #expect(s.autonomousIntervalRange == nil)   // moderate 默认不开 autonomous
        s.level = .active
        #expect(s.autonomousIntervalRange == 600...1200)
    }

    @Test("节流参数随 level 查表")
    func throttleParams() {
        var s = ProactiveSettings.default
        s.level = .restrained
        #expect(s.minIntervalSeconds == 1800)
        #expect(s.maxPerHour == 2)
        #expect(s.ignoreDecayThreshold == 2)
        #expect(s.ignoreDecayMultiplier == 2.0)

        s.level = .moderate
        #expect(s.minIntervalSeconds == 600)
        #expect(s.maxPerHour == 4)
        #expect(s.ignoreDecayThreshold == 3)
        #expect(s.ignoreDecayMultiplier == 1.5)

        s.level = .active
        #expect(s.minIntervalSeconds == 180)
        #expect(s.maxPerHour == 8)
        #expect(s.ignoreDecayThreshold == 5)
        #expect(s.ignoreDecayMultiplier == 1.2)

        s.level = .off
        #expect(s.maxPerHour == 0)
        #expect(s.minIntervalSeconds == .infinity)
    }

    @Test("Codable round-trip（含 chatter/autonomous 新字段）")
    func codable() throws {
        var s = ProactiveSettings.default
        s.level = .active
        s.triggerDwell = true
        s.dwellThresholdSeconds = 420
        s.chatterEnabled = false
        s.triggerAutonomous = true
        s.personaText = "叫我老王，后端工程师，说话随意点"
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ProactiveSettings.self, from: data)
        #expect(decoded == s)
        #expect(decoded.personaText == "叫我老王，后端工程师，说话随意点")
    }

    @Test("部分字段 legacy JSON → 缺的字段用默认值解码成功（含新增 chatter/autonomous）")
    func partialJSONDecodesWithDefaults() throws {
        let legacy = #"{"level":"active"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ProactiveSettings.self, from: legacy)
        #expect(decoded.level == .active)
        #expect(decoded.triggerAppSwitch == true)      // 缺 → 默认
        #expect(decoded.dwellThresholdSeconds == 600)  // 缺 → 默认
        #expect(decoded.chatterEnabled == true)        // 缺 → 默认开
        #expect(decoded.triggerAutonomous == false)    // 缺 → 默认关
        #expect(decoded.personaText == "")             // 缺 → 默认空（老用户升级不报错）
    }
}
