import Foundation
import Testing
import Context
import Orchestrator
import Rendering
import RuntimeBridge
@testable import AgentMode
@testable import App
@testable import Shell

@MainActor
@Suite("ProjectCapabilityManagerCard")
struct ProjectCapabilityManagerCardTests {
    @Test("build：从当前项目 plugin catalog 派生 Skills 和 MCP 卡片，不写 engine 文件")
    func buildsCardStateWithoutMaterializingEngineFiles() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(enabled: true)

        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .skills)

        #expect(state.visibleItems.map(\.name) == ["code-review"])
        #expect(state.visibleItems.first?.pluginID == "dev-toolkit")
        #expect(state.visibleItems.first?.status == .enabled)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".codex/config.toml").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".mcp.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".agents/skills/dev-toolkit-code-review").path) == false)
    }

    @Test("build：MCP 卡片显示 engine config targets")
    func buildsMCPItemsWithEngineConfigTargets() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(enabled: true)

        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .mcp)

        #expect(state.visibleItems.map(\.name) == ["filesystem"])
        #expect(state.visibleItems.first?.targetPaths.sorted() == [
            fixture.project.rootURL.appendingPathComponent(".codex/config.toml").path,
            fixture.project.rootURL.appendingPathComponent(".mcp.json").path
        ].sorted())
    }

    @Test("build：opencode policy 显示 native config target")
    func buildsMCPItemsWithOpencodeNativeTarget() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(
            enabled: true,
            enginesJSON: #"{ "openCode": { "enabled": true, "projection": "skills-and-mcp-files" } }"#
        )

        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .mcp)

        #expect(state.visibleItems.map(\.name) == ["filesystem"])
        #expect(state.visibleItems.first?.targetPaths == [fixture.project.rootURL.appendingPathComponent("opencode.json").path])
    }

    @Test("build：adapter 失败时转成卡片诊断")
    func adapterErrorsBecomeCardDiagnostics() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(enabled: true, mcpRef: "mcp/servers.json#missing")

        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .mcp)

        #expect(state.visibleItems.first?.status == .warning)
        #expect(state.visibleItems.first?.diagnostics.contains { $0.severity == "warning" && $0.message.contains("missing") } == true)
    }

    @Test("build：MCP 缺失只标记 MCP 行")
    func missingMCPDiagnosticsOnlyMarkMCPItem() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(enabled: true, mcpRef: "mcp/servers.json#missing")

        let skillState = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .skills)
        let skillItem = try #require(skillState.visibleItems.first)
        #expect(skillItem.status == .enabled)
        #expect(skillItem.diagnostics.contains { $0.message.contains("MCP server") } == false)

        let mcpState = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .mcp)
        let mcpItem = try #require(mcpState.visibleItems.first)
        #expect(mcpItem.status == .warning)
        #expect(mcpItem.diagnostics.contains { $0.severity == "warning" && $0.message.contains("missing") } == true)
        #expect(mcpItem.diagnostics.contains { $0.severity == "error" && $0.message.contains("missing") } == false)
    }

    @Test("build：MCP health warning 显示在 MCP 行")
    func mcpHealthWarningsMarkMCPItem() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(enabled: true, commandJSON: #"["openpetagent-missing-mcp-command"]"#)

        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .mcp)
        let item = try #require(state.visibleItems.first)

        #expect(item.status == .warning)
        #expect(item.diagnostics.contains { $0.severity == "warning" && $0.message.contains("MCP command not found") } == true)
    }

    @Test("toggle：禁用 plugin 只改 plugin.json enabled，不 materialize engine 文件")
    func disablesPluginManifestOnly() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(enabled: true)

        try MinimalAppDelegate.setProjectPluginEnabled(project: fixture.project, pluginID: "dev-toolkit", enabled: false)

        let json = try fixture.manifestJSON()
        #expect(json["enabled"] as? Bool == false)
        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .skills)
        #expect(state.visibleItems.first?.status == .disabled)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".codex/config.toml").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".mcp.json").path) == false)
    }

    @Test("build：typed validator 诊断会显示在能力卡片")
    func typedValidatorDiagnosticsBecomeCardDiagnostics() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(enabled: true)
        try FileManager.default.removeItem(at: fixture.pluginRoot.appendingPathComponent("skills/code-review/SKILL.md"))

        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .skills)

        #expect(state.visibleItems.first?.status == .failed)
        #expect(state.visibleItems.first?.diagnostics.contains { $0.severity == "error" && $0.message.contains("Missing skill") } == true)
    }

    @Test("toggle：拒绝 symlink plugin 写出项目 plugins root")
    func rejectsSymlinkedPluginManifestOutsideProject() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        let external = fixture.root.appendingPathComponent("external-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "External", "enabled": true, "capabilities": [] }
        """.data(using: .utf8)!.write(to: external.appendingPathComponent("plugin.json"), options: .atomic)
        try FileManager.default.createDirectory(at: ProjectConfig.pluginRoot(for: fixture.project), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.pluginRoot, withDestinationURL: external)

        #expect(throws: ProjectCapabilityManagerError.invalidPluginID("dev-toolkit")) {
            try MinimalAppDelegate.setProjectPluginEnabled(project: fixture.project, pluginID: "dev-toolkit", enabled: false)
        }
        let data = try Data(contentsOf: external.appendingPathComponent("plugin.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["enabled"] as? Bool == true)
    }

    @Test("Skill detail：保存正文只写 canonical catalog 并刷新 typed state")
    func skillDetailSavesCanonicalBodyWithoutMaterializing() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writePlugin(enabled: true)
        let suite = "ProjectCapabilitySkillEditTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        let model = delegate.projectCapabilityColumnState(for: fixture.project)
        let detail = try #require(model.skillDetail(
            pluginID: "dev-toolkit",
            skillRef: "skills/code-review"
        ))
        let updatedBody = "# code-review\n\n完整更新正文。\n"
        detail.beginEditing()
        detail.draftBody = updatedBody

        detail.save()

        let body = try String(
            contentsOf: fixture.pluginRoot.appendingPathComponent("skills/code-review/SKILL.md"),
            encoding: .utf8
        )
        #expect(body == updatedBody)
        #expect(model.catalog?.plugins.first?.skills.first?.body == updatedBody)
        #expect(detail.skill.body == updatedBody)
        #expect(detail.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".codex/config.toml").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".mcp.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".agents").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".claude").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".open-pet-agent/plugins/.materialized").path) == false)
    }

    @Test("Skill detail：写入后全局刷新失败仍保持保存成功")
    func skillDetailKeepsSuccessfulWriteWhenCatalogRefreshFails() throws {
        let fixture = try ProjectCapabilityManagerFixture(prefix: "RefreshFailure")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writePlugin(enabled: true)
        let suite = "ProjectCapabilityRefreshFailureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        let model = delegate.projectCapabilityColumnState(for: fixture.project)
        let detail = try #require(model.skillDetail(
            pluginID: "dev-toolkit",
            skillRef: "skills/code-review"
        ))
        let brokenRoot = ProjectConfig.pluginDirectory(for: fixture.project, pluginID: "broken")
        try FileManager.default.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
        try """
        { "schemaVersion": 1, "id": "not-broken", "name": "Broken", "enabled": true, "capabilities": [] }
        """.data(using: .utf8)!.write(to: brokenRoot.appendingPathComponent("plugin.json"), options: .atomic)
        let updatedBody = "# code-review\n\n刷新失败也不能回滚成功写入。\n"
        detail.beginEditing()
        detail.draftBody = updatedBody

        detail.save()

        let body = try String(
            contentsOf: fixture.pluginRoot.appendingPathComponent("skills/code-review/SKILL.md"),
            encoding: .utf8
        )
        #expect(body == updatedBody)
        #expect(model.catalog?.plugins.first { $0.id == "dev-toolkit" }?.skills.first?.body == updatedBody)
        #expect(detail.skill.body == updatedBody)
        #expect(detail.isEditing == false)
        #expect(detail.errorMessage == nil)
    }

    @Test("MCP detail：保存配置只写 canonical catalog 并刷新 typed state")
    func mcpDetailSavesCanonicalConfigWithoutMaterializing() throws {
        let fixture = try ProjectCapabilityManagerFixture(prefix: "MCPEdit")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writePlugin(enabled: true)
        let suite = "ProjectCapabilityMCPEditTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        let model = delegate.projectCapabilityColumnState(for: fixture.project)
        let detail = try #require(model.mcpDetail(pluginID: "dev-toolkit", serverName: "filesystem"))
        detail.beginEditing()
        detail.draftCommand = "uvx"
        detail.draftArguments = "mcp-server\n--verbose"
        detail.draftEnvironment = "TOKEN=secret"
        detail.draftCWD = "/tmp/work"

        detail.save()

        let server = try fixture.mcpServerJSON(name: "filesystem")
        #expect(server["command"] as? String == "uvx")
        #expect(server["args"] as? [String] == ["mcp-server", "--verbose"])
        #expect((server["env"] as? [String: String])?["TOKEN"] == "secret")
        #expect(server["cwd"] as? String == "/tmp/work")
        #expect(model.catalog?.plugins.first?.mcpServers.first?.command == ["uvx", "mcp-server", "--verbose"])
        #expect(detail.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".codex/config.toml").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".mcp.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".open-pet-agent/plugins/.materialized").path) == false)
    }

    @Test("MCP detail：写入后全局刷新失败仍保持保存成功")
    func mcpDetailKeepsSuccessfulWriteWhenCatalogRefreshFails() throws {
        let fixture = try ProjectCapabilityManagerFixture(prefix: "MCPRefreshFailure")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writePlugin(enabled: true)
        let suite = "ProjectCapabilityMCPRefreshFailureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        let model = delegate.projectCapabilityColumnState(for: fixture.project)
        let detail = try #require(model.mcpDetail(pluginID: "dev-toolkit", serverName: "filesystem"))
        let brokenRoot = ProjectConfig.pluginDirectory(for: fixture.project, pluginID: "broken")
        try FileManager.default.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
        try """
        { "schemaVersion": 1, "id": "not-broken", "name": "Broken", "enabled": true, "capabilities": [] }
        """.data(using: .utf8)!.write(to: brokenRoot.appendingPathComponent("plugin.json"), options: .atomic)
        detail.beginEditing()
        detail.draftCommand = "uvx"
        detail.draftArguments = "new"

        detail.save()

        let server = try fixture.mcpServerJSON(name: "filesystem")
        #expect(server["command"] as? String == "uvx")
        #expect(model.catalog?.plugins.first { $0.id == "dev-toolkit" }?.mcpServers.first?.command == ["uvx", "new"])
        #expect(detail.server.command == ["uvx", "new"])
        #expect(detail.isEditing == false)
        #expect(detail.errorMessage == nil)
    }

    @Test("MCP detail：删除只写 canonical catalog，不自动 materialize")
    func mcpDetailDeletesCanonicalConfigWithoutMaterializing() throws {
        let fixture = try ProjectCapabilityManagerFixture(prefix: "MCPDelete")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writePlugin(enabled: true)
        let projected = fixture.project.rootURL.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: projected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user projection stays".utf8).write(to: projected, options: .atomic)
        let suite = "ProjectCapabilityMCPDeleteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        let model = delegate.projectCapabilityColumnState(for: fixture.project)
        let detail = try #require(model.mcpDetail(pluginID: "dev-toolkit", serverName: "filesystem"))

        detail.delete()

        let serverFile = fixture.pluginRoot.appendingPathComponent("mcp/servers.json")
        let data = try Data(contentsOf: serverFile)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["filesystem"] == nil)
        #expect((try fixture.manifestJSON()["mcp"] as? [String]) == [])
        #expect(model.card.items.contains { $0.kind == .mcp && $0.name == "filesystem" } == false)
        #expect(detail.isDeleted)
        #expect(try String(contentsOf: projected, encoding: .utf8) == "user projection stays")
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".mcp.json").path) == false)
        let backupRoot = fixture.project.rootURL.appendingPathComponent(".open-pet-agent/backups/capabilities", isDirectory: true)
        #expect((try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)).count == 1)
    }

    @Test("column：Import Existing 扫描、确认后只写 canonical catalog")
    func importExistingDrillsInAndWritesCanonicalOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectCapabilityImportIntegrationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ProjectCapabilityImportIntegrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        ProjectConfig.homeDirectoryOverride = root
        defer {
            ProjectConfig.homeDirectoryOverride = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try ProjectStore.createExternal(
            name: "Import Existing",
            rootURL: root.appendingPathComponent("repo", isDirectory: true)
        )
        let skill = project.rootURL
            .appendingPathComponent(".claude/skills/review", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("# review\n\nImported.\n".utf8).write(
            to: skill.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        ProjectStore.setCurrent(project.id, defaults: defaults)
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        defer { delegate.columnContainerWindowController.close() }

        delegate.showProjectCapabilityManagerCard()
        let rootColumn = try #require(
            delegate.columnContainerWindowController.state.stack.columns.first
        )
        guard case .projectCapabilityManager(let model) = rootColumn.kind else {
            Issue.record("根列不是项目能力管理")
            return
        }
        model.openImport()

        #expect(delegate.columnContainerWindowController.state.stack.columns.count == 2)
        let importColumn = try #require(
            delegate.columnContainerWindowController.state.stack.columns.last
        )
        guard case .projectCapabilityImport(let importState) = importColumn.kind else {
            Issue.record("未追加 Import Existing 列")
            return
        }
        #expect(importState.candidates.map(\.name) == ["review"])
        importState.pluginID = "imported-local"
        importState.pluginName = "Imported Local"
        importState.toggleSelection("skill:review:claudeSkill")
        importState.importSelected()

        let canonical = ProjectConfig.pluginDirectory(
            for: project,
            pluginID: "imported-local"
        )
        #expect(FileManager.default.fileExists(
            atPath: canonical.appendingPathComponent("skills/review/SKILL.md").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: skill.appendingPathComponent("SKILL.md").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: project.rootURL.appendingPathComponent(".mcp.json").path
        ) == false)
        #expect(FileManager.default.fileExists(
            atPath: project.rootURL.appendingPathComponent(".codex/config.toml").path
        ) == false)
        #expect(model.catalog?.plugins.contains { $0.id == "imported-local" } == true)
        #expect(importState.errorMessage == nil)
    }

    @Test("column：添加能力与诊断作为二级列打开")
    func addCapabilityAndDiagnosticsOpenAsSecondaryColumns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCapabilitySecondaryColumnsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ProjectCapabilitySecondaryColumnsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        ProjectConfig.homeDirectoryOverride = root
        defer {
            ProjectConfig.homeDirectoryOverride = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try ProjectStore.createExternal(
            name: "Secondary Columns",
            rootURL: root.appendingPathComponent("repo", isDirectory: true)
        )
        let fixture = ProjectCapabilityManagerFixture(project: project)
        try fixture.writePlugin(enabled: true)
        ProjectStore.setCurrent(project.id, defaults: defaults)
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        defer { delegate.columnContainerWindowController.close() }

        delegate.showProjectCapabilityManagerCard()
        let rootColumn = try #require(delegate.columnContainerWindowController.state.stack.columns.first)
        guard case .projectCapabilityManager(let model) = rootColumn.kind else {
            Issue.record("根列不是项目能力管理")
            return
        }

        model.openAdd()

        #expect(delegate.columnContainerWindowController.state.stack.columns.count == 2)
        let addColumn = try #require(delegate.columnContainerWindowController.state.stack.columns.last)
        guard case .projectCapabilityAdd(let addModel) = addColumn.kind else {
            Issue.record("未追加添加能力列")
            return
        }
        #expect(addModel === model)

        model.showDiagnostics()

        #expect(delegate.columnContainerWindowController.state.stack.columns.count == 2)
        let diagnosticColumn = try #require(delegate.columnContainerWindowController.state.stack.columns.last)
        guard case .projectCapabilityDiagnostics(let panel) = diagnosticColumn.kind else {
            Issue.record("未追加项目能力诊断列")
            return
        }
        #expect(panel.sections.map(\.engineName).contains("Codex"))
    }

    @Test("Import Existing：写入成功但全局刷新失败时局部更新 root")
    func importKeepsSuccessfulWriteWhenCatalogRefreshFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProjectCapabilityImportRefreshFailureTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ProjectCapabilityImportRefreshFailureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        ProjectConfig.homeDirectoryOverride = root
        defer {
            ProjectConfig.homeDirectoryOverride = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try ProjectStore.createExternal(
            name: "Import Refresh Failure",
            rootURL: root.appendingPathComponent("repo", isDirectory: true)
        )
        let skill = project.rootURL
            .appendingPathComponent(".claude/skills/review", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("# review\n\nImported.\n".utf8).write(
            to: skill.appendingPathComponent("SKILL.md"),
            options: .atomic
        )
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        let model = delegate.projectCapabilityColumnState(for: project)
        let broken = ProjectConfig.pluginDirectory(for: project, pluginID: "broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("""
        { "schemaVersion": 1, "id": "not-broken", "name": "Broken", "enabled": true }
        """.utf8).write(to: broken.appendingPathComponent("plugin.json"), options: .atomic)
        var importState: ProjectCapabilityImportState?
        model.onOpenImport = { _, state in importState = state }

        model.openImport()
        let state = try #require(importState)
        state.toggleSelection("skill:review:claudeSkill")
        state.importSelected()

        #expect(FileManager.default.fileExists(
            atPath: ProjectConfig.pluginDirectory(
                for: project,
                pluginID: "imported-local"
            ).appendingPathComponent("skills/review/SKILL.md").path
        ))
        #expect(state.didImport)
        #expect(state.errorMessage == nil)
        #expect(model.catalog?.plugins.contains { $0.id == "imported-local" } == true)
        let item = try #require(
            model.card.items.first { $0.pluginID == "imported-local" }
        )
        #expect(item.status == .warning)
        #expect(item.targetPaths == [
            project.rootURL.appendingPathComponent(
                ".claude/skills/imported-local-review",
                isDirectory: true
            ).path
        ])
        #expect(item.diagnostics.contains {
            $0.severity == "warning"
                && $0.message.contains("全局刷新失败")
        })
    }

    @Test("column：点击 MCP 行在现有容器追加 detail 列")
    func mcpRowDrillsIntoDetailColumn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCapabilityMCPDrillInTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ProjectCapabilityMCPDrillInTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        ProjectConfig.homeDirectoryOverride = root
        defer {
            ProjectConfig.homeDirectoryOverride = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try ProjectStore.createExternal(
            name: "MCP Drill In",
            rootURL: root.appendingPathComponent("repo", isDirectory: true)
        )
        let fixture = ProjectCapabilityManagerFixture(project: project)
        try fixture.writePlugin(enabled: true)
        ProjectStore.setCurrent(project.id, defaults: defaults)
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        defer { delegate.columnContainerWindowController.close() }

        delegate.showProjectCapabilityManagerCard()
        let rootColumn = try #require(delegate.columnContainerWindowController.state.stack.columns.first)
        guard case .projectCapabilityManager(let model) = rootColumn.kind else {
            Issue.record("根列不是项目能力管理")
            return
        }
        model.selectTab(.mcp)
        let row = try #require(model.card.visibleRows.first)
        model.openItem(row.item, rowID: row.rowID)

        #expect(delegate.columnContainerWindowController.state.stack.columns.count == 2)
        let detailColumn = try #require(delegate.columnContainerWindowController.state.stack.columns.last)
        guard case .projectCapabilityMCPDetail(let detail) = detailColumn.kind else {
            Issue.record("未追加 MCP detail 列")
            return
        }
        #expect(detail.server.id == "dev-toolkit:filesystem")
    }

    @Test("column：点击 Skill 行在现有容器追加 detail 列")
    func skillRowDrillsIntoDetailColumn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCapabilityDrillInTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ProjectCapabilityDrillInTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        ProjectConfig.homeDirectoryOverride = root
        defer {
            ProjectConfig.homeDirectoryOverride = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try ProjectStore.createExternal(
            name: "Drill In",
            rootURL: root.appendingPathComponent("repo", isDirectory: true)
        )
        let fixture = ProjectCapabilityManagerFixture(project: project)
        try fixture.writePlugin(enabled: true)
        ProjectStore.setCurrent(project.id, defaults: defaults)
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        defer { delegate.columnContainerWindowController.close() }

        delegate.showProjectCapabilityManagerCard()
        let rootColumn = try #require(delegate.columnContainerWindowController.state.stack.columns.first)
        guard case .projectCapabilityManager(let model) = rootColumn.kind else {
            Issue.record("根列不是项目能力管理")
            return
        }
        let item = try #require(model.card.visibleItems.first)
        model.openItem(item, rowID: 0)

        #expect(delegate.columnContainerWindowController.state.stack.columns.count == 2)
        let detailColumn = try #require(delegate.columnContainerWindowController.state.stack.columns.last)
        guard case .projectCapabilitySkillDetail(let detail) = detailColumn.kind else {
            Issue.record("未追加 Skill detail 列")
            return
        }
        #expect(detail.skill.id == "dev-toolkit:skills/code-review")
        #expect(rootColumn.id == delegate.columnContainerWindowController.state.stack.columns.first?.id)
    }

    @Test("column：项目能力列操作绑定打开时项目，不被 current project 后续切换影响")
    func columnStateMutatesOpenedProjectAfterCurrentProjectChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCapabilityManagerCardTests-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ProjectCapabilityManagerCardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        ProjectConfig.homeDirectoryOverride = root
        defer {
            ProjectConfig.homeDirectoryOverride = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let projectA = try ProjectStore.createExternal(name: "A", rootURL: root.appendingPathComponent("A/repo", isDirectory: true))
        let projectB = try ProjectStore.createExternal(name: "B", rootURL: root.appendingPathComponent("B/repo", isDirectory: true))
        let fixtureA = ProjectCapabilityManagerFixture(project: projectA)
        let fixtureB = ProjectCapabilityManagerFixture(project: projectB)
        try fixtureA.writePlugin(enabled: true)
        try fixtureB.writePlugin(enabled: true)
        ProjectStore.setCurrent(projectA.id, defaults: defaults)
        let delegate = MinimalAppDelegate(rootSystem: .testSystem(), userDefaults: defaults, startFrameLoop: { _ in nil }, showShellWindows: { _ in })
        let model = delegate.projectCapabilityColumnState(for: projectA)
        ProjectStore.setCurrent(projectB.id, defaults: defaults)

        model.setPluginEnabled(pluginID: "dev-toolkit", enabled: false)

        #expect(try fixtureA.manifestJSON()["enabled"] as? Bool == false)
        #expect(try fixtureB.manifestJSON()["enabled"] as? Bool == true)
    }
    @Test("build：target states 显示 manifest 中声明的 engine 开关")
    func buildsTargetStatesFromManifestEngines() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(
            enabled: true,
            enginesJSON: #"{ "codex": { "enabled": true, "projection": "skills-and-mcp-files" } }"#
        )

        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .overview)
        let item = try #require(state.visibleItems.first { $0.kind == .skill })
        let states = Dictionary(uniqueKeysWithValues: item.targets.map { ($0.target, $0.isEnabled) })

        #expect(states[.codex] == true)
        #expect(states[.claudeCode] == false)
        #expect(states[.opencode] == false)
    }

    @Test("preview：Codex 同步预览列出操作但不 materialize engine 文件")
    func codexPreviewListsOperationsWithoutMaterializing() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(enabled: true)

        let preview = MinimalAppDelegate.projectCapabilitySyncPreview(
            for: fixture.project,
            target: .codex
        )

        #expect(preview.target == .codex)
        #expect(preview.failureMessage == nil)
        #expect(preview.operationSummaries.contains { $0.contains(".codex/config.toml") })
        #expect(preview.operationSummaries.contains { $0.contains(".agents/skills/dev-toolkit-code-review") })
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".open-pet-agent/opencode.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".codex/config.toml").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".agents").path) == false)
    }

    @Test("preview：项目能力列先预览不写文件，确认同步后才 materialize")
    func columnPreviewDoesNotMaterializeUntilConfirmedSync() throws {
        let fixture = try ProjectCapabilityManagerFixture(prefix: "PreviewThenSync")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writePlugin(enabled: true)
        let suite = "ProjectCapabilityPreviewThenSyncTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = MinimalAppDelegate(
            rootSystem: .testSystem(),
            userDefaults: defaults,
            startFrameLoop: { _ in nil },
            showShellWindows: { _ in }
        )
        let model = delegate.projectCapabilityColumnState(for: fixture.project)

        model.previewCodex()

        #expect(model.card.syncPreview?.target == .codex)
        #expect(model.card.syncPreview?.operationSummaries.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".open-pet-agent/opencode.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".codex/config.toml").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".agents").path) == false)

        model.syncCodex()

        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".codex/config.toml").path))
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".agents/skills/dev-toolkit-code-review").path))
    }

    @Test("target toggle：关闭目标时同步禁用 legacy engine aliases")
    func targetToggleDisablesLegacyAliases() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(
            enabled: true,
            enginesJSON: #"{ "openCode": { "enabled": true, "projection": "skills-and-mcp-files" }, "opencode": { "enabled": true, "projection": "skills-and-mcp-files" } }"#
        )

        try MinimalAppDelegate.setProjectPluginTarget(
            project: fixture.project,
            pluginID: "dev-toolkit",
            target: .opencode,
            enabled: false
        )

        let manifest = try fixture.manifestJSON()
        let engines = try #require(manifest["engines"] as? [String: Any])
        let openCode = try #require(engines["openCode"] as? [String: Any])
        let opencode = try #require(engines["opencode"] as? [String: Any])
        #expect(openCode["enabled"] as? Bool == false)
        #expect(opencode["enabled"] as? Bool == false)
    }

    @Test("target toggle：只改 manifest engine policy，不 materialize engine 文件")
    func targetToggleUpdatesManifestOnly() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(
            enabled: true,
            enginesJSON: #"{ "codex": { "enabled": true, "projection": "skills-and-mcp-files" }, "claude-code": { "enabled": true, "projection": "skills-and-mcp-files" } }"#
        )

        try MinimalAppDelegate.setProjectPluginTarget(
            project: fixture.project,
            pluginID: "dev-toolkit",
            target: .codex,
            enabled: false
        )

        let manifest = try fixture.manifestJSON()
        let engines = try #require(manifest["engines"] as? [String: Any])
        let codex = try #require(engines["codex"] as? [String: Any])
        let claude = try #require(engines["claude-code"] as? [String: Any])
        #expect(codex["enabled"] as? Bool == false)
        #expect(codex["projection"] as? String == "skills-and-mcp-files")
        #expect(claude["enabled"] as? Bool == true)
        #expect(claude["projection"] as? String == "skills-and-mcp-files")
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".codex/config.toml").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".mcp.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".agents").path) == false)
    }
}

private extension AppRootSystem {
    static func testSystem() -> AppRootSystem {
        AppRootSystem(
            snapshot: DesktopSnapshot(),
            windowGraph: .bootstrap,
            companionBootstrap: CompanionBootstrap(
                capabilities: RuntimeCapabilities(),
                initialRenderState: RenderState(
                    petPositionX: 100,
                    petPositionY: 100,
                    petRotation: 0,
                    particleCount: 0,
                    particles: [],
                    contactCount: 0,
                    isSnowEnabled: false
                )
            ),
            runtimeTicker: RuntimeTicker { previousState, _, _ in
                RuntimeTickResult(renderState: previousState, snapshot: DesktopSnapshot())
            },
            conversationResponder: ConversationResponder { _ in "" }
        )
    }
}

private struct ProjectCapabilityManagerFixture {
    let root: URL
    let project: AgentProject
    let pluginRoot: URL

    init(prefix: String = "P") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCapabilityManagerCardTests-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        project = AgentProject(
            id: "p-\(prefix)",
            name: prefix,
            rootURL: root.appendingPathComponent("repo", isDirectory: true),
            isExternal: true,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
    }

    init(project: AgentProject) {
        self.root = project.rootURL.deletingLastPathComponent()
        self.project = project
        self.pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
    }

    func writePlugin(
        enabled: Bool,
        mcpRef: String = "mcp/servers.json#filesystem",
        enginesJSON: String = #"{ "codex": { "enabled": true, "projection": "skills-and-mcp-files" }, "claude-code": { "enabled": true, "projection": "skills-and-mcp-files" } }"#,
        commandJSON: String = #"["/bin/echo"]"#
    ) throws {
        try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("mcp", isDirectory: true), withIntermediateDirectories: true)
        let skillRoot = pluginRoot.appendingPathComponent("skills/code-review", isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        try "# code-review\n\nReview staged diffs.\n".data(using: .utf8)!.write(to: skillRoot.appendingPathComponent("SKILL.md"), options: .atomic)
        try """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev Toolkit", "enabled": \(enabled), "capabilities": ["mcp", "skills"], "mcp": ["\(mcpRef)"], "skills": ["skills/code-review"], "engines": \(enginesJSON) }
        """.data(using: .utf8)!.write(to: pluginRoot.appendingPathComponent("plugin.json"), options: .atomic)
        try """
        { "mcpServers": { "filesystem": { "type": "local", "command": \(commandJSON), "enabled": true } } }
        """.data(using: .utf8)!.write(to: pluginRoot.appendingPathComponent("mcp/servers.json"), options: .atomic)
    }

    func mcpServerJSON(name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: pluginRoot.appendingPathComponent("mcp/servers.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let server = servers[name] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return server
    }

    func manifestJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: pluginRoot.appendingPathComponent("plugin.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return json
    }
}
