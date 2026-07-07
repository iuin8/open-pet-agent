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
