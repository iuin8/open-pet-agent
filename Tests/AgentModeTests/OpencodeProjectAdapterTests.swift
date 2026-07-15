import XCTest
@testable import AgentMode

final class OpencodeProjectAdapterTests: XCTestCase {
    private var tmpHome: URL!
    private var project: AgentProject!

    override func setUp() {
        super.setUp()
        tmpHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpencodeProjectAdapterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
        ProjectConfig.homeDirectoryOverride = tmpHome
        project = AgentProject(id: "p", name: "P", rootURL: tmpHome.appendingPathComponent("repo", isDirectory: true), isExternal: true, createdAt: Date(timeIntervalSince1970: 0))
    }

    override func tearDown() {
        ProjectConfig.homeDirectoryOverride = nil
        if let tmpHome { try? FileManager.default.removeItem(at: tmpHome) }
        super.tearDown()
    }

    func testLoadMCPServersReadsEnabledPluginMCP() throws {
        try writePlugin(id: "dev-toolkit", enabled: true)
        let servers = try OpencodeProjectAdapter().loadMCPServers(for: project)
        XCTAssertEqual(servers.count, 1)
        let command = servers[0].objectValue?["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(command, ["npx", "-y", "@modelcontextprotocol/server-filesystem"])
    }

    func testLoadMCPServersAcceptsLowercaseOpencodePolicy() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, enginesJSON: #"{ "opencode": { "enabled": true, "projection": "plugin-dir" } }"#)
        let servers = try OpencodeProjectAdapter().loadMCPServers(for: project)
        XCTAssertEqual(servers.count, 1)
    }

    func testLoadMCPServersSkipsDisabledPlugin() throws {
        try writePlugin(id: "dev-toolkit", enabled: false)
        let servers = try OpencodeProjectAdapter().loadMCPServers(for: project)
        XCTAssertEqual(servers.count, 0)
    }

    func testLoadMCPServersSkipsPluginWithoutOpencodePolicy() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, enginesJSON: "{}")
        let servers = try OpencodeProjectAdapter().loadMCPServers(for: project)
        XCTAssertEqual(servers.count, 0)
    }

    func testLoadMCPServersSkipsDisabledOpencodePolicy() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, enginesJSON: #"{ "openCode": { "enabled": true, "projection": "disabled" } }"#)
        let servers = try OpencodeProjectAdapter().loadMCPServers(for: project)
        XCTAssertEqual(servers.count, 0)
    }

    func testLoadMCPServersThrowsOnDuplicateServerNames() throws {
        try writePlugin(id: "first", enabled: true)
        try writePlugin(id: "second", enabled: true)
        XCTAssertThrowsError(try OpencodeProjectAdapter().loadMCPServers(for: project)) { error in
            XCTAssertTrue(String(describing: error).contains("filesystem"))
        }
    }

    func testLoadMCPServersRejectsMCPRefOutsideMCPDirectory() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, mcpRefs: ["mcp/../outside.json#filesystem"])
        let pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
        try mcpServersJSON.data(using: .utf8)!.write(to: pluginRoot.appendingPathComponent("outside.json"), options: .atomic)

        XCTAssertThrowsError(try OpencodeProjectAdapter().loadMCPServers(for: project)) { error in
            XCTAssertTrue(String(describing: error).contains("越界"))
        }
    }

    func testPlansIncludeNativeOpencodeConfigAndSkillTargets() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, capabilities: ["mcp", "skills"], skills: ["skills/code-review"])

        let plans = try OpencodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].engineID, AgentEngineKind.openCode.rawValue)
        XCTAssertTrue(plans[0].operations.contains { operation in
            if case let .writeFile(contents, destination) = operation {
                return destination.path == project.rootURL.appendingPathComponent("opencode.json").path
                    && contents.contains("\"mcp\"")
                    && contents.contains("\"filesystem\"")
            }
            return false
        })
        XCTAssertTrue(plans[0].operations.contains { operation in
            if case let .copyDirectory(source, destination) = operation {
                return source.path.hasSuffix("skills/code-review")
                    && destination.path == project.rootURL.appendingPathComponent(".opencode/skills/dev-toolkit-code-review", isDirectory: true).path
            }
            return false
        })
        XCTAssertFalse(plans[0].operations.contains { operation in
            switch operation {
            case .writeFile(_, let destination), .copyDirectory(_, let destination), .symlinkDirectory(_, let destination), .removeGenerated(let destination):
                return destination.path.contains(".materialized/openCode")
            }
        })
    }

    func testPlansAcceptLowercaseOpencodePolicy() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, enginesJSON: #"{ "opencode": { "enabled": true, "projection": "plugin-dir" } }"#)

        let plans = try OpencodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
    }

    func testPlansSkipDisabledOrMissingPolicy() throws {
        try writePlugin(id: "disabled", enabled: true, enginesJSON: #"{ "openCode": { "enabled": true, "projection": "disabled" } }"#)
        try writePlugin(id: "missing", enabled: true, enginesJSON: "{}")

        let plans = try OpencodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans, [])
    }

    func testPlansAcceptSkillsAndMCPFilesPolicy() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, enginesJSON: #"{ "openCode": { "enabled": true, "projection": "skills-and-mcp-files" } }"#)

        let plans = try OpencodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertFalse(plans[0].operations.isEmpty)
    }

    func testPlansIncludeSkillCopyAndWarningWhenMCPServerMissing() throws {
        try writePlugin(
            id: "dev-toolkit",
            enabled: true,
            capabilities: ["mcp", "skills"],
            mcpRefs: ["mcp/servers.json#missing"],
            skills: ["skills/code-review"]
        )

        let plans = try OpencodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(plans[0].operations.contains { operation in
            if case let .copyDirectory(source, destination) = operation {
                return source.path.hasSuffix("skills/code-review")
                    && destination.path == project.rootURL.appendingPathComponent(".opencode/skills/dev-toolkit-code-review", isDirectory: true).path
            }
            return false
        })
        XCTAssertFalse(plans[0].operations.contains { operation in
            if case .writeFile = operation { return true }
            return false
        })
        XCTAssertTrue(plans[0].diagnostics.contains {
            $0.severity == .warning && $0.message.contains("找不到 MCP server: missing")
        })
    }

    func testPlansRejectMalformedMCPFile() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, capabilities: ["mcp", "skills"], skills: ["skills/code-review"])
        let pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
        try Data("not json".utf8).write(to: pluginRoot.appendingPathComponent("mcp/servers.json"), options: .atomic)

        XCTAssertThrowsError(try OpencodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? OpencodeProjectAdapterError, .invalidMCPServer("mcp/servers.json#filesystem"))
        }
    }

    func testPlansRejectSymlinkedMCPRootOutsidePlugin() throws {
        try writePlugin(id: "dev-toolkit", enabled: true)
        let pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
        try FileManager.default.removeItem(at: pluginRoot.appendingPathComponent("mcp", isDirectory: true))
        let externalMCP = tmpHome.appendingPathComponent("external-mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: externalMCP, withIntermediateDirectories: true)
        try mcpServersJSON.data(using: .utf8)!.write(to: externalMCP.appendingPathComponent("servers.json"), options: .atomic)
        try FileManager.default.createSymbolicLink(at: pluginRoot.appendingPathComponent("mcp", isDirectory: true), withDestinationURL: externalMCP)

        XCTAssertThrowsError(try OpencodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? OpencodeProjectAdapterError, .mcpRefEscapesPlugin("mcp/servers.json#filesystem"))
        }
    }

    func testPlansRejectMissingSkillDirectory() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, capabilities: ["skills"], mcpRefs: [], skills: ["skills/missing"])

        XCTAssertThrowsError(try OpencodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? OpencodeProjectAdapterError, .missingSkill("skills/missing"))
        }
    }

    func testPlansRejectSkillRefOutsideSkillsDirectory() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, capabilities: ["skills"], mcpRefs: [], skills: ["skills/../outside"])
        let pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
        try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("outside", isDirectory: true), withIntermediateDirectories: true)

        XCTAssertThrowsError(try OpencodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? OpencodeProjectAdapterError, .skillRefEscapesPlugin("skills/../outside"))
        }
    }

    func testPlansRejectSymlinkedSkillsRootOutsidePlugin() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, capabilities: ["skills"], mcpRefs: [], skills: ["skills/code-review"])
        let pluginRoot = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
        try FileManager.default.removeItem(at: pluginRoot.appendingPathComponent("skills", isDirectory: true))
        let externalSkills = tmpHome.appendingPathComponent("external-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: externalSkills.appendingPathComponent("code-review", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pluginRoot.appendingPathComponent("skills", isDirectory: true), withDestinationURL: externalSkills)

        XCTAssertThrowsError(try OpencodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? OpencodeProjectAdapterError, .skillRefEscapesPlugin("skills/code-review"))
        }
    }

    private func writePlugin(
        id: String,
        enabled: Bool,
        capabilities: [String] = ["mcp"],
        mcpRefs: [String] = ["mcp/servers.json#filesystem"],
        skills: [String] = [],
        enginesJSON: String = #"{ "openCode": { "enabled": true, "projection": "plugin-dir" } }"#
    ) throws {
        let dir = ProjectConfig.pluginDirectory(for: project, pluginID: id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("mcp", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("skills/code-review", isDirectory: true), withIntermediateDirectories: true)
        try "---\nname: code-review\ndescription: Review code\n---\n".write(to: dir.appendingPathComponent("skills/code-review/SKILL.md"), atomically: true, encoding: .utf8)
        let capabilityJSON = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        let refsJSON = mcpRefs.map { "\"\($0)\"" }.joined(separator: ", ")
        let skillsJSON = skills.map { "\"\($0)\"" }.joined(separator: ", ")
        try """
        { "schemaVersion": 1, "id": "\(id)", "name": "Dev", "enabled": \(enabled), "capabilities": [\(capabilityJSON)], "mcp": [\(refsJSON)], "skills": [\(skillsJSON)], "engines": \(enginesJSON) }
        """.data(using: .utf8)!.write(to: dir.appendingPathComponent("plugin.json"), options: .atomic)
        try mcpServersJSON.data(using: .utf8)!.write(to: dir.appendingPathComponent("mcp/servers.json"), options: .atomic)
    }

    private var mcpServersJSON: String {
        """
        {
          "mcpServers": {
            "filesystem": { "type": "local", "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem"], "enabled": true }
          }
        }
        """
    }
}
