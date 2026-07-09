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
        try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("skills/code-review", isDirectory: true), withIntermediateDirectories: true)
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
