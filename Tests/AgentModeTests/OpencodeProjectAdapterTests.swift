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

    func testPlansRenderLocalServerInOpencodeNativeFormat() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, serversFileJSON: """
        { "mcpServers": { "filesystem": { "type": "stdio", "command": "npx", "args": ["-y", "srv"], "env": { "LOG_LEVEL": "info" }, "cwd": "/tmp", "enabled": true } } }
        """)

        let server = try XCTUnwrap(mcpConfigServers()?["filesystem"]?.objectValue)
        XCTAssertEqual(server["type"]?.stringValue, "local")
        XCTAssertEqual(server["command"]?.arrayValue?.compactMap(\.stringValue), ["npx", "-y", "srv"])
        XCTAssertEqual(server["environment"]?.objectValue?["LOG_LEVEL"]?.stringValue, "info")
        XCTAssertEqual(server["enabled"], .bool(true))
        XCTAssertNil(server["env"])
        XCTAssertNil(server["args"])
        XCTAssertNil(server["cwd"])
    }

    func testPlansPreserveImportedNativeEnvironmentKey() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, serversFileJSON: """
        { "mcpServers": { "filesystem": { "type": "local", "command": ["npx", "-y", "srv"], "environment": { "API_KEY": "x" } } } }
        """)

        let server = try XCTUnwrap(mcpConfigServers()?["filesystem"]?.objectValue)
        XCTAssertEqual(server["command"]?.arrayValue?.compactMap(\.stringValue), ["npx", "-y", "srv"])
        XCTAssertEqual(server["environment"]?.objectValue?["API_KEY"]?.stringValue, "x")
        XCTAssertNil(server["env"])
    }

    func testPlansRenderRemoteServerInOpencodeNativeFormat() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, mcpRefs: ["mcp/servers.json#remote"], serversFileJSON: """
        { "mcpServers": { "remote": { "type": "http", "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer token" }, "enabled": false } } }
        """)

        let server = try XCTUnwrap(mcpConfigServers()?["remote"]?.objectValue)
        XCTAssertEqual(server["type"]?.stringValue, "remote")
        XCTAssertEqual(server["url"]?.stringValue, "https://example.com/mcp")
        XCTAssertEqual(server["headers"]?.objectValue?["Authorization"]?.stringValue, "Bearer token")
        // opencode has a per-server enabled switch, so disabled servers are
        // projected with enabled:false instead of being dropped (contrast with
        // the Claude Code projection, which must exclude them).
        XCTAssertEqual(server["enabled"], .bool(false))
        XCTAssertNil(server["command"])
    }

    func testPlansRejectRemoteServerWithoutURL() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, mcpRefs: ["mcp/servers.json#remote"], serversFileJSON: """
        { "mcpServers": { "remote": { "type": "http" } } }
        """)

        XCTAssertThrowsError(try OpencodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? OpencodeProjectAdapterError, .invalidMCPServer("remote"))
        }
    }

    func testPlansRejectWSTransportUnsupportedByOpencode() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, mcpRefs: ["mcp/servers.json#remote"], serversFileJSON: """
        { "mcpServers": { "remote": { "type": "ws", "url": "wss://example.com/mcp" } } }
        """)

        XCTAssertThrowsError(try OpencodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? OpencodeProjectAdapterError, .invalidMCPServer("remote"))
        }
    }

    func testPlansRejectNonStringEnvironmentValues() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, serversFileJSON: """
        { "mcpServers": { "filesystem": { "type": "local", "command": ["npx"], "env": { "RETRIES": 3 } } } }
        """)

        XCTAssertThrowsError(try OpencodeProjectAdapter().plans(for: project)) { error in
            XCTAssertEqual(error as? OpencodeProjectAdapterError, .invalidMCPServer("filesystem"))
        }
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
        enginesJSON: String = #"{ "openCode": { "enabled": true, "projection": "plugin-dir" } }"#,
        serversFileJSON: String? = nil
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
        try (serversFileJSON ?? mcpServersJSON).data(using: .utf8)!.write(to: dir.appendingPathComponent("mcp/servers.json"), options: .atomic)
    }

    /// Parses the rendered `opencode.json` writeFile operation and returns its `mcp` object.
    private func mcpConfigServers(file: StaticString = #filePath, line: UInt = #line) throws -> [String: ACPJSON]? {
        let plans = try OpencodeProjectAdapter().plans(for: project)
        let writes = plans.flatMap(\.operations).compactMap { operation -> String? in
            if case let .writeFile(contents, destination) = operation,
               destination.path == project.rootURL.appendingPathComponent("opencode.json").path {
                return contents
            }
            return nil
        }
        let contents = try XCTUnwrap(writes.first, "missing opencode.json writeFile operation", file: file, line: line)
        let config = try JSONDecoder().decode(ACPJSON.self, from: Data(contents.utf8))
        return config.objectValue?["mcp"]?.objectValue
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
