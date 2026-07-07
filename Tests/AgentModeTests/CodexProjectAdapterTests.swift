import XCTest
@testable import AgentMode

final class CodexProjectAdapterTests: XCTestCase {
    private var tmpHome: URL!
    private var project: AgentProject!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexProjectAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
        project = AgentProject(id: "p", name: "P", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true), isExternal: true, createdAt: Date(timeIntervalSince1970: 0))
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testPlanIncludesCodexConfigForEnabledMCPPlugin() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"])

        let plans = try CodexProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].engineID, AgentEngineKind.codex.rawValue)
        XCTAssertTrue(plans[0].operations.contains {
            if case let .writeFile(sourceDescription, destination) = $0 {
                return destination.path == project.rootURL.appendingPathComponent(".codex/config.toml").path
                    && sourceDescription.contains("filesystem")
            }
            return false
        })
    }

    func testPlanSkipsPluginWithoutCodexPolicy() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"], enginesJSON: "{}")

        let plans = try CodexProjectAdapter().plans(for: project)

        XCTAssertEqual(plans, [])
    }

    func testPlanSkipsDisabledCodexPolicy() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"], enginesJSON: #"{ "codex": { "enabled": false, "projection": "skills-and-mcp-files" } }"#)

        let plans = try CodexProjectAdapter().plans(for: project)

        XCTAssertEqual(plans, [])
    }

    func testPlanRejectsDuplicateMCPServerNames() throws {
        try writePlugin(id: "first", capabilities: ["mcp"])
        try writePlugin(id: "second", capabilities: ["mcp"])

        XCTAssertThrowsError(try CodexProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? CodexProjectAdapterError, .duplicateMCPServer("filesystem"))
        }
    }

    func testPlanAggregatesMultipleMCPPluginsIntoOneConfigWrite() throws {
        try writePlugin(id: "filesystem-plugin", capabilities: ["mcp"], serverName: "filesystem")
        try writePlugin(id: "memory-plugin", capabilities: ["mcp"], serverName: "memory")

        let plans = try CodexProjectAdapter().plans(for: project)
        let writes = plans.flatMap(\.operations).compactMap { operation -> String? in
            if case let .writeFile(sourceDescription, destination) = operation,
               destination.path == project.rootURL.appendingPathComponent(".codex/config.toml").path {
                return sourceDescription
            }
            return nil
        }

        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes[0].contains("filesystem"))
        XCTAssertTrue(writes[0].contains("memory"))
    }

    func testPlanRejectsMCPRefOutsideMCPDirectory() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"], mcpRefs: ["mcp/../outside.json#filesystem"])
        let pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
        try mcpServersJSON(serverName: "filesystem").data(using: .utf8)!.write(to: pluginRoot.appendingPathComponent("outside.json"), options: .atomic)

        XCTAssertThrowsError(try CodexProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? CodexProjectAdapterError, .mcpRefEscapesPlugin("mcp/../outside.json#filesystem"))
        }
    }

    func testPlanIncludesSkillCopyOperations() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])

        let plans = try CodexProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(plans[0].operations.contains {
            if case let .copyDirectory(source, destination) = $0 {
                return source.path.hasSuffix("skills/code-review")
                    && destination.path == project.rootURL.appendingPathComponent(".agents/skills/dev-toolkit-code-review", isDirectory: true).path
            }
            return false
        })
    }

    func testPlanRejectsMissingSkillDirectory() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/missing"])

        XCTAssertThrowsError(try CodexProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? CodexProjectAdapterError, .missingSkill("skills/missing"))
        }
    }

    func testPlanRejectsSkillRefOutsideSkillsDirectory() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/../outside"])
        let pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
        try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("outside", isDirectory: true), withIntermediateDirectories: true)

        XCTAssertThrowsError(try CodexProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? CodexProjectAdapterError, .skillRefEscapesPlugin("skills/../outside"))
        }
    }

    func testPlanRejectsSymlinkedSkillsRootOutsidePlugin() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])
        let pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
        try FileManager.default.removeItem(at: pluginRoot.appendingPathComponent("skills", isDirectory: true))
        let externalSkills = tmpHome.appendingPathComponent("external-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: externalSkills.appendingPathComponent("code-review", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pluginRoot.appendingPathComponent("skills", isDirectory: true), withDestinationURL: externalSkills)

        XCTAssertThrowsError(try CodexProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? CodexProjectAdapterError, .skillRefEscapesPlugin("skills/code-review"))
        }
    }

    private func writePlugin(
        id: String,
        capabilities: [String],
        mcpRefs: [String]? = nil,
        skills: [String] = [],
        enginesJSON: String = #"{ "codex": { "enabled": true, "projection": "skills-and-mcp-files" } }"#,
        serverName: String = "filesystem"
    ) throws {
        let dir = ProjectConfig.pluginDirectory(for: project, pluginID: id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("mcp", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("skills/code-review", isDirectory: true), withIntermediateDirectories: true)
        let capabilityJSON = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        let actualMCPRefs = mcpRefs ?? ["mcp/servers.json#\(serverName)"]
        let refsJSON = actualMCPRefs.map { "\"\($0)\"" }.joined(separator: ", ")
        let skillsJSON = skills.map { "\"\($0)\"" }.joined(separator: ", ")
        try """
        { "schemaVersion": 1, "id": "\(id)", "name": "Dev", "enabled": true, "capabilities": [\(capabilityJSON)], "mcp": [\(refsJSON)], "skills": [\(skillsJSON)], "engines": \(enginesJSON) }
        """.data(using: .utf8)!.write(to: dir.appendingPathComponent("plugin.json"), options: .atomic)
        try mcpServersJSON(serverName: serverName).data(using: .utf8)!.write(to: dir.appendingPathComponent("mcp/servers.json"), options: .atomic)
    }

    private func mcpServersJSON(serverName: String) -> String {
        """
        {
          "mcpServers": {
            "\(serverName)": { "type": "local", "command": ["npx", "-y", "@modelcontextprotocol/server-\(serverName)"], "enabled": true }
          }
        }
        """
    }
}
