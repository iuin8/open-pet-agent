import Foundation
import Testing
@testable import Shell

@MainActor
@Suite("ChatCardWindowController")
struct ChatCardWindowControllerTests {
    @Test("handleSend：乐观追加 user + 流式累积进 assistant row")
    func sendAccumulates() async {
        let ctrl = ChatCardWindowController(streamProvider: { _ in
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
        let ctrl = ChatCardWindowController(streamProvider: { _ in
            AsyncThrowingStream { $0.finish() }
        })
        ctrl.handleSend("   \n ")
        #expect(ctrl.cardState.messages.isEmpty)
    }

    @Test("handleSend：流式抛错 → assistant row 显示友好文案，isSending 复位")
    func streamErrorShown() async {
        struct Boom: Error {}
        let ctrl = ChatCardWindowController(streamProvider: { _ in
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
        let ctrl = ChatCardWindowController(streamProvider: { _ in
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
        let ctrl = ChatCardWindowController(streamProvider: { _ in
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
        let ctrl = ChatCardWindowController(streamProvider: { _ in
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
        let ctrl = ChatCardWindowController(streamProvider: { _ in
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
        let ctrl = ChatCardWindowController(streamProvider: { _ in
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


// MARK: - P6.1 一次性目标烘焙与回弹

@MainActor
@Suite("ChatCardWindowController P6.1 一次性目标")
struct ChatCardWindowControllerSelectionTests {

    private func codexOption() -> MentionOption {
        MentionOption(trigger: "codex", label: "Codex", systemImage: "x", brandLogo: .codex, available: true)
    }

    @Test("胶囊选中 → 发送烘焙 @ 前缀 + 选中态清空(回弹)+ 用户行带 chip + 文本保真")
    func sendWithSelectedMention() async {
        final class Box: @unchecked Sendable { var sent: String? }
        let box = Box()
        let ctrl = ChatCardWindowController(streamProvider: { text in
            box.sent = text
            return AsyncThrowingStream { $0.finish() }
        })
        ctrl.cardState.mentionOptions = [codexOption()]
        ctrl.cardState.selectedMentionTrigger = "codex"

        ctrl.handleSend("看下构建")
        await ctrl.cardState.streamTask?.value

        #expect(box.sent == "@codex 看下构建")               // 烘焙进既有路由管线
        #expect(ctrl.cardState.selectedMentionTrigger == nil)  // 发送即回弹
        #expect(ctrl.cardState.messages[0].userMentionTrigger == "codex")
        #expect(ctrl.cardState.messages[0].text == "@codex 看下构建")   // 落盘保真
    }

    @Test("打字完整 @ 时不重复补前缀(打字党优先)")
    func sendWithTypedMentionNoDoubleBake() async {
        final class Box: @unchecked Sendable { var sent: String? }
        let box = Box()
        let ctrl = ChatCardWindowController(streamProvider: { text in
            box.sent = text
            return AsyncThrowingStream { $0.finish() }
        })
        ctrl.cardState.mentionOptions = [codexOption()]
        ctrl.cardState.selectedMentionTrigger = "opencode"   // 胶囊还选着别的 → 打字党赢

        ctrl.handleSend("@codex 看下")
        await ctrl.cardState.streamTask?.value

        #expect(box.sent == "@codex 看下")
        #expect(ctrl.cardState.messages[0].userMentionTrigger == "codex")
    }

    @Test("无选中无 mention → 原文直发,行无 chip")
    func sendPlain() async {
        final class Box: @unchecked Sendable { var sent: String? }
        let box = Box()
        let ctrl = ChatCardWindowController(streamProvider: { text in
            box.sent = text
            return AsyncThrowingStream { $0.finish() }
        })

        ctrl.handleSend("普通一句")
        await ctrl.cardState.streamTask?.value

        #expect(box.sent == "普通一句")
        #expect(ctrl.cardState.messages[0].userMentionTrigger == nil)
    }
}
