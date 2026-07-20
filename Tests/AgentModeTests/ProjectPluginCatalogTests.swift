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
        XCTAssertEqual(plugins[0].sourceMetadata.kind, .local)
        XCTAssertEqual(plugins[0].sourceMetadata.contentHash, "sha256:test")
    }

    func testSourceMetadataMissingUnknownAndMalformedStayCompatible() throws {
        try writePlugin("legacy", """
        { "schemaVersion": 1, "id": "legacy", "name": "Legacy", "enabled": true, "capabilities": [], "engines": {} }
        """)
        try writePlugin("future", """
        { "schemaVersion": 1, "id": "future", "name": "Future", "source": { "kind": "registry", "url": "https://example.com/plugin", "revision": "abc123", "installedAt": "2026-07-19T00:00:00Z" }, "enabled": true, "capabilities": [], "engines": {} }
        """)
        try writePlugin("bad-shape", """
        { "schemaVersion": 1, "id": "bad-shape", "name": "Bad Shape", "source": "bad", "enabled": true, "capabilities": [], "engines": {} }
        """)
        try writePlugin("bad-kind", """
        { "schemaVersion": 1, "id": "bad-kind", "name": "Bad Kind", "source": { "kind": 123, "url": "https://example.com/bad" }, "enabled": true, "capabilities": [], "engines": {} }
        """)

        let plugins = try ProjectPluginCatalog().listPlugins(for: project)

        XCTAssertEqual(plugins.first { $0.id == "legacy" }?.sourceMetadata.kind, .manual)
        let future = try XCTUnwrap(plugins.first { $0.id == "future" })
        XCTAssertEqual(future.sourceMetadata.kind, .unknown)
        XCTAssertEqual(future.sourceMetadata.url, "https://example.com/plugin")
        XCTAssertEqual(future.sourceMetadata.revision, "abc123")
        XCTAssertEqual(plugins.first { $0.id == "bad-shape" }?.sourceMetadata.kind, .unknown)
        let badKind = try XCTUnwrap(plugins.first { $0.id == "bad-kind" })
        XCTAssertEqual(badKind.sourceMetadata.kind, .unknown)
        XCTAssertEqual(badKind.sourceMetadata.url, "https://example.com/bad")
    }

    func testSourceMetadataLabelsDescribeProvenanceAndTrustBoundary() {
        let manual = ProjectPluginSourceMetadata(kind: .manual)
        XCTAssertEqual(manual.provenanceLabel, "manual")
        XCTAssertEqual(manual.trustLabel, "本地 · manual")

        let git = ProjectPluginSourceMetadata(kind: .git, revision: "abc123")
        XCTAssertEqual(git.provenanceLabel, "git · abc123")
        XCTAssertEqual(git.trustLabel, "需确认 · git")

        let unknown = ProjectPluginSourceMetadata(kind: .unknown, url: "https://example.com/plugin")
        XCTAssertEqual(unknown.provenanceLabel, "unknown")
        XCTAssertEqual(unknown.trustLabel, "未知来源")
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

    func testListPluginsSkipsMaterializedDirectory() throws {
        let materialized = ProjectConfig.pluginRoot(for: project).appendingPathComponent(".materialized", isDirectory: true)
        try FileManager.default.createDirectory(at: materialized, withIntermediateDirectories: true)
        try """
        { "schemaVersion": 1, "id": ".materialized", "name": "Projected", "enabled": true, "capabilities": ["mcp"], "engines": {} }
        """.data(using: .utf8)!.write(to: materialized.appendingPathComponent("plugin.json"), options: .atomic)
        try writePlugin("normal", """
        { "schemaVersion": 1, "id": "normal", "name": "Normal", "enabled": true, "capabilities": ["skills"], "engines": {} }
        """)

        let plugins = try ProjectPluginCatalog().listPlugins(for: project)

        XCTAssertEqual(plugins.map(\.id), ["normal"])
    }

    func testValidateErrorsOnDuplicateMCPReferences() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#filesystem", "mcp/servers.json#filesystem"], "engines": {} }
        """)

        let plugin = try ProjectPluginCatalog().listPlugins(for: project).first!
        let diagnostics = ProjectPluginCatalog().validate(plugin)

        XCTAssertTrue(diagnostics.contains { $0.severity == .error && $0.message.contains("Duplicate") && $0.message.contains("mcp/servers.json#filesystem") })
    }

    func testValidateErrorsOnDuplicateSkillReferences() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "skills": ["skills/code-review", "skills/code-review"], "engines": {} }
        """)

        let plugin = try ProjectPluginCatalog().listPlugins(for: project).first!
        let diagnostics = ProjectPluginCatalog().validate(plugin)

        XCTAssertTrue(diagnostics.contains { $0.severity == .error && $0.message.contains("Duplicate") && $0.message.contains("skills/code-review") })
    }

    private func writePlugin(_ id: String, _ json: String) throws {
        let dir = ProjectConfig.pluginDirectory(for: project, pluginID: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("plugin.json"), options: .atomic)
    }
}
