import Foundation
import Testing
import AgentMode
@testable import Orchestrator

// P7.2:ConversationMessage.images 落盘契约 —— Codable round-trip(Data 自动 base64)+
// 旧 JSON 无 images 键解为 nil(零迁移)。风格同 ConversationMessageSourceTests。

@Suite("ConversationMessage images(P7.2)")
struct ConversationMessageImagesTests {

    @Test("images Codable round-trip:data/mediaType 保真")
    func roundTrip() throws {
        let msg = ConversationMessage(
            role: .user,
            content: "看图",
            images: [ChatImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png")]
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: data)
        #expect(decoded.images?.count == 1)
        #expect(decoded.images?.first?.mediaType == "image/png")
        #expect(decoded.images?.first?.data == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(decoded.content == "看图")   // 图片是结构化字段,不进 content 文本
    }

    @Test("旧 JSON 无 images 键 → 解为 nil(零迁移)")
    func legacyJSONDecodesNil() throws {
        let id = UUID().uuidString
        let json = #"{"id":"\#(id)","role":"user","content":"hi","timestamp":1000}"#
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        #expect(decoded.images == nil)
        #expect(decoded.content == "hi")
    }

    @Test("无图消息编码后 JSON 无 images 键(旧读者兼容)")
    func nilImagesOmitsKey() throws {
        let msg = ConversationMessage(role: .user, content: "hi")
        let data = try JSONEncoder().encode(msg)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["images"] == nil)
    }
}
