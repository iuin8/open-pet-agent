import XCTest
@testable import AgentMode

final class ProjectCapabilityWriterTests: XCTestCase {
    private var tmpHome: URL!
    private var project: AgentProject!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCapabilityWriterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
        project = AgentProject(id: "p", name: "P", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true), isExternal: true, createdAt: Date(timeIntervalSince1970: 0))
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testUpdateSkillBodyPreservesManifestAndDoesNotMaterialize() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "skills": ["skills/code-review"], "engines": { "codex": { "enabled": true, "projection": "skills-and-mcp-files" }, "claude-code": { "enabled": true, "projection": "skills-and-mcp-files" } } }
        """)
        try writeSkill("dev-toolkit", "code-review", "# code-review\n\nOld body.\n")
        let manifestBefore = try Data(contentsOf: pluginRoot("dev-toolkit").appendingPathComponent("plugin.json"))

        try ProjectCapabilityWriter().updateSkillBody(project: project, pluginID: "dev-toolkit", skillRef: "skills/code-review", body: "# code-review\n\nNew body.\n")

        let skillBody = try String(contentsOf: pluginRoot("dev-toolkit").appendingPathComponent("skills/code-review/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(skillBody, "# code-review\n\nNew body.\n")
        XCTAssertEqual(try Data(contentsOf: pluginRoot("dev-toolkit").appendingPathComponent("plugin.json")), manifestBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.appendingPathComponent(".codex/config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.appendingPathComponent(".mcp.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.appendingPathComponent(".agents").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.appendingPathComponent(".claude").path))
    }

    func testUpsertMCPServerMergePreservesOtherServersAndUnknownFields() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#filesystem"], "engines": {} }
        """)
        let mcpURL = pluginRoot("dev-toolkit").appendingPathComponent("mcp/servers.json")
        try FileManager.default.createDirectory(at: mcpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        { "mcpServers": { "filesystem": { "type": "local", "command": ["npx"], "enabled": true, "note": "keep" }, "other": { "type": "local", "command": ["other"], "enabled": false } }, "topLevel": "keep" }
        """.data(using: .utf8)!.write(to: mcpURL, options: .atomic)

        try ProjectCapabilityWriter().upsertMCPServer(
            project: project,
            pluginID: "dev-toolkit",
            fileRef: "mcp/servers.json",
            serverName: "filesystem",
            value: .object([
                "type": .string("local"),
                "command": .array([.string("npx"), .string("-y"), .string("@modelcontextprotocol/server-filesystem")]),
                "enabled": .bool(true),
                "note": .string("keep")
            ])
        )

        let json = try readJSONObject(mcpURL)
        XCTAssertEqual(json["topLevel"] as? String, "keep")
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        let filesystem = try XCTUnwrap(servers["filesystem"] as? [String: Any])
        XCTAssertEqual(filesystem["note"] as? String, "keep")
        XCTAssertEqual(filesystem["command"] as? [String], ["npx", "-y", "@modelcontextprotocol/server-filesystem"])
    }

    func testDeleteSkillBacksUpBeforeRemoving() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "skills": ["skills/code-review"], "engines": {} }
        """)
        try writeSkill("dev-toolkit", "code-review", "# code-review\n\nBody.\n")

        try ProjectCapabilityWriter().deleteSkill(project: project, pluginID: "dev-toolkit", skillRef: "skills/code-review")

        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginRoot("dev-toolkit").appendingPathComponent("skills/code-review").path))
        let backupRoot = project.rootURL.appendingPathComponent(".open-pet-agent/backups/capabilities", isDirectory: true)
        let backups = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups[0].appendingPathComponent("dev-toolkit/skills/code-review/SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups[0].appendingPathComponent("dev-toolkit/plugin.json").path))
    }

    func testRejectsSkillPathEscapeWithoutTouchingOutsideFile() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "skills": ["../outside"], "engines": {} }
        """)
        let outside = tmpHome.appendingPathComponent("outside/SKILL.md")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "original".data(using: .utf8)!.write(to: outside, options: .atomic)

        XCTAssertThrowsError(try ProjectCapabilityWriter().updateSkillBody(project: project, pluginID: "dev-toolkit", skillRef: "../outside", body: "changed"))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "original")
    }

    func testExecutableCapabilitiesAreNeverMaterialized() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "executableCapabilities": { "hooks": true, "bin": true, "opencodePlugin": true }, "skills": ["skills/code-review"], "engines": { "opencode": { "enabled": true, "projection": "plugin-dir" } } }
        """)
        try writeSkill("dev-toolkit", "code-review", "# code-review\n")

        try ProjectCapabilityWriter().updateSkillBody(project: project, pluginID: "dev-toolkit", skillRef: "skills/code-review", body: "# code-review\n\nUpdated.\n")

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.appendingPathComponent(".open-pet-agent/plugins/.materialized").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.appendingPathComponent("hooks").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.appendingPathComponent("bin").path))
    }

    func testDeleteSkillRejectsSymlinkAliasWithoutDeletingTarget() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "skills": ["skills/alias"], "engines": {} }
        """)
        try writeSkill("dev-toolkit", "code-review", "# code-review\n")
        let alias = pluginRoot("dev-toolkit").appendingPathComponent("skills/alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: pluginRoot("dev-toolkit").appendingPathComponent("skills/code-review", isDirectory: true)
        )

        XCTAssertThrowsError(try ProjectCapabilityWriter().deleteSkill(project: project, pluginID: "dev-toolkit", skillRef: "skills/alias"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginRoot("dev-toolkit").appendingPathComponent("skills/code-review/SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
    }

    func testDeleteSkillRejectsSkillsRootRef() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "skills": ["skills/code-review"], "engines": {} }
        """)
        try writeSkill("dev-toolkit", "code-review", "# code-review\n")

        XCTAssertThrowsError(try ProjectCapabilityWriter().deleteSkill(project: project, pluginID: "dev-toolkit", skillRef: "skills"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginRoot("dev-toolkit").appendingPathComponent("skills/code-review/SKILL.md").path))
    }

    func testUpsertMCPServerRejectsEmptyName() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": [], "engines": {} }
        """)
        let mcpURL = pluginRoot("dev-toolkit").appendingPathComponent("mcp/servers.json")

        XCTAssertThrowsError(try ProjectCapabilityWriter().upsertMCPServer(
            project: project,
            pluginID: "dev-toolkit",
            fileRef: "mcp/servers.json",
            serverName: "",
            value: .object(["type": .string("local"), "command": .array([.string("npx")])])
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: mcpURL.path))
    }

    func testEditingOnePluginIgnoresUnrelatedMalformedPlugin() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "skills": ["skills/code-review"], "engines": {} }
        """)
        try writeSkill("dev-toolkit", "code-review", "# code-review\n")
        try writePlugin("broken", """
        { "schemaVersion": 1, "id": "not-broken", "name": "Broken", "enabled": true, "capabilities": [] }
        """)

        try ProjectCapabilityWriter().updateSkillBody(project: project, pluginID: "dev-toolkit", skillRef: "skills/code-review", body: "# code-review\n\nUpdated.\n")

        let body = try String(contentsOf: pluginRoot("dev-toolkit").appendingPathComponent("skills/code-review/SKILL.md"), encoding: .utf8)
        XCTAssertEqual(body, "# code-review\n\nUpdated.\n")
    }

    private func pluginRoot(_ id: String) -> URL {
        ProjectConfig.pluginDirectory(for: project, pluginID: id)
    }

    private func writePlugin(_ id: String, _ json: String) throws {
        let dir = pluginRoot(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("plugin.json"), options: .atomic)
    }

    private func writeSkill(_ pluginID: String, _ name: String, _ body: String) throws {
        let dir = ProjectConfig.pluginSkillsDirectory(for: project, pluginID: pluginID).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.data(using: .utf8)!.write(to: dir.appendingPathComponent("SKILL.md"), options: .atomic)
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
