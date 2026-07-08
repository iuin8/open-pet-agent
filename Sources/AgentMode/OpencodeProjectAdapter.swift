import Foundation

public struct OpencodeProjectAdapter: Sendable {
    private static let engineIDs = [AgentEngineKind.openCode.rawValue, "opencode"]
    private static let planID = "opencode"

    public init() {}

    public func plans(for project: AgentProject) throws -> [ProjectionPlan] {
        let catalog = ProjectPluginCatalog()
        let plugins = try catalog.listPlugins(for: project)
        var operations: [ProjectionOperation] = []
        var diagnostics: [ProjectConfigDiagnostic] = []
        var seenMCPServers = Set<String>()

        for plugin in plugins where supportsOpencodeProjection(plugin) {
            diagnostics.append(contentsOf: catalog.validate(plugin))
            if plugin.capabilities.contains(.mcp) {
                try collectMCPServers(from: plugin, seenNames: &seenMCPServers).forEach { _ in }
            }
            operations.append(.copyDirectory(
                source: plugin.rootURL,
                destination: ProjectConfig.materializedPluginDirectory(
                    for: project,
                    engineID: AgentEngineKind.openCode.rawValue,
                    pluginID: plugin.id
                )
            ))
        }

        guard !operations.isEmpty || !diagnostics.isEmpty else { return [] }
        return [ProjectionPlan(
            projectID: project.id,
            engineID: AgentEngineKind.openCode.rawValue,
            pluginID: Self.planID,
            operations: operations,
            diagnostics: diagnostics
        )]
    }

    public func loadMCPServers(for project: AgentProject) throws -> [ACPJSON] {
        let plugins = try ProjectPluginCatalog().listPlugins(for: project)
        var seenNames = Set<String>()
        return try plugins
            .filter(supportsOpencodeMCP)
            .flatMap { try collectMCPServers(from: $0, seenNames: &seenNames) }
    }

    private func supportsOpencodeProjection(_ plugin: ProjectPluginDescriptor) -> Bool {
        guard plugin.enabled else { return false }
        for engineID in Self.engineIDs {
            if let policy = plugin.enginePolicies[engineID] { return policy == .pluginDir }
        }
        return false
    }

    private func supportsOpencodeMCP(_ plugin: ProjectPluginDescriptor) -> Bool {
        supportsOpencodeProjection(plugin) && plugin.capabilities.contains(.mcp)
    }

    private func collectMCPServers(from plugin: ProjectPluginDescriptor, seenNames: inout Set<String>) throws -> [ACPJSON] {
        try plugin.mcp.map { ref in
            let (name, value) = try resolveMCPRef(ref, plugin: plugin)
            guard seenNames.insert(name).inserted else {
                throw OpencodeProjectAdapterError.duplicateMCPServer(name)
            }
            return value
        }
    }

    private func resolveMCPRef(_ ref: String, plugin: ProjectPluginDescriptor) throws -> (String, ACPJSON) {
        let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw OpencodeProjectAdapterError.invalidMCPRef(ref) }
        let fileURL = try containedURL(
            ref: parts[0],
            subdirectory: "mcp",
            plugin: plugin,
            isDirectory: false,
            escape: { OpencodeProjectAdapterError.mcpRefEscapesPlugin(ref) }
        )
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

    private func containedURL(
        ref: String,
        subdirectory: String,
        plugin: ProjectPluginDescriptor,
        isDirectory: Bool,
        escape: () -> OpencodeProjectAdapterError
    ) throws -> URL {
        let pluginRoot = plugin.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let lexicalRoot = plugin.rootURL
            .appendingPathComponent(subdirectory, isDirectory: true)
            .standardizedFileURL
        let lexicalURL = plugin.rootURL
            .appendingPathComponent(ref, isDirectory: isDirectory)
            .standardizedFileURL
        guard ProjectionTrust.isPath(lexicalURL, inside: lexicalRoot) else { throw escape() }

        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(resolvedRoot, inside: pluginRoot) else { throw escape() }

        let resolvedURL = lexicalURL.resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(resolvedURL, inside: resolvedRoot) else { throw escape() }
        return resolvedURL
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
