import Foundation
import Testing
import AgentMode
@testable import Shell

@MainActor
@Suite("ChatCardWindowController")
struct ChatCardWindowControllerTests {
    @Test("handleSend：乐观追加 user + 流式累积进 assistant row")
    func sendAccumulates() async {
        let ctrl = ChatCardWindowController(streamProvider: { _, _ in
            AsyncThrowingStream { c in
                for d in ["你", "好", "呀"] { c.yield(d) }
                c.finish()
            }
        })
        ctrl.handleSend("在吗")
        await ctrl.cardState.streamTask?.value   // 等流式跑完
        let msgs = ctrl.cardState.messages
        #expect(msgs.count == 2)
        #expect(msgs[0].role == .user)
        #expect(msgs[0].text == "在吗")
        #expect(msgs[1].role == .assistant)
        #expect(msgs[1].text == "你好呀")
        #expect(ctrl.cardState.isSending == false)
        #expect(ctrl.cardState.draft == "")
    }

    @Test("handleSend：空白输入不发送")
    func emptyNoSend() {
        let ctrl = ChatCardWindowController(streamProvider: { _, _ in
            AsyncThrowingStream { $0.finish() }
        })
        ctrl.handleSend("   \n ")
        #expect(ctrl.cardState.messages.isEmpty)
    }

    @Test("handleSend：流式抛错 → assistant row 显示友好文案，isSending 复位")
    func streamErrorShown() async {
        struct Boom: Error {}
        let ctrl = ChatCardWindowController(streamProvider: { _, _ in
            AsyncThrowingStream { c in c.finish(throwing: Boom()) }
        })
        ctrl.handleSend("x")
        await ctrl.cardState.streamTask?.value
        // 与 BondedSession 同一份 LLMErrorMessages 映射:⚠️ 友好文案,不再裸 ❌ + 错误码
        #expect(ctrl.cardState.messages.last?.text.hasPrefix("⚠️") == true)
        #expect(ctrl.cardState.messages.last?.text.contains("回复失败") == true)
        #expect(ctrl.cardState.isSending == false)
    }

    @Test("refreshProjectConfiguration：同步 Codex projection 回调")
    func refreshProjectConfigurationWiresCodexSync() {
        let ctrl = ChatCardWindowController(streamProvider: { _, _ in
            AsyncThrowingStream { $0.finish() }
        })
        var requested = false
        ctrl.projectProvider = {
            (
                current: ProjectOption(id: "p", name: "P", isExternal: true),
                projects: [ProjectOption(id: "p", name: "P", isExternal: true)]
            )
        }
        ctrl.onRequestSyncCodexProjection = {
            requested = true
            return "Codex 配置已同步"
        }

        ctrl.refreshProjectConfiguration()
        ctrl.cardState.requestSyncCodexProjection()

        #expect(requested == true)
        #expect(ctrl.cardState.codexProjectionSyncMessage == "Codex 配置已同步")
    }



    @Test("refreshProjectConfiguration：同步 Claude Code projection 回调")
    func refreshProjectConfigurationWiresClaudeCodeSync() {
        let ctrl = ChatCardWindowController(streamProvider: { _, _ in
            AsyncThrowingStream { $0.finish() }
        })
        var requested = false
        ctrl.projectProvider = {
            (
                current: ProjectOption(id: "p", name: "P", isExternal: true),
                projects: [ProjectOption(id: "p", name: "P", isExternal: true)]
            )
        }
        ctrl.onRequestSyncClaudeCodeProjection = {
            requested = true
            return "Claude Code 配置已同步"
        }

        ctrl.refreshProjectConfiguration()
        ctrl.cardState.requestSyncClaudeCodeProjection()

        #expect(requested == true)
        #expect(ctrl.cardState.codexProjectionSyncMessage == "Claude Code 配置已同步")
    }

    @Test("refreshProjectConfiguration：同步 opencode projection 回调")
    func refreshProjectConfigurationWiresOpencodeSync() {
        let ctrl = ChatCardWindowController(streamProvider: { _, _ in
            AsyncThrowingStream { $0.finish() }
        })
        var requested = false
        ctrl.projectProvider = {
            (
                current: ProjectOption(id: "p", name: "P", isExternal: true),
                projects: [ProjectOption(id: "p", name: "P", isExternal: true)]
            )
        }
        ctrl.onRequestSyncOpencodeProjection = {
            requested = true
            return "opencode 配置已同步"
        }

        ctrl.refreshProjectConfiguration()
        ctrl.cardState.requestSyncOpencodeProjection()

        #expect(requested == true)
        #expect(ctrl.cardState.codexProjectionSyncMessage == "opencode 配置已同步")
    }

    @Test("refreshProjectConfiguration：项目变化时清掉旧项目配置反馈")
    func refreshProjectConfigurationClearsProjectFeedbackOnProjectChange() {
        let ctrl = ChatCardWindowController(streamProvider: { _, _ in
            AsyncThrowingStream { $0.finish() }
        })
        var current = ProjectOption(id: "a", name: "A", isExternal: true)
        ctrl.projectProvider = { (current: current, projects: [current]) }
        ctrl.onRequestSyncCodexProjection = { "Codex 配置已同步" }

        ctrl.refreshProjectConfiguration()
        ctrl.cardState.requestSyncCodexProjection()
        #expect(ctrl.cardState.codexProjectionSyncMessage == "Codex 配置已同步")

        current = ProjectOption(id: "b", name: "B", isExternal: true)
        ctrl.refreshProjectConfiguration()

        #expect(ctrl.cardState.codexProjectionSyncMessage == nil)
    }

    @Test("refreshProjectConfiguration：项目能力管理触发管理入口")
    func refreshProjectConfigurationWiresProjectCapabilityManagerOpenAction() {
        let ctrl = ChatCardWindowController(streamProvider: { _, _ in
            AsyncThrowingStream { $0.finish() }
        })
        var requested = false
        ctrl.projectProvider = {
            (
                current: ProjectOption(id: "p", name: "P", isExternal: true),
                projects: [ProjectOption(id: "p", name: "P", isExternal: true)]
            )
        }
        ctrl.onRequestOpenProjectCapabilityManager = {
            requested = true
        }

        ctrl.refreshProjectConfiguration()
        ctrl.cardState.requestShowProjectCapabilityManager()

        #expect(requested == true)
        #expect(ctrl.cardState.codexProjectionSyncMessage == nil)
    }
}


// MARK: - P7.1 行首 chip wire format + 钉住回补

@MainActor
@Suite("ChatCardWindowController P7.1 composer parts")
struct ChatCardWindowControllerComposerPartsTests {

    private func codexOption() -> MentionOption {
        MentionOption(trigger: "codex", label: "Codex", systemImage: "x", brandLogo: .codex, available: true)
    }

    @Test("行首 chip → 序列化即 wire format(无需烘焙)+ 用户行带 chip + 文本保真;一次性 chip 不回补")
    func sendWithLeadingChip() async {
        final class Box: @unchecked Sendable { var sent: String? }
        let box = Box()
        let ctrl = ChatCardWindowController(streamProvider: { text, _ in
            box.sent = text
            return AsyncThrowingStream { $0.finish() }
        })
        ctrl.cardState.mentionOptions = [codexOption()]
        ctrl.cardState.composerParts = [.mention(trigger: "codex", isPinned: false), .text("看下构建")]

        ctrl.handleSend(ctrl.cardState.draft)
        await ctrl.cardState.streamTask?.value

        #expect(box.sent == "@codex 看下构建")                      // draft 投影已是 wire format
        #expect(ctrl.cardState.messages[0].userMentionTrigger == "codex")
        #expect(ctrl.cardState.messages[0].text == "@codex 看下构建")   // 落盘保真
        #expect(ctrl.cardState.composerParts.isEmpty)                // 一次性 chip 发送后不回补
    }

    @Test("钉住 chip 发送清空后自动回补(tray 常驻的 inline 版)")
    func pinnedChipReinsertedAfterSend() async {
        final class Box: @unchecked Sendable { var sent: String? }
        let box = Box()
        let ctrl = ChatCardWindowController(streamProvider: { text, _ in
            box.sent = text
            return AsyncThrowingStream { $0.finish() }
        })
        ctrl.cardState.mentionOptions = [codexOption()]
        ctrl.cardState.pinnedMentionTrigger = "codex"   // didSet → 行首钉住 chip
        ctrl.cardState.composerParts = [.mention(trigger: "codex", isPinned: true), .text("看下")]

        ctrl.handleSend(ctrl.cardState.draft)
        await ctrl.cardState.streamTask?.value

        #expect(box.sent == "@codex 看下")
        #expect(ctrl.cardState.composerParts == [.mention(trigger: "codex", isPinned: true)])
        #expect(ctrl.cardState.draft == "@codex ")
    }

    @Test("打字完整 @(纯文本无 chip)仍按行首 mention 解析路由")
    func typedMentionTextStillRoutes() async {
        final class Box: @unchecked Sendable { var sent: String? }
        let box = Box()
        let ctrl = ChatCardWindowController(streamProvider: { text, _ in
            box.sent = text
            return AsyncThrowingStream { $0.finish() }
        })
        ctrl.cardState.mentionOptions = [codexOption()]

        ctrl.handleSend("@codex 看下")
        await ctrl.cardState.streamTask?.value

        #expect(box.sent == "@codex 看下")
        #expect(ctrl.cardState.messages[0].userMentionTrigger == "codex")
    }

    @Test("无 chip 无 mention → 原文直发,行无 chip")
    func sendPlain() async {
        final class Box: @unchecked Sendable { var sent: String? }
        let box = Box()
        let ctrl = ChatCardWindowController(streamProvider: { text, _ in
            box.sent = text
            return AsyncThrowingStream { $0.finish() }
        })

        ctrl.handleSend("普通一句")
        await ctrl.cardState.streamTask?.value

        #expect(box.sent == "普通一句")
        #expect(ctrl.cardState.messages[0].userMentionTrigger == nil)
    }
}


// MARK: - P7.2 图片能力门闸

@MainActor
@Suite("ChatCardWindowController P7.2 图片门闸")
struct ChatCardWindowControllerImageGateTests {

    private func makeImage() -> ChatImage {
        ChatImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png")
    }

    @Test("gate false → assistant 行友好文案 + draft/parts/images 恢复 + streamProvider 未调(store 零写入)")
    func gateRejectedRestoresDraft() async {
        final class Box: @unchecked Sendable { var calls = 0 }
        let box = Box()
        let ctrl = ChatCardWindowController(streamProvider: { _, _ in
            box.calls += 1
            return AsyncThrowingStream { $0.finish() }
        })
        ctrl.imageGateProvider = { _, _ in false }
        let image = makeImage()
        ctrl.cardState.composerParts = [.mention(trigger: "codex", isPinned: true), .text("看图")]
        ctrl.cardState.composerImages = [image]

        ctrl.handleSend(ctrl.cardState.draft)
        await ctrl.cardState.streamTask?.value

        #expect(box.calls == 0)                                       // provider 未调(store 零写入)
        #expect(ctrl.cardState.messages.count == 2)                   // 乐观 user + assistant 文案
        #expect(ctrl.cardState.messages[0].images == [image])         // 用户行回显保留
        #expect(ctrl.cardState.messages[1].text == LLMErrorMessages.imageUnsupported)
        #expect(ctrl.cardState.composerParts == [.mention(trigger: "codex", isPinned: true), .text("看图")])
        #expect(ctrl.cardState.draft == "@codex 看图")                // 投影回 wire format
        #expect(ctrl.cardState.composerImages == [image])
        #expect(ctrl.cardState.isSending == false)
    }

    @Test("gate true → images 随 provider 收到并随发送清空")
    func gatePassedSendsImages() async {
        final class Box: @unchecked Sendable { var images: [ChatImage]? }
        let box = Box()
        let ctrl = ChatCardWindowController(streamProvider: { _, images in
            box.images = images
            return AsyncThrowingStream { $0.finish() }
        })
        ctrl.imageGateProvider = { _, _ in true }
        let image = makeImage()
        ctrl.cardState.composerParts = [.text("看图")]
        ctrl.cardState.composerImages = [image]

        ctrl.handleSend(ctrl.cardState.draft)
        await ctrl.cardState.streamTask?.value

        #expect(box.images == [image])
        #expect(ctrl.cardState.composerImages.isEmpty)                // 发送清空
        #expect(ctrl.cardState.messages[0].images == [image])         // 用户行回显
    }

    @Test("无图 → gate 不被调用,provider 收到空数组")
    func noImageSkipsGate() async {
        final class Box: @unchecked Sendable { var gateCalls = 0; var images: [ChatImage]? }
        let box = Box()
        let ctrl = ChatCardWindowController(streamProvider: { _, images in
            box.images = images
            return AsyncThrowingStream { $0.finish() }
        })
        ctrl.imageGateProvider = { _, _ in
            box.gateCalls += 1
            return false   // 即使 false,无图也不应被拦
        }
        ctrl.cardState.composerParts = [.text("纯文本")]

        ctrl.handleSend(ctrl.cardState.draft)
        await ctrl.cardState.streamTask?.value

        #expect(box.gateCalls == 0)
        #expect(box.images == [])
        #expect(ctrl.cardState.messages[1].text != LLMErrorMessages.imageUnsupported)
    }
}
