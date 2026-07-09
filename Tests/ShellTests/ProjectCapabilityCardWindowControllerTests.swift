import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("ProjectCapabilityCardWindowController")
struct ProjectCapabilityCardWindowControllerTests {
    @Test("show：独立窗口显示项目能力卡片")
    func showPresentsStandaloneWindow() {
        let controller = ProjectCapabilityCardWindowController()
        let item = ProjectCapabilityCardState.Item(
            id: "skill:dev-toolkit:lint",
            kind: .skill,
            name: "lint",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/skills/lint",
            targetPaths: [],
            status: .enabled,
            diagnostics: []
        )

        controller.show(
            card: ProjectCapabilityCardState(selectedTab: .skills, items: [item]),
            petRect: NSRect(x: 120, y: 120, width: 64, height: 64),
            screen: NSRect(x: 0, y: 0, width: 800, height: 600),
            onSetEnabled: { _, _ in ProjectCapabilityCardState(selectedTab: .skills, items: [item]) },
            onCreatePlugin: { _, _ in ProjectCapabilityCardState(selectedTab: .skills, items: [item]) },
            onAddSkill: { _, _ in ProjectCapabilityCardState(selectedTab: .skills, items: [item]) },
            onAddMCP: { _, _, _ in ProjectCapabilityCardState(selectedTab: .mcp, items: [item]) },
            onSyncCodex: { "Codex 配置已同步" },
            onSyncClaudeCode: { "Claude Code 配置已同步" },
            onSyncOpencode: { "opencode 配置已同步" }
        )

        #expect(controller.window?.isVisible == true)
        #expect(controller.window?.isMovableByWindowBackground == true)
        controller.hide()
    }

    @Test("toggle：刷新后保留当前 tab")
    func togglePreservesSelectedTab() {
        let controller = ProjectCapabilityCardWindowController()
        let item = ProjectCapabilityCardState.Item(
            id: "mcp:dev-toolkit:filesystem",
            kind: .mcp,
            name: "filesystem",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/mcp/servers.json#filesystem",
            targetPaths: [],
            isEnabled: true,
            status: .enabled,
            diagnostics: []
        )
        controller.show(
            card: ProjectCapabilityCardState(selectedTab: .mcp, items: [item]),
            petRect: .zero,
            screen: NSRect(x: 0, y: 0, width: 800, height: 600),
            onSetEnabled: { _, _ in ProjectCapabilityCardState(selectedTab: .skills, items: [item]) },
            onCreatePlugin: { _, _ in ProjectCapabilityCardState(selectedTab: .skills, items: [item]) },
            onAddSkill: { _, _ in ProjectCapabilityCardState(selectedTab: .skills, items: [item]) },
            onAddMCP: { _, _, _ in ProjectCapabilityCardState(selectedTab: .mcp, items: [item]) },
            onSyncCodex: { "Codex 配置已同步" },
            onSyncClaudeCode: { "Claude Code 配置已同步" },
            onSyncOpencode: { "opencode 配置已同步" }
        )

        controller.setPluginEnabled(pluginID: "dev-toolkit", enabled: false)

        #expect(controller.card.selectedTab == .mcp)
        controller.hide()
    }

    @Test("sync：三路同步按钮回调在卡片内记录结果")
    func syncActionsRecordMessages() {
        let controller = ProjectCapabilityCardWindowController()
        let card = ProjectCapabilityCardState(selectedTab: .skills, items: [])
        controller.show(
            card: card,
            petRect: .zero,
            screen: NSRect(x: 0, y: 0, width: 800, height: 600),
            onSetEnabled: { _, _ in card },
            onCreatePlugin: { _, _ in card },
            onAddSkill: { _, _ in card },
            onAddMCP: { _, _, _ in card },
            onSyncCodex: { "Codex 配置已同步" },
            onSyncClaudeCode: { "Claude Code 配置已同步" },
            onSyncOpencode: { "opencode 配置已同步" }
        )

        controller.syncCodex()
        controller.syncClaudeCode()
        controller.syncOpencode()

        #expect(controller.syncMessages == ["Codex 配置已同步", "Claude Code 配置已同步", "opencode 配置已同步"])
        controller.hide()
    }
}
