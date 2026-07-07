import Foundation

public struct OpencodeProjectAdapter: Sendable {
    private static let engineIDs = [AgentEngineKind.openCode.rawValue, "opencode"]

    public init() {}

    public func loadMCPServers(for project: AgentProject) throws -> [ACPJSON] {
        let plugins = try ProjectPluginCatalog().listPlugins(for: project)
        var servers: [ACPJSON] = []
        var seenNames = Set<String>()

        for plugin in plugins where supportsOpencodeMCP(plugin) {
            for ref in plugin.mcp {
                let (name, value) = try resolveMCPRef(ref, plugin: plugin)
                guard seenNames.insert(name).inserted else {
                    throw OpencodeProjectAdapterError.duplicateMCPServer(name)
                }
                servers.append(value)
            }
        }
        return servers
    }

    private func supportsOpencodeMCP(_ plugin: ProjectPluginDescriptor) -> Bool {
        guard plugin.enabled, plugin.capabilities.contains(.mcp) else { return false }
        for engineID in Self.engineIDs {
            if let policy = plugin.enginePolicies[engineID] { return policy != .disabled }
        }
        return false
    }

    private func resolveMCPRef(_ ref: String, plugin: ProjectPluginDescriptor) throws -> (String, ACPJSON) {
        let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw OpencodeProjectAdapterError.invalidMCPRef(ref) }
        let fileURL = plugin.rootURL
            .appendingPathComponent(parts[0], isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let mcpRoot = plugin.rootURL
            .appendingPathComponent("mcp", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(fileURL, inside: mcpRoot) else {
            throw OpencodeProjectAdapterError.mcpRefEscapesPlugin(ref)
        }
        let serverName = parts[1]
        let data = try Data(contentsOf: fileURL)
        guard let object = try JSONDecoder().decode(ACPJSON.self, from: data).objectValue,
              let servers = object["mcpServers"]?.objectValue,
              let server = servers[serverName] else {
            throw OpencodeProjectAdapterError.missingMCPServer(serverName)
        }
        guard server.objectValue != nil else {
            throw OpencodeProjectAdapterError.invalidMCPServer(serverName)
        }
        return (serverName, server)
    }
}

public enum OpencodeProjectAdapterError: Error, Equatable, CustomStringConvertible {
    case invalidMCPRef(String)
    case missingMCPServer(String)
    case invalidMCPServer(String)
    case duplicateMCPServer(String)
    case mcpRefEscapesPlugin(String)

    public var description: String {
        switch self {
        case .invalidMCPRef(let ref): return "无效 MCP 引用: \(ref)"
        case .missingMCPServer(let name): return "找不到 MCP server: \(name)"
        case .invalidMCPServer(let name): return "无效 MCP server: \(name)"
        case .duplicateMCPServer(let name): return "重复 MCP server 投影: \(name)"
        case .mcpRefEscapesPlugin(let ref): return "MCP 引用越界: \(ref)"
        }
    }
}
