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
        let encoded = try JSONEncoder().encode(servers[0])
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("filesystem"))
        XCTAssertTrue(text.contains("server-filesystem"))
    }

    func testLoadMCPServersSkipsDisabledPlugin() throws {
        try writePlugin(id: "dev-toolkit", enabled: false)
        let servers = try OpencodeProjectAdapter().loadMCPServers(for: project)
        XCTAssertEqual(servers.count, 0)
    }

    private func writePlugin(id: String, enabled: Bool) throws {
        let dir = ProjectConfig.pluginDirectory(for: project, pluginID: id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("mcp", isDirectory: true), withIntermediateDirectories: true)
        try """
        { "schemaVersion": 1, "id": "\(id)", "name": "Dev", "enabled": \(enabled), "capabilities": ["mcp"], "mcp": ["mcp/servers.json#filesystem"], "engines": { "opencode": { "enabled": true, "projection": "plugin-dir" } } }
        """.data(using: .utf8)!.write(to: dir.appendingPathComponent("plugin.json"), options: .atomic)
        try """
        {
          "mcpServers": {
            "filesystem": { "type": "local", "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem"], "enabled": true }
          }
        }
        """.data(using: .utf8)!.write(to: dir.appendingPathComponent("mcp/servers.json"), options: .atomic)
    }
}
