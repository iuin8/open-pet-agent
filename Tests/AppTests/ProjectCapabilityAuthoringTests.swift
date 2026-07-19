import Foundation
import Testing
@testable import AgentMode
@testable import App
@testable import Shell

@MainActor
@Suite("ProjectCapabilityAuthoring")
struct ProjectCapabilityAuthoringTests {
    @Test("create：创建最小 plugin 后卡片能看到空 plugin")
    func createsPluginVisibleInCard() throws {
        let fixture = try ProjectCapabilityAuthoringFixture()

        try MinimalAppDelegate.createProjectCapabilityPlugin(project: fixture.project, pluginID: "dev-toolkit", name: "Dev Toolkit")
        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .skills)

        let manifest = try fixture.manifest()
        let source = try #require(manifest["source"] as? [String: Any])
        #expect(source["kind"] as? String == "manual")
        #expect(FileManager.default.fileExists(atPath: fixture.pluginRoot.appendingPathComponent("plugin.json").path))
        #expect(state.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".codex/config.toml").path) == false)
    }

    @Test("create：拒绝 symlink plugin 写出项目 plugins root")
    func createRejectsSymlinkedPluginDirectory() throws {
        let fixture = try ProjectCapabilityAuthoringFixture()
        let external = fixture.root.appendingPathComponent("external-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ProjectConfig.pluginRoot(for: fixture.project), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.pluginRoot, withDestinationURL: external)

        #expect(throws: ProjectCapabilityManagerError.invalidPluginID("dev-toolkit")) {
            try MinimalAppDelegate.createProjectCapabilityPlugin(project: fixture.project, pluginID: "dev-toolkit", name: "Dev Toolkit")
        }
        #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent("plugin.json").path) == false)
    }

    @Test("addSkill：添加完整 skill 正文后卡片显示 summary 且不 materialize")
    func addsSkillBodyVisibleInCardWithoutMaterializing() throws {
        let fixture = try ProjectCapabilityAuthoringFixture()
        try MinimalAppDelegate.createProjectCapabilityPlugin(project: fixture.project, pluginID: "dev-toolkit", name: "Dev Toolkit")

        try MinimalAppDelegate.addProjectCapabilitySkill(
            project: fixture.project,
            pluginID: "dev-toolkit",
            skillName: "code-review",
            skillDescription: "Review staged diffs before commit.",
            body: "1. Inspect git diff.\n2. Report correctness issues.\n"
        )
        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .skills)

        #expect(state.visibleItems.map(\.name) == ["code-review"])
        let body = try String(
            contentsOf: fixture.pluginRoot.appendingPathComponent("skills/code-review/SKILL.md"),
            encoding: .utf8
        )
        #expect(body.contains("description: Review staged diffs before commit."))
        #expect(body.contains("1. Inspect git diff."))
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".agents/skills/dev-toolkit-code-review").path) == false)
    }

    @Test("addMCP：添加 MCP 后卡片显示 server 且不 materialize")
    func addsMCPVisibleInCardWithoutMaterializing() throws {
        let fixture = try ProjectCapabilityAuthoringFixture()
        try MinimalAppDelegate.createProjectCapabilityPlugin(project: fixture.project, pluginID: "dev-toolkit", name: "Dev Toolkit")

        try MinimalAppDelegate.addProjectCapabilityMCP(project: fixture.project, pluginID: "dev-toolkit", serverName: "filesystem")
        let state = try MinimalAppDelegate.projectCapabilityCard(for: fixture.project, selectedTab: .mcp)

        #expect(state.visibleItems.map(\.name) == ["filesystem"])
        #expect(FileManager.default.fileExists(atPath: fixture.project.rootURL.appendingPathComponent(".mcp.json").path) == false)
    }

    @Test("addMCP：追加 server 时保留已有 MCP server 和未知字段")
    func addMCPMergesExistingServersAndUnknownFields() throws {
        let fixture = try ProjectCapabilityAuthoringFixture()
        try MinimalAppDelegate.createProjectCapabilityPlugin(project: fixture.project, pluginID: "dev-toolkit", name: "Dev Toolkit")
        let mcpURL = fixture.pluginRoot.appendingPathComponent("mcp/servers.json")
        try FileManager.default.createDirectory(at: mcpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        { "mcpServers": { "existing": { "type": "local", "command": ["uvx"], "enabled": true } }, "topLevel": "keep" }
        """.data(using: .utf8)!.write(to: mcpURL, options: .atomic)

        try MinimalAppDelegate.addProjectCapabilityMCP(project: fixture.project, pluginID: "dev-toolkit", serverName: "filesystem")

        let root = try fixture.json(mcpURL)
        #expect(root["topLevel"] as? String == "keep")
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["existing"] != nil)
        #expect(servers["filesystem"] != nil)
        let manifest = try fixture.manifest()
        #expect(manifest["mcp"] as? [String] == ["mcp/servers.json#filesystem"])
    }
}

private struct ProjectCapabilityAuthoringFixture {
    let root: URL
    let project: AgentProject
    let pluginRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCapabilityAuthoringTests-\(UUID().uuidString)", isDirectory: true)
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

    func manifest() throws -> [String: Any] {
        try json(pluginRoot.appendingPathComponent("plugin.json"))
    }

    func json(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
