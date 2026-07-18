import Foundation

public struct ClaudeCodeProjectAdapter: Sendable {
    private static let engineIDs = [AgentEngineKind.claudeCode.rawValue, "claude-code", "claude"]
    private static let planID = "claude-code"

    public init() {}

    public func plans(for project: AgentProject) throws -> [ProjectionPlan] {
        let catalog = ProjectPluginCatalog()
        let plugins = try catalog.listPlugins(for: project)
        var operations: [ProjectionOperation] = []
        var diagnostics: [ProjectConfigDiagnostic] = []
        var mcpServers: [(name: String, value: ACPJSON)] = []
        var seenMCPServers = Set<String>()

        for plugin in plugins where supportsClaudeCodeProjection(plugin) {
            diagnostics.append(contentsOf: catalog.validate(plugin))

            if plugin.capabilities.contains(.mcp) {
                for ref in plugin.mcp {
                    do {
                        let (name, value) = try resolveMCPRef(ref, plugin: plugin)
                        // Claude Code has no per-server enabled switch; a disabled
                        // server is excluded rather than projected as active.
                        guard ProjectCapabilityMCPResolver.isEnabled(value) else { continue }
                        guard seenMCPServers.insert(name).inserted else {
                            throw ClaudeCodeProjectAdapterError.duplicateMCPServer(name)
                        }
                        mcpServers.append((name: name, value: value))
                    } catch let error as ClaudeCodeProjectAdapterError {
                        guard error.isRecoverableMCPConfigurationError else { throw error }
                        diagnostics.append(ProjectConfigDiagnostic(
                            severity: error.diagnosticSeverity,
                            message: error.description,
                            path: plugin.rootURL.path
                        ))
                    }
                }
            }

            if plugin.capabilities.contains(.skills) {
                for ref in plugin.skills {
                    let (source, destination) = try resolveSkillRef(ref, plugin: plugin, project: project)
                    operations.append(.copyDirectory(source: source, destination: destination))
                }
            }
        }

        if !mcpServers.isEmpty {
            operations.insert(.writeFile(
                contents: try renderMCPConfig(mcpServers),
                destination: project.rootURL.appendingPathComponent(".mcp.json", isDirectory: false)
            ), at: 0)
        }

        guard !operations.isEmpty || !diagnostics.isEmpty else { return [] }
        return [ProjectionPlan(
            projectID: project.id,
            engineID: AgentEngineKind.claudeCode.rawValue,
            pluginID: Self.planID,
            operations: operations,
            diagnostics: diagnostics
        )]
    }

    private func supportsClaudeCodeProjection(_ plugin: ProjectPluginDescriptor) -> Bool {
        guard plugin.enabled else { return false }
        for engineID in Self.engineIDs {
            if let policy = plugin.enginePolicies[engineID] { return policy != .disabled }
        }
        return false
    }

    private func resolveMCPRef(_ ref: String, plugin: ProjectPluginDescriptor) throws -> (String, ACPJSON) {
        do {
            return try ProjectProjectionMCPResolver.resolve(ref, plugin: plugin)
        } catch let error as ProjectProjectionMCPResolutionError {
            throw ClaudeCodeProjectAdapterError(error)
        }
    }

    private func resolveSkillRef(_ ref: String, plugin: ProjectPluginDescriptor, project: AgentProject) throws -> (URL, URL) {
        let rawSource = plugin.rootURL.appendingPathComponent(ref, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rawSource.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ClaudeCodeProjectAdapterError.missingSkill(ref)
        }

        let lexicalRoot = plugin.rootURL
            .appendingPathComponent("skills", isDirectory: true)
            .standardizedFileURL
        let lexicalSource = rawSource.standardizedFileURL
        guard ProjectionTrust.isPath(lexicalSource, inside: lexicalRoot) else {
            throw ClaudeCodeProjectAdapterError.skillRefEscapesPlugin(ref)
        }

        let source = try containedURL(
            ref: ref,
            subdirectory: "skills",
            plugin: plugin,
            isDirectory: true,
            escape: { ClaudeCodeProjectAdapterError.skillRefEscapesPlugin(ref) }
        )
        let skillName = source.lastPathComponent
        let destination = project.rootURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("\(plugin.id)-\(skillName)", isDirectory: true)
        return (source, destination)
    }

    private func renderMCPConfig(_ servers: [(name: String, value: ACPJSON)]) throws -> String {
        var object: [String: ACPJSON] = [:]
        for server in servers.sorted(by: { $0.name < $1.name }) {
            do {
                object[server.name] = try ClaudeCodeMCPServerProjection.serverJSON(name: server.name, value: server.value)
            } catch {
                throw ClaudeCodeProjectAdapterError.invalidMCPServer(server.name)
            }
        }
        let data = try JSONEncoder.openPetAgentPretty.encode(ACPJSON.object(["mcpServers": .object(object)]))
        return String(decoding: data, as: UTF8.self)
    }

    private func containedURL(
        ref: String,
        subdirectory: String,
        plugin: ProjectPluginDescriptor,
        isDirectory: Bool,
        escape: () -> ClaudeCodeProjectAdapterError
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

public enum ClaudeCodeProjectAdapterError: Error, Equatable, CustomStringConvertible {
    case invalidMCPRef(String)
    case unreadableMCPServer(String)
    case missingMCPServer(String)
    case invalidMCPServer(String)
    case duplicateMCPServer(String)
    case mcpRefEscapesPlugin(String)
    case skillRefEscapesPlugin(String)
    case missingSkill(String)

    init(_ error: ProjectProjectionMCPResolutionError) {
        switch error {
        case .invalidRef(let ref): self = .invalidMCPRef(ref)
        case .unreadableServer(let ref): self = .unreadableMCPServer(ref)
        case .malformedServerFile(let ref): self = .invalidMCPServer(ref)
        case .missingServer(let name): self = .missingMCPServer(name)
        case .invalidServer(let name): self = .invalidMCPServer(name)
        case .refEscapesPlugin(let ref): self = .mcpRefEscapesPlugin(ref)
        }
    }

    var isRecoverableMCPConfigurationError: Bool {
        switch self {
        case .unreadableMCPServer, .missingMCPServer:
            return true
        case .invalidMCPRef, .invalidMCPServer, .duplicateMCPServer, .mcpRefEscapesPlugin, .skillRefEscapesPlugin, .missingSkill:
            return false
        }
    }

    var diagnosticSeverity: ProjectConfigDiagnostic.Severity {
        switch self {
        case .unreadableMCPServer, .missingMCPServer:
            return .warning
        case .invalidMCPRef, .invalidMCPServer, .duplicateMCPServer, .mcpRefEscapesPlugin, .skillRefEscapesPlugin, .missingSkill:
            return .error
        }
    }

    public var description: String {
        switch self {
        case .invalidMCPRef(let ref): return "无效 Claude Code MCP 引用: \(ref)"
        case .unreadableMCPServer(let ref): return "无法读取 Claude Code MCP server 文件: \(ref)"
        case .missingMCPServer(let name): return "找不到 Claude Code MCP server: \(name)"
        case .invalidMCPServer(let name): return "无效 Claude Code MCP server: \(name)"
        case .duplicateMCPServer(let name): return "重复 Claude Code MCP server 投影: \(name)"
        case .mcpRefEscapesPlugin(let ref): return "Claude Code MCP 引用越界: \(ref)"
        case .skillRefEscapesPlugin(let ref): return "Claude Code skill 引用越界: \(ref)"
        case .missingSkill(let ref): return "找不到 Claude Code skill: \(ref)"
        }
    }
}

private extension JSONEncoder {
    static var openPetAgentPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
