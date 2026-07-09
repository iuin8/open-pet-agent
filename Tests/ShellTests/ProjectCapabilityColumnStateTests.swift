import Testing
@testable import Shell

@MainActor
@Suite("ProjectCapabilityColumnState")
struct ProjectCapabilityColumnStateTests {
    @Test("setPluginEnabled：刷新后保留当前 tab")
    func setPluginEnabledPreservesSelectedTab() {
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
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .mcp, items: [item]),
            onSetEnabled: { _, _ in ProjectCapabilityCardState(selectedTab: .skills, items: [item]) }
        )

        model.setPluginEnabled(pluginID: "dev-toolkit", enabled: false)

        #expect(model.card.selectedTab == .mcp)
    }

    @Test("createPlugin：刷新后保留当前 tab")
    func createPluginPreservesSelectedTab() {
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
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .mcp, items: [item]),
            onCreatePlugin: { _, _ in ProjectCapabilityCardState(selectedTab: .skills, items: [item]) }
        )

        model.createPlugin(pluginID: "dev-toolkit", name: "Dev Toolkit")

        #expect(model.card.selectedTab == .mcp)
    }

    @Test("sync：三路同步结果记录在列状态内")
    func syncActionsRecordMessages() {
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .skills, items: []),
            onSyncCodex: { "Codex 配置已同步" },
            onSyncClaudeCode: { "Claude Code 配置已同步" },
            onSyncOpencode: { "opencode 配置已同步" }
        )

        model.syncCodex()
        model.syncClaudeCode()
        model.syncOpencode()

        #expect(model.syncMessages == ["Codex 配置已同步", "Claude Code 配置已同步", "opencode 配置已同步"])
    }
}
