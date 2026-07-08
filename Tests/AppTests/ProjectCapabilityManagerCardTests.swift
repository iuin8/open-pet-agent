import Foundation
import Testing
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

        let data = try Data(contentsOf: fixture.pluginRoot.appendingPathComponent("plugin.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
}

private struct ProjectCapabilityManagerFixture {
    let root: URL
    let project: AgentProject
    let pluginRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCapabilityManagerCardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        project = AgentProject(
            id: "p",
            name: "P",
            rootURL: root.appendingPathComponent("repo", isDirectory: true),
            isExternal: true,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
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
}
