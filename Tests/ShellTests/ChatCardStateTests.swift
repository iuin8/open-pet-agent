import Foundation
import Testing
@testable import Shell

@MainActor
@Suite("ChatCardState")
struct ChatCardStateTests {
    @Test("乐观追加：一条 user + 一条空 assistant，返回 assistant id")
    func appendPlaceholder() {
        let s = ChatCardState()
        let aid = s.appendExchangePlaceholder(userText: "你好")
        #expect(s.messages.count == 2)
        #expect(s.messages[0].role == .user)
        #expect(s.messages[0].text == "你好")
        #expect(s.messages[1].role == .assistant)
        #expect(s.messages[1].text == "")
        #expect(s.messages[1].id == aid)
    }

    @Test("流式覆写：updateAssistant 按 id 覆写文本")
    func updateAssistantOverwrites() {
        let s = ChatCardState()
        let aid = s.appendExchangePlaceholder(userText: "在吗")
        s.updateAssistant(id: aid, text: "在的")
        s.updateAssistant(id: aid, text: "在的，怎么啦")   // 覆写非追加
        #expect(s.messages[1].text == "在的，怎么啦")
    }

    @Test("load(history:) 用快照重填消息")
    func loadHistory() {
        let s = ChatCardState()
        _ = s.appendExchangePlaceholder(userText: "旧的")
        s.load(history: [
            ChatCardRow(role: .user, text: "历史问"),
            ChatCardRow(role: .assistant, text: "历史答"),
        ])
        #expect(s.messages.count == 2)
        #expect(s.messages[0].text == "历史问")
        #expect(s.messages[1].text == "历史答")
    }

    @Test("cancelStreaming 停流但保留 messages")
    func cancelKeepsMessages() {
        let s = ChatCardState()
        _ = s.appendExchangePlaceholder(userText: "x")
        s.isSending = true
        s.cancelStreaming()
        #expect(s.isSending == false)
        #expect(s.messages.count == 2)   // 重开仍在
    }
}
