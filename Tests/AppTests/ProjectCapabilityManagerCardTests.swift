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

    @Test("build：adapter 失败时转成卡片诊断")
    func adapterErrorsBecomeCardDiagnostics() throws {
        let fixture = try ProjectCapabilityManagerFixture()
        try fixture.writePlugin(enabled: true, mcpRef: "mcp/servers.json#missing")

        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .mcp)

        #expect(state.visibleItems.first?.status == .failed)
        #expect(state.visibleItems.first?.diagnostics.contains { $0.severity == "error" && $0.message.contains("missing") } == true)
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

    func writePlugin(enabled: Bool, mcpRef: String = "mcp/servers.json#filesystem") throws {
        try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("mcp", isDirectory: true), withIntermediateDirectories: true)
        let skillRoot = pluginRoot.appendingPathComponent("skills/code-review", isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        try "# code-review\n\nReview staged diffs.\n".data(using: .utf8)!.write(to: skillRoot.appendingPathComponent("SKILL.md"), options: .atomic)
        try """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev Toolkit", "enabled": \(enabled), "capabilities": ["mcp", "skills"], "mcp": ["\(mcpRef)"], "skills": ["skills/code-review"], "engines": { "codex": { "enabled": true, "projection": "skills-and-mcp-files" }, "claude-code": { "enabled": true, "projection": "skills-and-mcp-files" } } }
        """.data(using: .utf8)!.write(to: pluginRoot.appendingPathComponent("plugin.json"), options: .atomic)
        try """
        { "mcpServers": { "filesystem": { "type": "local", "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem"], "enabled": true } } }
        """.data(using: .utf8)!.write(to: pluginRoot.appendingPathComponent("mcp/servers.json"), options: .atomic)
    }

    func manifestJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: pluginRoot.appendingPathComponent("plugin.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return json
    }
}
