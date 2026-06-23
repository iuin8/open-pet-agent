// Tests/OrchestratorTests/ProactivityLevelTests.swift
import Foundation
import Testing
@testable import Orchestrator

@Suite("ProactivityLevel")
struct ProactivityLevelTests {
    @Test("4 个级别都有中文 displayName")
    func displayNames() {
        #expect(ProactivityLevel.off.displayName == "关闭")
        #expect(ProactivityLevel.restrained.displayName == "克制·待命")
        #expect(ProactivityLevel.moderate.displayName == "适度·察言观色")
        #expect(ProactivityLevel.active.displayName == "积极·伴侣")
    }

    @Test("CaseIterable 顺序固定（off→restrained→moderate→active）")
    func caseOrder() {
        #expect(ProactivityLevel.allCases == [.off, .restrained, .moderate, .active])
    }

    @Test("Codable round-trip 用 rawValue")
    func codable() throws {
        let data = try JSONEncoder().encode(ProactivityLevel.moderate)
        let decoded = try JSONDecoder().decode(ProactivityLevel.self, from: data)
        #expect(decoded == .moderate)
    }
}
