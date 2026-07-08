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

    @Test("handleSend：流式抛错 → assistant row 显示错误，isSending 复位")
    func streamErrorShown() async {
        struct Boom: Error {}
        let ctrl = ChatCardWindowController(streamProvider: { _ in
            AsyncThrowingStream { c in c.finish(throwing: Boom()) }
        })
        ctrl.handleSend("x")
        await ctrl.cardState.streamTask?.value
        #expect(ctrl.cardState.messages.last?.text.hasPrefix("❌") == true)
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

    @Test("refreshProjectConfiguration：项目能力诊断回调写入面板状态")
    func refreshProjectConfigurationWiresProjectCapabilityDiagnostics() {
        let ctrl = ChatCardWindowController(streamProvider: { _ in
            AsyncThrowingStream { $0.finish() }
        })
        var requested = false
        let panel = ProjectCapabilityPanelState(
            fullText: "Codex\n写入生成文件: /tmp/project/.codex/config.toml",
            sections: [
                ProjectCapabilityPanelState.Section(
                    engineName: "Codex",
                    status: .ready,
                    ownership: "OpenPetAgent 生成内容",
                    rows: [
                        ProjectCapabilityPanelState.Row(
                            kind: "写入生成文件",
                            target: "/tmp/project/.codex/config.toml",
                            detail: nil,
                            copyText: "/tmp/project/.codex/config.toml"
                        )
                    ],
                    diagnostics: []
                )
            ]
        )
        ctrl.projectProvider = {
            (
                current: ProjectOption(id: "p", name: "P", isExternal: true),
                projects: [ProjectOption(id: "p", name: "P", isExternal: true)]
            )
        }
        ctrl.onRequestShowProjectCapabilityDiagnostics = {
            requested = true
            return panel
        }

        ctrl.refreshProjectConfiguration()
        ctrl.cardState.requestShowProjectCapabilityDiagnostics()

        #expect(requested == true)
        #expect(ctrl.cardState.projectCapabilityPanel == panel)
        #expect(ctrl.cardState.codexProjectionSyncMessage == nil)
    }

    @Test("refreshProjectConfiguration：项目变化时清掉旧项目配置反馈")
    func refreshProjectConfigurationClearsProjectFeedbackOnProjectChange() {
        let ctrl = ChatCardWindowController(streamProvider: { _ in
            AsyncThrowingStream { $0.finish() }
        })
        let panel = ProjectCapabilityPanelState(
            fullText: "Codex",
            sections: [ProjectCapabilityPanelState.Section(engineName: "Codex", status: .empty, ownership: nil, rows: [], diagnostics: [])]
        )
        var current = ProjectOption(id: "a", name: "A", isExternal: true)
        ctrl.projectProvider = { (current: current, projects: [current]) }
        ctrl.onRequestSyncCodexProjection = { "Codex 配置已同步" }
        ctrl.onRequestShowProjectCapabilityDiagnostics = { panel }

        ctrl.refreshProjectConfiguration()
        ctrl.cardState.requestSyncCodexProjection()
        ctrl.cardState.requestShowProjectCapabilityDiagnostics()
        #expect(ctrl.cardState.codexProjectionSyncMessage == nil)
        #expect(ctrl.cardState.projectCapabilityPanel == panel)

        current = ProjectOption(id: "b", name: "B", isExternal: true)
        ctrl.refreshProjectConfiguration()

        #expect(ctrl.cardState.codexProjectionSyncMessage == nil)
        #expect(ctrl.cardState.projectCapabilityPanel == nil)
    }

    @Test("refreshProjectConfiguration：项目能力管理 toggle 后保留当前 tab")
    func projectCapabilityManagerTogglePreservesSelectedTab() {
        let ctrl = ChatCardWindowController(streamProvider: { _ in
            AsyncThrowingStream { $0.finish() }
        })
        let manager = ProjectCapabilityCardState(
            selectedTab: .mcp,
            items: [ProjectCapabilityCardState.Item(
                id: "mcp:dev-toolkit:filesystem",
                kind: .mcp,
                name: "filesystem",
                pluginID: "dev-toolkit",
                sourcePath: "/tmp/repo/.open-pet-agent/plugins/dev-toolkit/mcp/servers.json#filesystem",
                targetPaths: [],
                isEnabled: true,
                status: .enabled,
                diagnostics: []
            )]
        )
        ctrl.projectProvider = {
            (
                current: ProjectOption(id: "p", name: "P", isExternal: true),
                projects: [ProjectOption(id: "p", name: "P", isExternal: true)]
            )
        }
        ctrl.onRequestShowProjectCapabilityManager = { manager }
        ctrl.onRequestSetProjectPluginEnabled = { _, _ in
            ProjectCapabilityCardState(selectedTab: .skills, items: manager.items)
        }

        ctrl.refreshProjectConfiguration()
        ctrl.cardState.requestShowProjectCapabilityManager()
        ctrl.cardState.setProjectPluginEnabled(pluginID: "dev-toolkit", enabled: false)

        #expect(ctrl.cardState.projectCapabilityManager?.selectedTab == .mcp)
    }
}
