import Foundation

public struct OpencodeProjectAdapter: Sendable {
    public init() {}

    public func loadMCPServers(for project: AgentProject) throws -> [ACPJSON] {
        let plugins = try ProjectPluginCatalog().listPlugins(for: project)
        var servers: [ACPJSON] = []
        var seenNames = Set<String>()

        for plugin in plugins where plugin.enabled && plugin.capabilities.contains(.mcp) {
            for ref in plugin.mcp {
                let resolved = try resolveMCPRef(ref, plugin: plugin)
                for (name, value) in resolved {
                    guard seenNames.insert(name).inserted else {
                        throw OpencodeProjectAdapterError.duplicateMCPServer(name)
                    }
                    servers.append(value)
                }
            }
        }
        return servers
    }

    private func resolveMCPRef(_ ref: String, plugin: ProjectPluginDescriptor) throws -> [(String, ACPJSON)] {
        let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw OpencodeProjectAdapterError.invalidMCPRef(ref) }
        let fileURL = plugin.rootURL.appendingPathComponent(parts[0], isDirectory: false)
        let serverName = parts[1]
        let data = try Data(contentsOf: fileURL)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = raw["mcpServers"] as? [String: Any],
              let server = object[serverName] else {
            throw OpencodeProjectAdapterError.missingMCPServer(serverName)
        }
        let jsonData = try JSONSerialization.data(withJSONObject: server)
        let jsonText = String(decoding: jsonData, as: UTF8.self)
        guard let parsed = ACPJSON.parse(jsonText) else { throw OpencodeProjectAdapterError.invalidMCPServer(serverName) }
        return [(serverName, parsed)]
    }
}

public enum OpencodeProjectAdapterError: Error, Equatable, CustomStringConvertible {
    case invalidMCPRef(String)
    case missingMCPServer(String)
    case invalidMCPServer(String)
    case duplicateMCPServer(String)

    public var description: String {
        switch self {
        case .invalidMCPRef(let ref): return "Invalid MCP reference: \(ref)"
        case .missingMCPServer(let name): return "Missing MCP server: \(name)"
        case .invalidMCPServer(let name): return "Invalid MCP server: \(name)"
        case .duplicateMCPServer(let name): return "Duplicate MCP server projection: \(name)"
        }
    }
}
