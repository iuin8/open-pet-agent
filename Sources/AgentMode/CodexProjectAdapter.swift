import Foundation

public struct CodexProjectAdapter: Sendable {
    private static let engineIDs = [AgentEngineKind.codex.rawValue, "codex"]
    private static let planID = "codex"

    public init() {}

    public func plans(for project: AgentProject) throws -> [ProjectionPlan] {
        let catalog = ProjectPluginCatalog()
        let plugins = try catalog.listPlugins(for: project)
        var operations: [ProjectionOperation] = []
        var diagnostics: [ProjectConfigDiagnostic] = []
        var mcpDescriptions: [String] = []
        var seenMCPServers = Set<String>()

        for plugin in plugins where supportsCodexProjection(plugin) {
            diagnostics.append(contentsOf: catalog.validate(plugin))

            if plugin.capabilities.contains(.mcp) {
                var serverNames: [String] = []
                for ref in plugin.mcp {
                    let name = try resolveMCPRef(ref, plugin: plugin)
                    guard seenMCPServers.insert(name).inserted else {
                        throw CodexProjectAdapterError.duplicateMCPServer(name)
                    }
                    serverNames.append(name)
                }
                if !serverNames.isEmpty {
                    mcpDescriptions.append("\(plugin.id): \(serverNames.sorted().joined(separator: ", "))")
                }
            }

            if plugin.capabilities.contains(.skills) {
                for ref in plugin.skills {
                    let (source, destination) = try resolveSkillRef(ref, plugin: plugin, project: project)
                    operations.append(.copyDirectory(source: source, destination: destination))
                }
            }
        }

        if !mcpDescriptions.isEmpty {
            operations.insert(.writeFile(
                sourceDescription: "Codex MCP servers: \(mcpDescriptions.joined(separator: "; "))",
                destination: project.rootURL.appendingPathComponent(".codex/config.toml", isDirectory: false)
            ), at: 0)
        }

        guard !operations.isEmpty || !diagnostics.isEmpty else { return [] }
        return [ProjectionPlan(
            projectID: project.id,
            engineID: AgentEngineKind.codex.rawValue,
            pluginID: Self.planID,
            operations: operations,
            diagnostics: diagnostics
        )]
    }

    private func supportsCodexProjection(_ plugin: ProjectPluginDescriptor) -> Bool {
        guard plugin.enabled else { return false }
        for engineID in Self.engineIDs {
            if let policy = plugin.enginePolicies[engineID] { return policy != .disabled }
        }
        return false
    }

    private func resolveMCPRef(_ ref: String, plugin: ProjectPluginDescriptor) throws -> String {
        let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw CodexProjectAdapterError.invalidMCPRef(ref) }
        let fileURL = try containedURL(
            ref: parts[0],
            subdirectory: "mcp",
            plugin: plugin,
            isDirectory: false,
            escape: { CodexProjectAdapterError.mcpRefEscapesPlugin(ref) }
        )

        let serverName = parts[1]
        let data = try Data(contentsOf: fileURL)
        guard let object = try JSONDecoder().decode(ACPJSON.self, from: data).objectValue,
              let servers = object["mcpServers"]?.objectValue,
              let server = servers[serverName] else {
            throw CodexProjectAdapterError.missingMCPServer(serverName)
        }
        guard server.objectValue != nil else {
            throw CodexProjectAdapterError.invalidMCPServer(serverName)
        }
        return serverName
    }

    private func resolveSkillRef(_ ref: String, plugin: ProjectPluginDescriptor, project: AgentProject) throws -> (URL, URL) {
        let rawSource = plugin.rootURL.appendingPathComponent(ref, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rawSource.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexProjectAdapterError.missingSkill(ref)
        }

        let lexicalRoot = plugin.rootURL
            .appendingPathComponent("skills", isDirectory: true)
            .standardizedFileURL
        let lexicalSource = rawSource.standardizedFileURL
        guard ProjectionTrust.isPath(lexicalSource, inside: lexicalRoot) else {
            throw CodexProjectAdapterError.skillRefEscapesPlugin(ref)
        }

        let source = try containedURL(
            ref: ref,
            subdirectory: "skills",
            plugin: plugin,
            isDirectory: true,
            escape: { CodexProjectAdapterError.skillRefEscapesPlugin(ref) }
        )
        let skillName = source.lastPathComponent
        let destination = project.rootURL
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("\(plugin.id)-\(skillName)", isDirectory: true)
        return (source, destination)
    }

    private func containedURL(
        ref: String,
        subdirectory: String,
        plugin: ProjectPluginDescriptor,
        isDirectory: Bool,
        escape: () -> CodexProjectAdapterError
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

public enum CodexProjectAdapterError: Error, Equatable, CustomStringConvertible {
    case invalidMCPRef(String)
    case missingMCPServer(String)
    case invalidMCPServer(String)
    case duplicateMCPServer(String)
    case mcpRefEscapesPlugin(String)
    case skillRefEscapesPlugin(String)
    case missingSkill(String)

    public var description: String {
        switch self {
        case .invalidMCPRef(let ref): return "无效 Codex MCP 引用: \(ref)"
        case .missingMCPServer(let name): return "找不到 Codex MCP server: \(name)"
        case .invalidMCPServer(let name): return "无效 Codex MCP server: \(name)"
        case .duplicateMCPServer(let name): return "重复 Codex MCP server 投影: \(name)"
        case .mcpRefEscapesPlugin(let ref): return "Codex MCP 引用越界: \(ref)"
        case .skillRefEscapesPlugin(let ref): return "Codex skill 引用越界: \(ref)"
        case .missingSkill(let ref): return "找不到 Codex skill: \(ref)"
        }
    }
}
