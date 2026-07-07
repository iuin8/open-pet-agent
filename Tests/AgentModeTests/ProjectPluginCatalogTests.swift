import XCTest
@testable import AgentMode

final class ProjectPluginCatalogTests: XCTestCase {
    private var tmpHome: URL!
    private var project: AgentProject!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectPluginCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
        project = AgentProject(id: "p", name: "P", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true), isExternal: true, createdAt: Date(timeIntervalSince1970: 0))
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testListPluginsReadsNamedPluginManifests() throws {
        try writePlugin("dev-toolkit", """
        {
          "schemaVersion": 1,
          "id": "dev-toolkit",
          "name": "Dev Toolkit",
          "version": "1.0.0",
          "source": { "kind": "local", "url": null, "revision": null, "contentHash": "sha256:test" },
          "enabled": true,
          "capabilities": ["mcp", "skills"],
          "executableCapabilities": { "hooks": false, "bin": false, "opencodePlugin": false },
          "mcp": ["mcp/servers.json#filesystem"],
          "skills": ["skills/code-review"],
          "prompts": [],
          "engines": { "opencode": { "enabled": true, "projection": "plugin-dir" } }
        }
        """)

        let plugins = try ProjectPluginCatalog().listPlugins(for: project)

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins[0].id, "dev-toolkit")
        XCTAssertEqual(plugins[0].name, "Dev Toolkit")
        XCTAssertEqual(plugins[0].version, "1.0.0")
        XCTAssertTrue(plugins[0].enabled)
        XCTAssertEqual(plugins[0].capabilities, [.mcp, .skills])
        XCTAssertEqual(plugins[0].enginePolicies["opencode"], .pluginDir)
    }

    func testManifestIDMustMatchDirectoryName() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "other", "name": "Other", "enabled": true, "capabilities": [], "engines": {} }
        """)

        XCTAssertThrowsError(try ProjectPluginCatalog().listPlugins(for: project)) { error in
            XCTAssertTrue(String(describing: error).contains("id"))
        }
    }

    func testUnknownCapabilityProducesWarningButDoesNotThrow() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp", "futureThing"], "engines": {} }
        """)

        let plugin = try ProjectPluginCatalog().listPlugins(for: project).first!
        let diagnostics = ProjectPluginCatalog().validate(plugin)

        XCTAssertEqual(plugin.capabilities, [.mcp])
        XCTAssertTrue(diagnostics.contains { $0.severity == .warning && $0.message.contains("futureThing") })
    }

    func testExecutableCapabilitiesDefaultFalse() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "engines": {} }
        """)

        let plugin = try ProjectPluginCatalog().listPlugins(for: project).first!
        XCTAssertEqual(plugin.executableCapabilities, ProjectExecutableCapabilities())
    }

    private func writePlugin(_ id: String, _ json: String) throws {
        let dir = ProjectConfig.pluginDirectory(for: project, pluginID: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("plugin.json"), options: .atomic)
    }
}
