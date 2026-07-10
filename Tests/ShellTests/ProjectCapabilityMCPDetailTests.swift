import Foundation
import Testing
@testable import AgentMode
@testable import Shell

@MainActor
@Suite("ProjectCapabilityMCPDetail")
struct ProjectCapabilityMCPDetailTests {
    @Test("basic 编辑：保存时保留 raw JSON 未知字段")
    func basicEditPreservesUnknownRawFields() throws {
        let original = mcpServer(rawJSON: """
        {
          "command" : "npx",
          "args" : ["old"],
          "enabled" : true,
          "headers" : {"X-Trace" : "keep"},
          "type" : "local"
        }
        """)
        var savedValue: ACPJSON?
        let detail = ProjectCapabilityMCPDetailState(
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/dev-toolkit/mcp/servers.json#filesystem",
            server: original,
            onSave: { value in
                savedValue = value
                var refreshed = original
                refreshed.command = ["uvx", "server", "--verbose"]
                refreshed.rawJSON = encoded(value)
                return refreshed
            }
        )
        detail.beginEditing()
        detail.draftCommand = "uvx"
        detail.draftArguments = "server\n--verbose"

        detail.save()

        let object = try #require(savedValue?.objectValue)
        #expect(object["command"] == .string("uvx"))
        #expect(object["args"] == .array([.string("server"), .string("--verbose")]))
        #expect(object["headers"] == .object(["X-Trace": .string("keep")]))
        #expect(detail.isEditing == false)
        #expect(detail.errorMessage == nil)
    }

    @Test("raw 编辑：切回 basic 后同步 transport、URL、env、cwd")
    func rawEditSynchronizesBasicFields() {
        let detail = ProjectCapabilityMCPDetailState(
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/dev-toolkit/mcp/servers.json#remote",
            server: mcpServer(),
            onSave: { _ in mcpServer() }
        )
        detail.beginEditing()
        detail.selectEditorMode(.raw)
        detail.draftRawJSON = """
        {
          "type": "sse",
          "url": "https://example.com/mcp",
          "env": {"TOKEN": "secret"},
          "cwd": "/tmp/work",
          "enabled": true
        }
        """

        detail.selectEditorMode(.basic)

        #expect(detail.editorMode == .basic)
        #expect(detail.draftTransport == .sse)
        #expect(detail.draftURL == "https://example.com/mcp")
        #expect(detail.draftEnvironment == "TOKEN=secret")
        #expect(detail.draftCWD == "/tmp/work")
        #expect(detail.errorMessage == nil)
    }

    @Test("raw 编辑：非法 JSON 保留 raw 模式和草稿")
    func invalidRawJSONKeepsDraft() {
        var saveCount = 0
        let detail = ProjectCapabilityMCPDetailState(
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/dev-toolkit/mcp/servers.json#filesystem",
            server: mcpServer(),
            onSave: { _ in saveCount += 1; return mcpServer() }
        )
        detail.beginEditing()
        detail.selectEditorMode(.raw)
        detail.draftRawJSON = "{ invalid"

        detail.save()

        #expect(saveCount == 0)
        #expect(detail.isEditing)
        #expect(detail.editorMode == .raw)
        #expect(detail.draftRawJSON == "{ invalid")
        #expect(detail.errorMessage != nil)
    }

    @Test("raw 编辑：stdio 配置不能混入 URL")
    func rawStdioRejectsURL() {
        var saveCount = 0
        let detail = ProjectCapabilityMCPDetailState(
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/dev-toolkit/mcp/servers.json#filesystem",
            server: mcpServer(),
            onSave: { _ in saveCount += 1; return mcpServer() }
        )
        detail.beginEditing()
        detail.selectEditorMode(.raw)
        detail.draftRawJSON = """
        { "type": "stdio", "command": "npx", "url": "https://example.com/mcp" }
        """

        detail.save()

        #expect(saveCount == 0)
        #expect(detail.isEditing)
        #expect(detail.errorMessage != nil)
    }

    @Test("basic 编辑：远程 transport 缺 URL 时不保存")
    func remoteTransportRequiresURL() {
        var saveCount = 0
        let detail = ProjectCapabilityMCPDetailState(
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/dev-toolkit/mcp/servers.json#remote",
            server: mcpServer(),
            onSave: { _ in saveCount += 1; return mcpServer() }
        )
        detail.beginEditing()
        detail.draftTransport = .http
        detail.draftURL = ""

        detail.save()

        #expect(saveCount == 0)
        #expect(detail.isEditing)
        #expect(detail.errorMessage?.contains("URL") == true)
    }

    @Test("basic 编辑：远程 transport 的 URL 必须包含 host")
    func remoteTransportRequiresURLHost() {
        var saveCount = 0
        let detail = ProjectCapabilityMCPDetailState(
            pluginID: "dev-toolkit",
            sourcePath: "/tmp/dev-toolkit/mcp/servers.json#remote",
            server: mcpServer(),
            onSave: { _ in saveCount += 1; return mcpServer() }
        )
        detail.beginEditing()
        detail.draftTransport = .http
        detail.draftURL = "https://"

        detail.save()

        #expect(saveCount == 0)
        #expect(detail.isEditing)
        #expect(detail.errorMessage?.contains("URL") == true)
    }

    private func mcpServer(rawJSON: String? = nil) -> CapabilityMCPServer {
        CapabilityMCPServer(
            id: "dev-toolkit:filesystem",
            name: "filesystem",
            fileRef: "mcp/servers.json",
            transport: .stdio,
            command: ["npx", "old"],
            url: nil,
            env: [:],
            cwd: nil,
            rawJSON: rawJSON ?? """
            {
              "command" : "npx",
              "args" : ["old"],
              "enabled" : true,
              "type" : "local"
            }
            """,
            targets: [.codex],
            diagnostics: []
        )
    }

    private func encoded(_ value: ACPJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try! encoder.encode(value), encoding: .utf8)!
    }
}
