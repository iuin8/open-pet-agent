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
        XCTAssertEqual(model.plugins[0].mcpServers.map(\.name), ["filesystem"])
        XCTAssertEqual(model.plugins[0].mcpServers[0].command, ["npx", "-y", "@modelcontextprotocol/server-filesystem"])
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

        XCTAssertTrue(diagnostics.containsDiagnostic("Missing MCP server: missing"))
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

    private func writeMCP(_ pluginID: String, _ name: String, command: [String]) throws {
        let dir = ProjectConfig.pluginMCPDirectory(for: project, pluginID: pluginID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encodedCommand = command.map { "\"\($0)\"" }.joined(separator: ", ")
        try """
        { "mcpServers": { "\(name)": { "type": "local", "command": [\(encodedCommand)], "enabled": true } } }
        """.data(using: .utf8)!.write(to: dir.appendingPathComponent("servers.json"), options: .atomic)
    }
}

private extension Array where Element == ProjectConfigDiagnostic {
    func containsDiagnostic(_ text: String) -> Bool {
        contains { $0.severity == .error && $0.message.contains(text) }
    }
}
