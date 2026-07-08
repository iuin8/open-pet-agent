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

    func testPlansCreateMaterializedPluginDirectoryForEnabledPlugin() throws {
        try writePlugin(id: "dev-toolkit", enabled: true)

        let plans = try OpencodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].engineID, AgentEngineKind.openCode.rawValue)
        XCTAssertTrue(plans[0].operations.contains {
            if case let .copyDirectory(source, destination) = $0 {
                let expectedSource = ProjectConfig.pluginDirectory(for: project, pluginID: "dev-toolkit")
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                return source.standardizedFileURL.resolvingSymlinksInPath().path == expectedSource
                    && destination.path == ProjectConfig.materializedPluginDirectory(
                        for: project,
                        engineID: AgentEngineKind.openCode.rawValue,
                        pluginID: "dev-toolkit"
                    ).path
            }
            return false
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

    func testPlansSkipSkillsAndMCPFilesPolicyUntilNativeTargetsAreVerified() throws {
        try writePlugin(id: "dev-toolkit", enabled: true, enginesJSON: #"{ "openCode": { "enabled": true, "projection": "skills-and-mcp-files" } }"#)

        let plans = try OpencodeProjectAdapter().plans(for: project)

        XCTAssertEqual(plans, [])
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

    private func writePlugin(
        id: String,
        enabled: Bool,
        mcpRefs: [String] = ["mcp/servers.json#filesystem"],
        enginesJSON: String = #"{ "openCode": { "enabled": true, "projection": "plugin-dir" } }"#
    ) throws {
        let dir = ProjectConfig.pluginDirectory(for: project, pluginID: id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("mcp", isDirectory: true), withIntermediateDirectories: true)
        let refsJSON = mcpRefs.map { "\"\($0)\"" }.joined(separator: ", ")
        try """
        { "schemaVersion": 1, "id": "\(id)", "name": "Dev", "enabled": \(enabled), "capabilities": ["mcp"], "mcp": [\(refsJSON)], "engines": \(enginesJSON) }
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
