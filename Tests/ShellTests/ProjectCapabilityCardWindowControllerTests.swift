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
            onCreatePlugin: { ProjectCapabilityCardState(selectedTab: .skills, items: [item]) },
            onAddSkill: { ProjectCapabilityCardState(selectedTab: .skills, items: [item]) },
            onAddMCP: { ProjectCapabilityCardState(selectedTab: .mcp, items: [item]) }
        )

        #expect(controller.window?.isVisible == true)
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
            onCreatePlugin: { ProjectCapabilityCardState(selectedTab: .skills, items: [item]) },
            onAddSkill: { ProjectCapabilityCardState(selectedTab: .skills, items: [item]) },
            onAddMCP: { ProjectCapabilityCardState(selectedTab: .mcp, items: [item]) }
        )

        controller.setPluginEnabled(pluginID: "dev-toolkit", enabled: false)

        #expect(controller.card.selectedTab == .mcp)
        controller.hide()
    }
}
