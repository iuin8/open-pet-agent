import Testing
import AgentMode
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

    @Test("Item：来源元数据用于展示，不影响复制 source → target")
    func itemKeepsSourceProvenanceDisplay() {
        let item = ProjectCapabilityCardState.Item(
            id: "skill:dev-toolkit:lint",
            kind: .skill,
            name: "lint",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/repo/.open-pet-agent/plugins/dev-toolkit/skills/lint",
            targetPaths: ["/tmp/repo/.agents/skills/dev-toolkit-lint"],
            sourceProvenance: "imported · abc123",
            status: .enabled,
            diagnostics: []
        )

        #expect(item.sourceProvenance == "imported · abc123")
        #expect(item.copyText == "/tmp/repo/.open-pet-agent/plugins/dev-toolkit/skills/lint → /tmp/repo/.agents/skills/dev-toolkit-lint")
    }

    @Test("Item：来源信任状态用于展示可信边界，不影响复制 source → target")
    func itemKeepsSourceTrustDisplay() {
        let item = ProjectCapabilityCardState.Item(
            id: "skill:dev-toolkit:lint",
            kind: .skill,
            name: "lint",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/repo/.open-pet-agent/plugins/dev-toolkit/skills/lint",
            targetPaths: ["/tmp/repo/.agents/skills/dev-toolkit-lint"],
            sourceTrust: "需确认 · git",
            status: .enabled,
            diagnostics: []
        )

        #expect(item.sourceTrust == "需确认 · git")
        #expect(item.copyText == "/tmp/repo/.open-pet-agent/plugins/dev-toolkit/skills/lint → /tmp/repo/.agents/skills/dev-toolkit-lint")
    }

    @Test("Item：来源确认状态决定确认按钮下一步动作")
    func itemTracksSourceConfirmationAction() {
        let item = ProjectCapabilityCardState.Item(
            id: "skill:remote:lint",
            kind: .skill,
            name: "lint",
            pluginID: "remote",
            sourcePath: "/tmp/plugin/skills/lint",
            targetPaths: [],
            sourceTrust: "需确认 · git",
            isSourceConfirmable: true,
            isSourceConfirmed: false,
            sourceConfirmationAudit: "确认 1970-01-01T00:00:06Z · hash abc123",
            status: .enabled,
            diagnostics: []
        )

        #expect(item.nextSourceConfirmedValue == true)
        #expect(item.sourceConfirmationAudit == "确认 1970-01-01T00:00:06Z · hash abc123")
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

    @Test("State：overview 显示全部能力并保留原始 rowID")
    func overviewShowsAllCapabilityItems() {
        let skill = ProjectCapabilityCardState.Item(
            id: "skill:dev-toolkit:lint",
            kind: .skill,
            name: "lint",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/skills/lint",
            targetPaths: [],
            targets: [ProjectCapabilityCardState.ProjectionTargetState(target: .codex, isEnabled: true)],
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
            targets: [ProjectCapabilityCardState.ProjectionTargetState(target: .codex, isEnabled: true)],
            status: .warning,
            diagnostics: []
        )

        let state = ProjectCapabilityCardState(selectedTab: .overview, items: [mcp, skill])

        #expect(state.visibleItems == [mcp, skill])
        #expect(state.visibleRows.map(\.rowID) == [0, 1])
    }

    @Test("Item：target states 记录每个投影目标的启用态")
    func itemStoresProjectionTargetStates() {
        let item = ProjectCapabilityCardState.Item(
            id: "skill:dev-toolkit:lint",
            kind: .skill,
            name: "lint",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/skills/lint",
            targetPaths: [],
            targets: [
                ProjectCapabilityCardState.ProjectionTargetState(target: .codex, isEnabled: true),
                ProjectCapabilityCardState.ProjectionTargetState(target: .claudeCode, isEnabled: false)
            ],
            status: .enabled,
            diagnostics: []
        )

        #expect(item.targets.map(\.target) == [.codex, .claudeCode])
        #expect(item.targets.map(\.isEnabled) == [true, false])
    }
}
