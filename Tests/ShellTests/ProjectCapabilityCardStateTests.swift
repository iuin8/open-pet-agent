import Testing
@testable import Shell

@Suite("ProjectCapabilityCardState")
struct ProjectCapabilityCardStateTests {
    @Test("Item：source 和多个 targets 默认复制 source → targets")
    func itemCopiesSourceTargetsPair() {
        let item = ProjectCapabilityCardState.Item(
            id: "skill:dev-toolkit:lint",
            kind: .skill,
            name: "lint",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/repo/.open-pet-agent/plugins/dev-toolkit/skills/lint",
            targetPaths: [
                "/tmp/repo/.agents/skills/dev-toolkit-lint",
                "/tmp/repo/.claude/skills/dev-toolkit-lint"
            ],
            status: .enabled,
            diagnostics: []
        )

        #expect(item.copyText == "/tmp/repo/.open-pet-agent/plugins/dev-toolkit/skills/lint → /tmp/repo/.agents/skills/dev-toolkit-lint\n/tmp/repo/.open-pet-agent/plugins/dev-toolkit/skills/lint → /tmp/repo/.claude/skills/dev-toolkit-lint")
    }

    @Test("State：按当前 tab 过滤 items")
    func stateFiltersItemsBySelectedTab() {
        let skill = ProjectCapabilityCardState.Item(
            id: "skill:dev-toolkit:lint",
            kind: .skill,
            name: "lint",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/skills/lint",
            targetPaths: [],
            status: .enabled,
            diagnostics: []
        )
        let mcp = ProjectCapabilityCardState.Item(
            id: "mcp:dev-toolkit:filesystem",
            kind: .mcp,
            name: "filesystem",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/mcp/servers.json#filesystem",
            targetPaths: [],
            status: .warning,
            diagnostics: []
        )

        let state = ProjectCapabilityCardState(selectedTab: .skills, items: [mcp, skill])

        #expect(state.visibleItems == [skill])
        #expect(state.visibleRows.map(\.rowID) == [1])
        #expect(state.visibleRows.map(\.item) == [skill])
    }

    @Test("Item：启用/禁用下一值由 isEnabled 决定，不受 warning 状态影响")
    func itemNextEnabledValueIgnoresDisplayStatus() {
        let item = ProjectCapabilityCardState.Item(
            id: "skill:dev-toolkit:lint",
            kind: .skill,
            name: "lint",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/skills/lint",
            targetPaths: [],
            isEnabled: false,
            status: .warning,
            diagnostics: [ProjectCapabilityPanelState.Diagnostic(severity: "warning", message: "重复引用", path: nil)]
        )

        #expect(item.nextEnabledValue == true)
    }
}
