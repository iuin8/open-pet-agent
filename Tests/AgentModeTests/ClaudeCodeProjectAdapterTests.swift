import XCTest
@testable import AgentMode

final class ClaudeCodeProjectAdapterTests: XCTestCase {
    private var tmpHome: URL!
    private var project: AgentProject!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeProjectAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
        project = AgentProject(id: "p", name: "P", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true), isExternal: true, createdAt: Date(timeIntervalSince1970: 0))
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testPlanIncludesClaudeCodeConfigForEnabledMCPPlugin() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"])

        let plans = try ClaudeCodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].engineID, AgentEngineKind.claudeCode.rawValue)
        XCTAssertTrue(plans[0].operations.contains {
            if case let .writeFile(contents, destination) = $0 {
                return destination.path == project.rootURL.appendingPathComponent(".mcp.json").path
                    && contents.contains("filesystem")
            }
            return false
        })
    }

    func testPlanSkipsPluginWithoutClaudeCodePolicy() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"], enginesJSON: "{}")

        let plans = try ClaudeCodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans, [])
    }

    func testPlanSkipsDisabledClaudeCodePolicy() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"], enginesJSON: #"{ "claude-code": { "enabled": false, "projection": "skills-and-mcp-files" } }"#)

        let plans = try ClaudeCodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans, [])
    }

    func testPlanRejectsDuplicateMCPServerNames() throws {
        try writePlugin(id: "first", capabilities: ["mcp"])
        try writePlugin(id: "second", capabilities: ["mcp"])

        XCTAssertThrowsError(try ClaudeCodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? ClaudeCodeProjectAdapterError, .duplicateMCPServer("filesystem"))
        }
    }

    func testPlanAggregatesMultipleMCPPluginsIntoOneConfigWrite() throws {
        try writePlugin(id: "filesystem-plugin", capabilities: ["mcp"], serverName: "filesystem")
        try writePlugin(id: "memory-plugin", capabilities: ["mcp"], serverName: "memory")

        let plans = try ClaudeCodeProjectAdapter().plans(for: project)
        let writes = plans.flatMap(\.operations).compactMap { operation -> String? in
            if case let .writeFile(contents, destination) = operation,
               destination.path == project.rootURL.appendingPathComponent(".mcp.json").path {
                return contents
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

        XCTAssertThrowsError(try ClaudeCodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? ClaudeCodeProjectAdapterError, .mcpRefEscapesPlugin("mcp/../outside.json#filesystem"))
        }
    }

    func testPlanIncludesSkillCopyAndDiagnosticWhenMCPServerMissing() throws {
        try writePlugin(
            id: "dev-toolkit",
            capabilities: ["mcp", "skills"],
            mcpRefs: ["mcp/servers.json#missing"],
            skills: ["skills/code-review"]
        )

        let plans = try ClaudeCodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(plans[0].operations.contains {
            if case let .copyDirectory(source, destination) = $0 {
                return source.path.hasSuffix("skills/code-review")
                    && destination.path == project.rootURL.appendingPathComponent(".claude/skills/dev-toolkit-code-review", isDirectory: true).path
            }
            return false
        })
        XCTAssertFalse(plans[0].operations.contains {
            if case .writeFile = $0 { return true }
            return false
        })
        XCTAssertTrue(plans[0].diagnostics.contains {
            $0.severity == .warning && $0.message.contains("找不到 Claude Code MCP server: missing")
        })
    }

    func testPlanIncludesSkillCopyAndDiagnosticWhenMCPFileMissing() throws {
        try writePlugin(
            id: "dev-toolkit",
            capabilities: ["mcp", "skills"],
            skills: ["skills/code-review"]
        )
        try FileManager.default.removeItem(
            at: ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit").appendingPathComponent("mcp/servers.json")
        )

        let plans = try ClaudeCodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(plans[0].operations.contains {
            if case let .copyDirectory(source, destination) = $0 {
                return source.path.hasSuffix("skills/code-review")
                    && destination.path == project.rootURL.appendingPathComponent(".claude/skills/dev-toolkit-code-review", isDirectory: true).path
            }
            return false
        })
        XCTAssertTrue(plans[0].diagnostics.contains {
            $0.severity == .warning && $0.message.contains("无法读取 Claude Code MCP server 文件: mcp/servers.json#filesystem")
        })
    }

    func testPlanIncludesSkillCopyOperations() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])

        let plans = try ClaudeCodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(plans[0].operations.contains {
            if case let .copyDirectory(source, destination) = $0 {
                return source.path.hasSuffix("skills/code-review")
                    && destination.path == project.rootURL.appendingPathComponent(".claude/skills/dev-toolkit-code-review", isDirectory: true).path
            }
            return false
        })
    }

    func testPlanRejectsMissingSkillDirectory() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/missing"])

        XCTAssertThrowsError(try ClaudeCodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? ClaudeCodeProjectAdapterError, .missingSkill("skills/missing"))
        }
    }

    func testPlanRejectsSkillRefOutsideSkillsDirectory() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/../outside"])
        let pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
        try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("outside", isDirectory: true), withIntermediateDirectories: true)

        XCTAssertThrowsError(try ClaudeCodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? ClaudeCodeProjectAdapterError, .skillRefEscapesPlugin("skills/../outside"))
        }
    }

    func testPlanRejectsSymlinkedSkillsRootOutsidePlugin() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])
        let pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
        try FileManager.default.removeItem(at: pluginRoot.appendingPathComponent("skills", isDirectory: true))
        let externalSkills = tmpHome.appendingPathComponent("external-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: externalSkills.appendingPathComponent("code-review", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pluginRoot.appendingPathComponent("skills", isDirectory: true), withDestinationURL: externalSkills)

        XCTAssertThrowsError(try ClaudeCodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? ClaudeCodeProjectAdapterError, .skillRefEscapesPlugin("skills/code-review"))
        }
    }


    func testApplyWritesClaudeCodeConfigAndCopiesSkills() throws {
        try writePlugin(id: "filesystem-plugin", capabilities: ["mcp", "skills"], mcpRefs: ["mcp/servers.json#filesystem"], skills: ["skills/code-review"])
        try writePlugin(id: "memory-plugin", capabilities: ["mcp"], serverName: "memory")

        let plans = try ClaudeCodeProjectAdapter().plans(for: project)
        try ClaudeCodeProjectionMaterializer().apply(plans)

        let configURL = project.rootURL.appendingPathComponent(".mcp.json")
        let config = try JSONDecoder().decode(ACPJSON.self, from: Data(contentsOf: configURL))
        let servers = try XCTUnwrap(config.objectValue?["mcpServers"]?.objectValue)
        let filesystem = try XCTUnwrap(servers["filesystem"]?.objectValue)
        XCTAssertEqual(filesystem["command"]?.arrayValue?.compactMap(\.stringValue), ["npx", "-y", "@modelcontextprotocol/server-filesystem"])
        XCTAssertNotNil(servers["memory"])

        let copiedSkill = project.rootURL.appendingPathComponent(".claude/skills/filesystem-plugin-code-review", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedSkill.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testApplyReplacesExistingGeneratedSkillDirectory() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])
        let destination = project.rootURL.appendingPathComponent(".claude/skills/dev-toolkit-code-review", isDirectory: true)
        let plans = try ClaudeCodeProjectAdapter().plans(for: project)
        try ClaudeCodeProjectionMaterializer().apply(plans)
        try "stale".write(to: destination.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        let sourceReadme = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
            .appendingPathComponent("skills/code-review/README.md")
        try "fresh".write(to: sourceReadme, atomically: true, encoding: .utf8)

        try ClaudeCodeProjectionMaterializer().apply(plans)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale.txt").path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("README.md"), encoding: .utf8), "fresh")
    }


    func testApplyRendersStringCommandAndArgs() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"], serverName: "custom", commandJSON: #""uvx", "args": ["mcp-server", "--flag"]"#)

        let plans = try ClaudeCodeProjectAdapter().plans(for: project)
        try ClaudeCodeProjectionMaterializer().apply(plans)

        let config = try JSONDecoder().decode(ACPJSON.self, from: Data(contentsOf: project.rootURL.appendingPathComponent(".mcp.json")))
        let servers = try XCTUnwrap(config.objectValue?["mcpServers"]?.objectValue)
        let custom = try XCTUnwrap(servers["custom"]?.objectValue)
        XCTAssertEqual(custom["command"]?.stringValue, "uvx")
        XCTAssertEqual(custom["args"]?.arrayValue?.compactMap(\.stringValue), ["mcp-server", "--flag"])
    }


    func testApplyRejectsExistingUserMCPConfig() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"])
        let configURL = project.rootURL.appendingPathComponent(".mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"user\"".write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ClaudeCodeProjectionMaterializer().apply(ClaudeCodeProjectAdapter().plans(for: project))) { error in
            XCTAssertEqual(error as? ClaudeCodeProjectionMaterializerError, .unownedDestination(configURL))
        }
    }

    func testApplyRejectsSymlinkedMCPFileOutsideProject() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"])
        let externalMCP = tmpHome.appendingPathComponent("external-mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: externalMCP, withIntermediateDirectories: true)
        let configURL = project.rootURL.appendingPathComponent(".mcp.json")
        try FileManager.default.createDirectory(at: project.rootURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: externalMCP.appendingPathComponent("config.json"))

        XCTAssertThrowsError(try ClaudeCodeProjectionMaterializer().apply(ClaudeCodeProjectAdapter().plans(for: project))) { error in
            XCTAssertEqual(error as? ClaudeCodeProjectionMaterializerError, .destinationEscapesProject(configURL))
        }
    }

    func testApplyRejectsExistingUserSkillDirectory() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])
        let destination = project.rootURL.appendingPathComponent(".claude/skills/dev-toolkit-code-review", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "user".write(to: destination.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ClaudeCodeProjectionMaterializer().apply(ClaudeCodeProjectAdapter().plans(for: project))) { error in
            XCTAssertEqual(error as? ClaudeCodeProjectionMaterializerError, .unownedDestination(destination))
        }
    }

    func testApplyRejectsSymlinkedSkillsDirectoryOutsideProject() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])
        let claudeDir = project.rootURL.appendingPathComponent(".claude", isDirectory: true)
        let skillsDir = claudeDir.appendingPathComponent("skills", isDirectory: true)
        let externalSkills = tmpHome.appendingPathComponent("external-generated-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skillsDir, withDestinationURL: externalSkills)
        let destination = skillsDir.appendingPathComponent("dev-toolkit-code-review", isDirectory: true)

        XCTAssertThrowsError(try ClaudeCodeProjectionMaterializer().apply(ClaudeCodeProjectAdapter().plans(for: project))) { error in
            XCTAssertEqual(error as? ClaudeCodeProjectionMaterializerError, .destinationEscapesProject(destination))
        }
    }

    func testApplyEscapesJSONControlCharacters() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"], serverName: "custom", commandJSON: #""uvx", "args": ["line\\nbreak"]"#)

        let plans = try ClaudeCodeProjectAdapter().plans(for: project)
        try ClaudeCodeProjectionMaterializer().apply(plans)

        let config = try String(contentsOf: project.rootURL.appendingPathComponent(".mcp.json"), encoding: .utf8)
        XCTAssertTrue(config.contains("\"line\\\\nbreak\""))
    }

    private func writePlugin(
        id: String,
        capabilities: [String],
        mcpRefs: [String]? = nil,
        skills: [String] = [],
        enginesJSON: String = #"{ "claude-code": { "enabled": true, "projection": "skills-and-mcp-files" } }"#,
        serverName: String = "filesystem",
        commandJSON: String? = nil
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
        try mcpServersJSON(serverName: serverName, commandJSON: commandJSON).data(using: .utf8)!.write(to: dir.appendingPathComponent("mcp/servers.json"), options: .atomic)
    }

    private func mcpServersJSON(serverName: String, commandJSON: String? = nil) -> String {
        let command = commandJSON ?? #"["npx", "-y", "@modelcontextprotocol/server-\#(serverName)"]"#
        return """
        {
          "mcpServers": {
            "\(serverName)": { "type": "local", "command": \(command), "enabled": true }
          }
        }
        """
    }
}
