import Foundation
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

    @Test("Skill row：Skill 与 MCP 分别打开对应 detail")
    func opensDetailsForSkillAndMCPItems() {
        let skill = capabilitySkill(body: "正文")
        let server = capabilityMCPServer(command: ["npx", "old"])
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .skills, items: [skillItem(), mcpItem()]),
            catalog: capabilityCatalog(skill: skill, server: server)
        )
        var openedSkillRow: Int?
        var openedMCPRow: Int?
        model.onOpenSkillDetail = { rowID, detail in
            openedSkillRow = rowID
            #expect(detail.skill.id == skill.id)
        }
        model.onOpenMCPDetail = { rowID, detail in
            openedMCPRow = rowID
            #expect(detail.server.id == server.id)
        }

        model.openItem(skillItem(), rowID: 7)
        model.openItem(mcpItem(), rowID: 8)

        #expect(openedSkillRow == 7)
        #expect(openedMCPRow == 8)
    }

    @Test("Import Existing：稳定 rowID 打开独立导入列")
    func opensImportPaneWithStableRowID() {
        let candidate = ProjectCapabilityImportCandidate(
            id: "skill:review:claudeSkill",
            kind: .skill,
            name: "review",
            sources: [.init(
                kind: .claudeSkill,
                url: URL(fileURLWithPath: "/tmp/review/SKILL.md")
            )],
            skillBody: "# review"
        )
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .mcp, items: []),
            onScanImports: {
                ProjectCapabilityImportScan(candidates: [candidate])
            },
            onImportCandidates: { _, _, _ in
                .snapshot(ProjectCapabilitySnapshot(
                    catalog: ProjectCapabilityCatalogModel(
                        projectID: "p",
                        plugins: []
                    ),
                    card: ProjectCapabilityCardState(
                        selectedTab: .skills,
                        items: []
                    )
                ))
            }
        )
        var openedRow: Int?
        var openedState: ProjectCapabilityImportState?
        model.onOpenImport = { rowID, state in
            openedRow = rowID
            openedState = state
        }

        model.openImport()

        #expect(openedRow == ProjectCapabilityColumnState.importRowID)
        #expect(openedState?.candidates.map(\.name) == ["review"])
        #expect(model.card.selectedTab == .mcp)
    }

    @Test("MCP detail：保存成功后刷新 root/detail 并保留 tab")
    func mcpDetailSaveRefreshesRootAndDetail() throws {
        let original = capabilityMCPServer(command: ["npx", "old"])
        let refreshed = capabilityMCPServer(command: ["uvx", "new"])
        let skill = capabilitySkill(body: "正文")
        let originalCatalog = capabilityCatalog(skill: skill, server: original)
        let refreshedCatalog = capabilityCatalog(skill: skill, server: refreshed)
        let item = mcpItem()
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .skills, items: [item]),
            catalog: originalCatalog,
            onUpdateMCPServer: { pluginID, fileRef, serverName, value in
                #expect(pluginID == "dev-toolkit")
                #expect(fileRef == "mcp/servers.json")
                #expect(serverName == "filesystem")
                #expect(value.objectValue?["command"] == .string("uvx"))
                return ProjectCapabilitySnapshot(
                    catalog: refreshedCatalog,
                    card: ProjectCapabilityCardState(selectedTab: .mcp, items: [item])
                )
            }
        )
        let detail = try #require(model.mcpDetail(pluginID: "dev-toolkit", serverName: "filesystem"))
        detail.beginEditing()
        detail.draftCommand = "uvx"
        detail.draftArguments = "new"

        detail.save()

        #expect(detail.server.command == ["uvx", "new"])
        #expect(detail.isEditing == false)
        #expect(detail.errorMessage == nil)
        #expect(model.catalog == refreshedCatalog)
        #expect(model.card.selectedTab == .skills)
    }

    @Test("MCP detail：保存失败时保留草稿和原 snapshot")
    func mcpDetailSaveFailureKeepsDraftAndSnapshot() throws {
        struct SaveError: Error {}
        let skill = capabilitySkill(body: "正文")
        let original = capabilityMCPServer(command: ["npx", "old"])
        let originalCatalog = capabilityCatalog(skill: skill, server: original)
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .mcp, items: [mcpItem()]),
            catalog: originalCatalog,
            onUpdateMCPServer: { _, _, _, _ in throw SaveError() }
        )
        let detail = try #require(model.mcpDetail(pluginID: "dev-toolkit", serverName: "filesystem"))
        detail.beginEditing()
        detail.draftCommand = "uvx"
        detail.draftArguments = "unsaved"

        detail.save()

        #expect(detail.server.command == ["npx", "old"])
        #expect(detail.draftCommand == "uvx")
        #expect(detail.draftArguments == "unsaved")
        #expect(detail.isEditing)
        #expect(detail.errorMessage != nil)
        #expect(model.catalog == originalCatalog)
    }

    @Test("MCP detail：写入成功但全局刷新失败时局部更新 typed state")
    func mcpDetailPatchesCatalogWhenRefreshFails() throws {
        let skill = capabilitySkill(body: "正文")
        let original = capabilityMCPServer(command: ["npx", "old"])
        let originalCatalog = capabilityCatalog(skill: skill, server: original)
        let model = ProjectCapabilityColumnState(
            card: ProjectCapabilityCardState(selectedTab: .mcp, items: [mcpItem()]),
            catalog: originalCatalog,
            onUpdateMCPServer: { _, _, _, _ in nil }
        )
        let detail = try #require(model.mcpDetail(pluginID: "dev-toolkit", serverName: "filesystem"))
        detail.beginEditing()
        detail.draftCommand = "uvx"
        detail.draftArguments = "new"

        detail.save()

        #expect(detail.server.command == ["uvx", "new"])
        #expect(model.catalog?.plugins.first?.mcpServers.first?.command == ["uvx", "new"])
        #expect(detail.errorMessage == nil)
        #expect(detail.isEditing == false)
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

    private func capabilityCatalog(
        skill: CapabilitySkill,
        server: CapabilityMCPServer? = nil
    ) -> ProjectCapabilityCatalogModel {
        ProjectCapabilityCatalogModel(
            projectID: "p",
            plugins: [CapabilityPlugin(
                id: "dev-toolkit",
                name: "Dev Toolkit",
                version: nil,
                enabled: true,
                source: .local(path: "/tmp/dev-toolkit"),
                skills: [skill],
                mcpServers: server.map { [$0] } ?? [],
                profiles: [],
                diagnostics: []
            )]
        )
    }

    private func capabilityMCPServer(command: [String]) -> CapabilityMCPServer {
        let object: ACPJSON = .object([
            "type": .string("local"),
            "command": .string(command[0]),
            "args": .array(command.dropFirst().map(ACPJSON.string)),
            "enabled": .bool(true)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return CapabilityMCPServer(
            id: "dev-toolkit:filesystem",
            name: "filesystem",
            fileRef: "mcp/servers.json",
            transport: .stdio,
            command: command,
            url: nil,
            env: [:],
            cwd: nil,
            rawJSON: String(data: try! encoder.encode(object), encoding: .utf8),
            targets: [.codex],
            diagnostics: []
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
