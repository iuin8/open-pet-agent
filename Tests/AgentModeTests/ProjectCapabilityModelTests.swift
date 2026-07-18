import XCTest
@testable import AgentMode

final class ProjectCapabilityModelTests: XCTestCase {
    private var tmpHome: URL!
    private var project: AgentProject!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectCapabilityModelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
        project = AgentProject(id: "p", name: "P", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true), isExternal: true, createdAt: Date(timeIntervalSince1970: 0))
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testBuildsTypedModelFromPluginCatalog() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev Toolkit", "version": "1.0.0", "enabled": true, "capabilities": ["mcp", "skills"], "mcp": ["mcp/servers.json#filesystem"], "skills": ["skills/code-review"], "engines": { "codex": { "enabled": true, "projection": "skills-and-mcp-files" } } }
        """)
        try writeSkill("dev-toolkit", "code-review", "# code-review\n\nReview staged diffs.")
        try writeMCP("dev-toolkit", "filesystem", command: ["npx", "-y", "@modelcontextprotocol/server-filesystem"])

        let model = try ProjectCapabilityCatalogModel.build(for: project)

        XCTAssertEqual(model.projectID, "p")
        XCTAssertEqual(model.plugins.map(\.id), ["dev-toolkit"])
        XCTAssertEqual(model.plugins[0].name, "Dev Toolkit")
        XCTAssertEqual(model.plugins[0].version, "1.0.0")
        XCTAssertTrue(model.plugins[0].enabled)
        XCTAssertEqual(model.plugins[0].skills.map(\.id), ["dev-toolkit:skills/code-review"])
        XCTAssertEqual(model.plugins[0].skills[0].name, "code-review")
        XCTAssertEqual(model.plugins[0].skills[0].summary, "Review staged diffs.")
        XCTAssertEqual(model.plugins[0].skills[0].body, "# code-review\n\nReview staged diffs.")
        XCTAssertEqual(model.plugins[0].mcpServers.map(\.name), ["filesystem"])
        XCTAssertEqual(model.plugins[0].mcpServers[0].command, ["npx", "-y", "@modelcontextprotocol/server-filesystem"])
    }

    func testSkillModelKeepsFullBodyAndTruncatedPreview() throws {
        let body = "# long-skill\n\n" + String(repeating: "正文", count: 180)
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev Toolkit", "enabled": true, "capabilities": ["skills"], "skills": ["skills/long-skill"], "engines": {} }
        """)
        try writeSkill("dev-toolkit", "long-skill", body)

        let skill = try XCTUnwrap(ProjectCapabilityCatalogModel.build(for: project).plugins.first?.skills.first)

        XCTAssertEqual(skill.body, body)
        XCTAssertEqual(skill.bodyPreview, String(body.prefix(240)))
        XCTAssertGreaterThan(skill.body?.count ?? 0, skill.bodyPreview?.count ?? 0)
    }

    func testValidatorReportsMissingSkill() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "skills": ["skills/missing"], "engines": {} }
        """)

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)

        XCTAssertTrue(diagnostics.containsDiagnostic("Missing skill: skills/missing"))
    }

    func testValidatorReportsSkillPathEscape() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["skills"], "skills": ["../outside"], "engines": {} }
        """)

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)

        XCTAssertTrue(diagnostics.containsDiagnostic("Skill reference escapes plugin: ../outside"))
    }

    func testValidatorReportsMissingMCPServer() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#missing"], "engines": {} }
        """)
        try writeMCP("dev-toolkit", "filesystem", command: ["npx"])

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)

        XCTAssertTrue(diagnostics.containsDiagnostic("Missing MCP server: missing", severity: .warning))
    }

    func testBuildKeepsMissingMCPRefAsWarningPlaceholder() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#missing"], "engines": {} }
        """)
        try writeMCP("dev-toolkit", "filesystem", command: ["npx"])

        let server = try XCTUnwrap(ProjectCapabilityCatalogModel.build(for: project).plugins.first?.mcpServers.first)

        XCTAssertEqual(server.name, "missing")
        XCTAssertEqual(server.fileRef, "mcp/servers.json")
        XCTAssertEqual(server.command, [])
        XCTAssertTrue(server.diagnostics.contains { $0.severity == .warning && $0.message.contains("Missing MCP server: missing") })
    }

    func testValidatorReportsMalformedMCPCommand() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#bad"], "engines": {} }
        """)
        let mcpURL = ProjectConfig.pluginMCPDirectory(for: project, pluginID: "dev-toolkit").appendingPathComponent("servers.json")
        try FileManager.default.createDirectory(at: mcpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        { "mcpServers": { "bad": { "type": "local", "command": [], "enabled": true } } }
        """.data(using: .utf8)!.write(to: mcpURL, options: .atomic)

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)

        XCTAssertTrue(diagnostics.containsDiagnostic("Malformed MCP command: bad"))
    }

    func testValidatorReportsDuplicateIDs() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp", "skills"], "mcp": ["mcp/servers.json#filesystem", "mcp/servers.json#filesystem"], "skills": ["skills/code-review", "skills/code-review"], "engines": {} }
        """)
        try writeSkill("dev-toolkit", "code-review", "# code-review")
        try writeMCP("dev-toolkit", "filesystem", command: ["npx"])

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)

        XCTAssertTrue(diagnostics.containsDiagnostic("Duplicate skill id: dev-toolkit:skills/code-review"))
        XCTAssertTrue(diagnostics.containsDiagnostic("Duplicate MCP server id: dev-toolkit:filesystem"))
    }

    func testMCPModelKeepsFileRefAndRoundTrippableRawJSON() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/custom.json#remote"], "engines": {} }
        """)
        let mcpURL = ProjectConfig.pluginMCPDirectory(for: project, pluginID: "dev-toolkit")
            .appendingPathComponent("custom.json")
        try FileManager.default.createDirectory(at: mcpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        { "mcpServers": { "remote": { "type": "sse", "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer token" }, "enabled": true } } }
        """.data(using: .utf8)!.write(to: mcpURL, options: .atomic)

        let server = try XCTUnwrap(ProjectCapabilityCatalogModel.build(for: project).plugins.first?.mcpServers.first)

        XCTAssertEqual(server.fileRef, "mcp/custom.json")
        XCTAssertEqual(server.transport, .sse)
        XCTAssertEqual(server.url, "https://example.com/mcp")
        XCTAssertEqual(
            ACPJSON.parse(try XCTUnwrap(server.rawJSON)),
            .object([
                "type": .string("sse"),
                "url": .string("https://example.com/mcp"),
                "headers": .object(["Authorization": .string("Bearer token")]),
                "enabled": .bool(true)
            ])
        )
    }

    func testValidatorAcceptsRemoteMCPTransportWithURL() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#remote"], "engines": {} }
        """)
        let mcpURL = ProjectConfig.pluginMCPDirectory(for: project, pluginID: "dev-toolkit").appendingPathComponent("servers.json")
        try FileManager.default.createDirectory(at: mcpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        { "mcpServers": { "remote": { "type": "http", "url": "https://example.com/mcp", "enabled": true } } }
        """.data(using: .utf8)!.write(to: mcpURL, options: .atomic)

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)

        XCTAssertFalse(diagnostics.containsDiagnostic("Malformed MCP command: remote"))
    }

    func testValidatorWarnsAboutMissingMCPCommandPath() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#missing-command"], "engines": {} }
        """)
        try writeMCP("dev-toolkit", "missing-command", command: ["openpetagent-missing-mcp-command"])

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)
        let server = try XCTUnwrap(ProjectCapabilityCatalogModel.build(for: project).plugins.first?.mcpServers.first)

        XCTAssertTrue(diagnostics.containsDiagnostic("MCP command not found: missing-command", severity: .warning))
        XCTAssertTrue(server.diagnostics.containsDiagnostic("MCP command not found: missing-command", severity: .warning))
    }

    func testValidatorWarnsAboutMissingMCPCWD() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#cwd-missing"], "engines": {} }
        """)
        let missingCWD = tmpHome.appendingPathComponent("missing-workdir").path
        try writeMCP("dev-toolkit", "cwd-missing", command: ["/bin/echo"], extra: #", "cwd": "\#(missingCWD)""#)

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)
        let server = try XCTUnwrap(ProjectCapabilityCatalogModel.build(for: project).plugins.first?.mcpServers.first)

        XCTAssertTrue(diagnostics.containsDiagnostic("MCP cwd missing: cwd-missing", severity: .warning))
        XCTAssertTrue(server.diagnostics.containsDiagnostic("MCP cwd missing: cwd-missing", severity: .warning))
    }

    func testValidatorWarnsAboutMissingMCPEnvValue() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#env-missing"], "engines": {} }
        """)
        try writeMCP("dev-toolkit", "env-missing", command: ["/bin/echo"], extra: #", "env": { "TOKEN": "" }"#)

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)
        let server = try XCTUnwrap(ProjectCapabilityCatalogModel.build(for: project).plugins.first?.mcpServers.first)

        XCTAssertTrue(diagnostics.containsDiagnostic("MCP env missing: env-missing TOKEN", severity: .warning))
        XCTAssertTrue(server.diagnostics.containsDiagnostic("MCP env missing: env-missing TOKEN", severity: .warning))
    }

    func testValidatorWarnsAboutEmptyMCPArgsArray() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#empty-args"], "engines": {} }
        """)
        try writeMCP("dev-toolkit", "empty-args", command: ["/bin/echo"], extra: #", "args": []"#)

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)
        let server = try XCTUnwrap(ProjectCapabilityCatalogModel.build(for: project).plugins.first?.mcpServers.first)

        XCTAssertTrue(diagnostics.containsDiagnostic("MCP args empty: empty-args", severity: .warning))
        XCTAssertTrue(server.diagnostics.containsDiagnostic("MCP args empty: empty-args", severity: .warning))
    }

    func testValidatorResolvesRelativeMCPCommandAgainstCWD() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#relative-command"], "engines": {} }
        """)
        let workdir = tmpHome.appendingPathComponent("workdir", isDirectory: true)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        let tool = workdir.appendingPathComponent("tool")
        try """
        #!/bin/sh
        exit 0
        """.data(using: .utf8)!.write(to: tool, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try writeMCP("dev-toolkit", "relative-command", command: ["./tool"], extra: #", "cwd": "\#(workdir.path)""#)

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)
        let server = try XCTUnwrap(ProjectCapabilityCatalogModel.build(for: project).plugins.first?.mcpServers.first)

        XCTAssertFalse(diagnostics.containsDiagnostic("MCP command not found: relative-command", severity: .warning))
        XCTAssertFalse(server.diagnostics.containsDiagnostic("MCP command not found: relative-command", severity: .warning))
    }

    func testValidatorWarnsAboutMalformedRemoteMCPURL() throws {
        try writePlugin("dev-toolkit", """
        { "schemaVersion": 1, "id": "dev-toolkit", "name": "Dev", "enabled": true, "capabilities": ["mcp"], "mcp": ["mcp/servers.json#remote"], "engines": {} }
        """)
        let mcpURL = ProjectConfig.pluginMCPDirectory(for: project, pluginID: "dev-toolkit").appendingPathComponent("servers.json")
        try FileManager.default.createDirectory(at: mcpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        { "mcpServers": { "remote": { "type": "http", "url": "https://", "enabled": true } } }
        """.data(using: .utf8)!.write(to: mcpURL, options: .atomic)

        let diagnostics = try ProjectCapabilityValidator().validate(project: project)
        let server = try XCTUnwrap(ProjectCapabilityCatalogModel.build(for: project).plugins.first?.mcpServers.first)

        XCTAssertTrue(diagnostics.containsDiagnostic("MCP URL malformed: remote", severity: .warning))
        XCTAssertFalse(diagnostics.containsDiagnostic("Malformed MCP command: remote"))
        XCTAssertTrue(server.diagnostics.containsDiagnostic("MCP URL malformed: remote", severity: .warning))
    }

    private func writePlugin(_ id: String, _ json: String) throws {
        let dir = ProjectConfig.pluginDirectory(for: project, pluginID: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("plugin.json"), options: .atomic)
    }

    private func writeSkill(_ pluginID: String, _ name: String, _ body: String) throws {
        let dir = ProjectConfig.pluginSkillsDirectory(for: project, pluginID: pluginID).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.data(using: .utf8)!.write(to: dir.appendingPathComponent("SKILL.md"), options: .atomic)
    }

    private func writeMCP(_ pluginID: String, _ name: String, command: [String], extra: String = "") throws {
        let dir = ProjectConfig.pluginMCPDirectory(for: project, pluginID: pluginID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encodedCommand = command.map { "\"\($0)\"" }.joined(separator: ", ")
        try """
        { "mcpServers": { "\(name)": { "type": "local", "command": [\(encodedCommand)], "enabled": true\(extra) } } }
        """.data(using: .utf8)!.write(to: dir.appendingPathComponent("servers.json"), options: .atomic)
    }
}

private extension Array where Element == ProjectConfigDiagnostic {
    func containsDiagnostic(_ text: String, severity: ProjectConfigDiagnostic.Severity = .error) -> Bool {
        contains { $0.severity == severity && $0.message.contains(text) }
    }
}
