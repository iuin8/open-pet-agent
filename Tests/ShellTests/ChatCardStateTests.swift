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


// MARK: - P5 follow-up @mention 补全

@MainActor
@Suite("ChatCardState @mention / pin 配置")
struct ChatCardStateMentionTests {
    @Test("默认:候选空 + 未钉(nil = 默认灵魂层)+ pin 回调 nil")
    func mentionDefaultsOff() {
        let s = ChatCardState()
        #expect(s.mentionOptions.isEmpty)
        #expect(s.pinnedMentionTrigger == nil)
        #expect(s.onPinMentionTrigger == nil)
        #expect(s.onUnpinMention == nil)
    }
}


// MARK: - P6.1 一次性目标(chip + 落盘保真)

@MainActor
@Suite("ChatCardState P6.1 一次性目标")
struct ChatCardStateSelectionTests {
    @Test("appendExchangePlaceholder 带 userMentionTrigger → user 行记录;assistant 行无;文本保真")
    func placeholderUserMention() {
        let s = ChatCardState()
        _ = s.appendExchangePlaceholder(userText: "@codex 看下", userMentionTrigger: "codex")
        #expect(s.messages[0].userMentionTrigger == "codex")
        #expect(s.messages[0].text == "@codex 看下")   // 落盘/行文本保留 @ 原文
        #expect(s.messages[1].userMentionTrigger == nil)
    }
}


// MARK: - P7.1 composerParts 投影 + pinned chip 同步

@MainActor
@Suite("ChatCardState composerParts(P7.1)")
struct ChatCardStateComposerPartsTests {
    @Test("默认:parts 空,draft 空(selectedMentionTrigger 已随 P6.2 tray 退役)")
    func defaults() {
        let s = ChatCardState()
        #expect(s.composerParts.isEmpty)
        #expect(s.draft == "")
    }

    @Test("外部写 draft → parts 文本投影(prefill/clear 路径零改动)")
    func draftToParts() {
        let s = ChatCardState()
        s.draft = "你好"
        #expect(s.composerParts == [.text("你好")])
        s.draft = ""
        #expect(s.composerParts.isEmpty)
    }

    @Test("写 parts → draft 序列化投影(wire format,行首 chip → '@trigger ')")
    func partsToDraft() {
        let s = ChatCardState()
        s.composerParts = [.mention(trigger: "codex", isPinned: true), .text("看日志")]
        #expect(s.draft == "@codex 看日志")
    }

    @Test("syncPinnedChip:parts 空 + pinned → 行首重插钉住 chip(发送后回补/tray 常驻)")
    func pinnedReinsert() {
        let s = ChatCardState()
        s.pinnedMentionTrigger = "codex"   // didSet → syncPinnedChip
        #expect(s.composerParts == [.mention(trigger: "codex", isPinned: true)])
        #expect(s.draft == "@codex ")
    }

    @Test("syncPinnedChip:pinned 变 nil 且行首是钉住 chip → 移除(取消钉住)")
    func unpinRemovesChip() {
        let s = ChatCardState()
        s.pinnedMentionTrigger = "codex"
        s.composerParts = [.mention(trigger: "codex", isPinned: true), .text("正文")]
        s.pinnedMentionTrigger = nil
        #expect(s.composerParts == [.text("正文")])
    }

    @Test("syncPinnedChip:行首一次性 chip 的 trigger 被钉住(菜单钉住回环)→ 转钉住深色")
    func pinMarksLeadingChip() {
        let s = ChatCardState()
        s.composerParts = [.mention(trigger: "claude", isPinned: false), .text("正文")]
        s.pinnedMentionTrigger = "claude"
        #expect(s.composerParts.first == .mention(trigger: "claude", isPinned: true))
    }

    @Test("syncPinnedChip:已有正文时 pinned 到来不强插 chip(只认空 parts)")
    func noInsertWhenTyping() {
        let s = ChatCardState()
        s.composerParts = [.text("正在写")]
        s.pinnedMentionTrigger = "codex"
        #expect(s.composerParts == [.text("正在写")])
    }
}
