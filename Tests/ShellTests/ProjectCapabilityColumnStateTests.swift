import Testing
@testable import AgentMode
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

    @Test("Skill detail：保存成功后刷新 root/detail 并保留 tab")
    func skillDetailSaveRefreshesRootAndDetail() throws {
        let original = capabilitySkill(body: "旧正文")
        let refreshed = capabilitySkill(body: "新正文")
        let originalCatalog = capabilityCatalog(skill: original)
        let refreshedCatalog = capabilityCatalog(skill: refreshed)
        let item = skillItem()
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .mcp, items: [item]),
            catalog: originalCatalog,
            onUpdateSkillBody: { pluginID, skillRef, body in
                #expect(pluginID == "dev-toolkit")
                #expect(skillRef == "skills/code-review")
                #expect(body == "新正文")
                return ProjectCapabilitySnapshot(
                    catalog: refreshedCatalog,
                    card: ProjectCapabilityCardState(selectedTab: .skills, items: [item])
                )
            }
        )
        let detail = try #require(model.skillDetail(pluginID: "dev-toolkit", skillRef: "skills/code-review"))
        detail.beginEditing()
        detail.draftBody = "新正文"

        detail.save()

        #expect(detail.skill.body == "新正文")
        #expect(detail.isEditing == false)
        #expect(detail.errorMessage == nil)
        #expect(model.catalog == refreshedCatalog)
        #expect(model.card.selectedTab == .mcp)
    }

    @Test("Skill detail：保存失败时保留草稿和原 snapshot")
    func skillDetailSaveFailureKeepsDraftAndSnapshot() throws {
        struct SaveError: Error {}
        let original = capabilitySkill(body: "旧正文")
        let originalCatalog = capabilityCatalog(skill: original)
        let item = skillItem()
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .skills, items: [item]),
            catalog: originalCatalog,
            onUpdateSkillBody: { _, _, _ in throw SaveError() }
        )
        let detail = try #require(model.skillDetail(pluginID: "dev-toolkit", skillRef: "skills/code-review"))
        detail.beginEditing()
        detail.draftBody = "未保存正文"

        detail.save()

        #expect(detail.skill.body == "旧正文")
        #expect(detail.draftBody == "未保存正文")
        #expect(detail.isEditing == true)
        #expect(detail.errorMessage != nil)
        #expect(model.catalog == originalCatalog)
    }

    @Test("Skill row：只为 Skill 打开 detail")
    func opensDetailOnlyForSkillItems() {
        let skill = capabilitySkill(body: "正文")
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .skills, items: [skillItem()]),
            catalog: capabilityCatalog(skill: skill)
        )
        var openedRow: Int?
        model.onOpenSkillDetail = { rowID, detail in
            openedRow = rowID
            #expect(detail.skill.id == skill.id)
        }

        model.openItem(skillItem(), rowID: 7)
        model.openItem(mcpItem(), rowID: 8)

        #expect(openedRow == 7)
    }

    private func capabilitySkill(body: String) -> CapabilitySkill {
        CapabilitySkill(
            id: "dev-toolkit:skills/code-review",
            name: "code-review",
            relativePath: "skills/code-review",
            summary: "Review staged diffs.",
            body: body,
            bodyPreview: body,
            targets: [.codex],
            diagnostics: []
        )
    }

    private func capabilityCatalog(skill: CapabilitySkill) -> ProjectCapabilityCatalogModel {
        ProjectCapabilityCatalogModel(
            projectID: "p",
            plugins: [CapabilityPlugin(
                id: "dev-toolkit",
                name: "Dev Toolkit",
                version: nil,
                enabled: true,
                source: .local(path: "/tmp/dev-toolkit"),
                skills: [skill],
                mcpServers: [],
                profiles: [],
                diagnostics: []
            )]
        )
    }

    private func skillItem() -> ProjectCapabilityCardState.Item {
        ProjectCapabilityCardState.Item(
            id: "skill:dev-toolkit:/tmp/dev-toolkit/skills/code-review",
            kind: .skill,
            name: "code-review",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/dev-toolkit/skills/code-review",
            targetPaths: [],
            status: .enabled,
            diagnostics: []
        )
    }

    private func mcpItem() -> ProjectCapabilityCardState.Item {
        ProjectCapabilityCardState.Item(
            id: "mcp:dev-toolkit:filesystem",
            kind: .mcp,
            name: "filesystem",
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/dev-toolkit/mcp/servers.json#filesystem",
            targetPaths: [],
            status: .enabled,
            diagnostics: []
        )
    }
}
