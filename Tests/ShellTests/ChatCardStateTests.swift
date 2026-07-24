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

    @Test("上下文用量字段:默认 nil(无 usage_update 数据,composer 不显示占用条)")
    func contextUsageDefaultsNil() {
        let s = ChatCardState()
        #expect(s.contextUsed == nil)
        #expect(s.contextSize == nil)
        #expect(s.contextCost == nil)
    }

    @Test("上下文用量字段:写入 used/size/cost 后可读(ACP usage_update 落点,驱动占用条显隐)")
    func contextUsageRoundTrip() {
        let s = ChatCardState()
        s.contextUsed = 12_345
        s.contextSize = 200_000
        s.contextCost = "$0.0123"
        #expect(s.contextUsed == 12_345)
        #expect(s.contextSize == 200_000)
        #expect(s.contextCost == "$0.0123")
    }

    @Test("ACP 会话字段:默认空/关/不在途(能力探测前 popover 不显示,P2)")
    func acpSessionDefaults() {
        let s = ChatCardState()
        #expect(s.acpSessions.isEmpty)
        #expect(s.acpSessionUIEnabled == false)
        #expect(s.isLoadingACPSessions == false)
    }
}


// MARK: - P5 @mention 署名

@MainActor
@Suite("ChatCardState P5 来源署名")
struct ChatCardStateSourceTests {
    @Test("appendExchangePlaceholder 带 assistantSource → assistant 行 source;user 行无")
    func appendPlaceholderWithSource() {
        let s = ChatCardState()
        let aid = s.appendExchangePlaceholder(userText: "@codex 看下", assistantSource: "Codex")
        #expect(s.messages[0].source == nil)
        #expect(s.messages[1].source == "Codex")
        #expect(s.messages[1].id == aid)
    }

    @Test("ChatCardRow 默认 source nil(无 chip,旧行为不变)")
    func rowSourceDefaultsNil() {
        #expect(ChatCardRow(role: .assistant, text: "x").source == nil)
        let s = ChatCardState()
        _ = s.appendExchangePlaceholder(userText: "普通")
        #expect(s.messages[1].source == nil)
    }
}
