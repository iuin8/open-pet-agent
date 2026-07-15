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
            if case let .writeFile(contents, destination) = $0 {
                return destination.path == project.rootURL.appendingPathComponent(".codex/config.toml").path
                    && contents.contains("filesystem")
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
            if case let .writeFile(contents, destination) = operation,
               destination.path == project.rootURL.appendingPathComponent(".codex/config.toml").path {
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

        XCTAssertThrowsError(try CodexProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? CodexProjectAdapterError, .mcpRefEscapesPlugin("mcp/../outside.json#filesystem"))
        }
    }

    func testPlanIncludesSkillCopyAndDiagnosticWhenMCPServerMissing() throws {
        try writePlugin(
            id: "dev-toolkit",
            capabilities: ["mcp", "skills"],
            mcpRefs: ["mcp/servers.json#missing"],
            skills: ["skills/code-review"]
        )

        let plans = try CodexProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(plans[0].operations.contains {
            if case let .copyDirectory(source, destination) = $0 {
                return source.path.hasSuffix("skills/code-review")
                    && destination.path == project.rootURL.appendingPathComponent(".agents/skills/dev-toolkit-code-review", isDirectory: true).path
            }
            return false
        })
        XCTAssertFalse(plans[0].operations.contains {
            if case .writeFile = $0 { return true }
            return false
        })
        XCTAssertTrue(plans[0].diagnostics.contains {
            $0.severity == .warning && $0.message.contains("找不到 Codex MCP server: missing")
        })
    }

    func testPlanRejectsMCPServerInvalidForCodex() throws {
        try writePlugin(
            id: "dev-toolkit",
            capabilities: ["mcp", "skills"],
            skills: ["skills/code-review"],
            serverName: "bad",
            commandJSON: #"[]"#
        )

        XCTAssertThrowsError(try CodexProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? CodexProjectAdapterError, .invalidMCPServer("bad"))
        }
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

        let plans = try CodexProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(plans[0].operations.contains {
            if case let .copyDirectory(source, destination) = $0 {
                return source.path.hasSuffix("skills/code-review")
                    && destination.path == project.rootURL.appendingPathComponent(".agents/skills/dev-toolkit-code-review", isDirectory: true).path
            }
            return false
        })
        XCTAssertTrue(plans[0].diagnostics.contains {
            $0.severity == .warning && $0.message.contains("无法读取 Codex MCP server 文件: mcp/servers.json#filesystem")
        })
    }

    func testPlanRejectsMalformedMCPFile() throws {
        try writePlugin(
            id: "dev-toolkit",
            capabilities: ["mcp", "skills"],
            skills: ["skills/code-review"]
        )
        try Data("not json".utf8).write(
            to: ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit").appendingPathComponent("mcp/servers.json"),
            options: .atomic
        )

        XCTAssertThrowsError(try CodexProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? CodexProjectAdapterError, .invalidMCPServer("mcp/servers.json#filesystem"))
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


    func testApplyWritesCodexConfigAndCopiesSkills() throws {
        try writePlugin(id: "filesystem-plugin", capabilities: ["mcp", "skills"], mcpRefs: ["mcp/servers.json#filesystem"], skills: ["skills/code-review"])
        try writePlugin(id: "memory-plugin", capabilities: ["mcp"], serverName: "memory")

        let plans = try CodexProjectAdapter().plans(for: project)
        try CodexProjectionMaterializer().apply(plans)

        let configURL = project.rootURL.appendingPathComponent(".codex/config.toml")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(config.contains("[mcp_servers.filesystem]"))
        XCTAssertTrue(config.contains("command = \"npx\""))
        XCTAssertTrue(config.contains("args = [\"-y\", \"@modelcontextprotocol/server-filesystem\"]"))
        XCTAssertTrue(config.contains("[mcp_servers.memory]"))

        let copiedSkill = project.rootURL.appendingPathComponent(".agents/skills/filesystem-plugin-code-review", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedSkill.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testApplyReplacesExistingGeneratedSkillDirectory() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])
        let destination = project.rootURL.appendingPathComponent(".agents/skills/dev-toolkit-code-review", isDirectory: true)
        let plans = try CodexProjectAdapter().plans(for: project)
        try CodexProjectionMaterializer().apply(plans)
        try "stale".write(to: destination.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        let sourceReadme = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
            .appendingPathComponent("skills/code-review/README.md")
        try "fresh".write(to: sourceReadme, atomically: true, encoding: .utf8)

        try CodexProjectionMaterializer().apply(plans)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale.txt").path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("README.md"), encoding: .utf8), "fresh")
    }


    func testApplyRendersStringCommandAndArgs() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"], serverName: "custom", commandJSON: #""uvx", "args": ["mcp-server", "--flag"]"#)

        let plans = try CodexProjectAdapter().plans(for: project)
        try CodexProjectionMaterializer().apply(plans)

        let config = try String(contentsOf: project.rootURL.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("[mcp_servers.custom]"))
        XCTAssertTrue(config.contains("command = \"uvx\""))
        XCTAssertTrue(config.contains("args = [\"mcp-server\", \"--flag\"]"))
    }


    func testApplyRejectsExistingUserCodexConfig() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"])
        let configURL = project.rootURL.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"user\"".write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try CodexProjectionMaterializer().apply(CodexProjectAdapter().plans(for: project))) { error in
            XCTAssertEqual(error as? CodexProjectionMaterializerError, .unownedDestination(configURL))
        }
    }

    func testApplyRejectsSymlinkedCodexDirectoryOutsideProject() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"])
        let externalCodex = tmpHome.appendingPathComponent("external-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: externalCodex, withIntermediateDirectories: true)
        let codexDir = project.rootURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: project.rootURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: codexDir, withDestinationURL: externalCodex)
        let configURL = codexDir.appendingPathComponent("config.toml")

        XCTAssertThrowsError(try CodexProjectionMaterializer().apply(CodexProjectAdapter().plans(for: project))) { error in
            XCTAssertEqual(error as? CodexProjectionMaterializerError, .destinationEscapesProject(configURL))
        }
    }

    func testApplyRejectsExistingUserSkillDirectory() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])
        let destination = project.rootURL.appendingPathComponent(".agents/skills/dev-toolkit-code-review", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "user".write(to: destination.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try CodexProjectionMaterializer().apply(CodexProjectAdapter().plans(for: project))) { error in
            XCTAssertEqual(error as? CodexProjectionMaterializerError, .unownedDestination(destination))
        }
    }

    func testApplyRejectsSymlinkedSkillsDirectoryOutsideProject() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])
        let agentsDir = project.rootURL.appendingPathComponent(".agents", isDirectory: true)
        let skillsDir = agentsDir.appendingPathComponent("skills", isDirectory: true)
        let externalSkills = tmpHome.appendingPathComponent("external-generated-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skillsDir, withDestinationURL: externalSkills)
        let destination = skillsDir.appendingPathComponent("dev-toolkit-code-review", isDirectory: true)

        XCTAssertThrowsError(try CodexProjectionMaterializer().apply(CodexProjectAdapter().plans(for: project))) { error in
            XCTAssertEqual(error as? CodexProjectionMaterializerError, .destinationEscapesProject(destination))
        }
    }

    func testApplyEscapesTomlControlCharacters() throws {
        try writePlugin(id: "dev-toolkit", capabilities: ["mcp"], serverName: "custom", commandJSON: #""uvx", "args": ["line\\nbreak"]"#)

        let plans = try CodexProjectAdapter().plans(for: project)
        try CodexProjectionMaterializer().apply(plans)

        let config = try String(contentsOf: project.rootURL.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("args = [\"line\\\\nbreak\"]"))
    }

    private func writePlugin(
        id: String,
        capabilities: [String],
        mcpRefs: [String]? = nil,
        skills: [String] = [],
        enginesJSON: String = #"{ "codex": { "enabled": true, "projection": "skills-and-mcp-files" } }"#,
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
