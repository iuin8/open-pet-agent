import Foundation
import Testing
@testable import Orchestrator

// P5 ConversationMessage.source(engine 署名)单测:Codable 兼容是重点 ——
// 旧格式 JSON(无 source 键)必须零迁移解码;新格式 roundtrip 保留署名。

@Suite("ConversationMessage source(P5 署名)")
struct ConversationMessageSourceTests {

    @Test("source 编解码 roundtrip 保留")
    func sourceRoundtrip() throws {
        let m = ConversationMessage(role: .assistant, content: "答", source: "codex")
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ConversationMessage.self, from: data)
        #expect(back.source == "codex")
        #expect(back == m)
    }

    @Test("旧格式 JSON(无 source/model 键)→ 解码 source nil,不炸")
    func legacyJSONDecodes() throws {
        // 手写旧格式(不依赖新 encoder 行为):P5 前的持久化消息就长这样。
        let legacyJSON = """
            {"id":"\(UUID().uuidString)","role":"assistant","content":"旧消息","timestamp":778777200}
            """
        let back = try JSONDecoder().decode(
            ConversationMessage.self, from: Data(legacyJSON.utf8))
        #expect(back.source == nil)
        #expect(back.model == nil)
        #expect(back.content == "旧消息")
        #expect(back.role == .assistant)
    }

    @Test("默认 init 不带 source → nil(灵魂层/用户消息无署名)")
    func sourceDefaultsNil() {
        #expect(ConversationMessage(role: .user, content: "问").source == nil)
        #expect(ConversationMessage(role: .assistant, content: "答").source == nil)
    }
}
