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
        var mcpServers: [(name: String, value: ACPJSON)] = []
        var seenMCPServers = Set<String>()

        for plugin in plugins where supportsCodexProjection(plugin) {
            diagnostics.append(contentsOf: catalog.validate(plugin))

            if plugin.capabilities.contains(.mcp) {
                for ref in plugin.mcp {
                    do {
                        let (name, value) = try resolveMCPRef(ref, plugin: plugin)
                        try validateMCPServer(value, name: name)
                        guard seenMCPServers.insert(name).inserted else {
                            throw CodexProjectAdapterError.duplicateMCPServer(name)
                        }
                        mcpServers.append((name: name, value: value))
                    } catch let error as CodexProjectAdapterError {
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
                contents: try renderCodexConfig(mcpServers),
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

    private func resolveMCPRef(_ ref: String, plugin: ProjectPluginDescriptor) throws -> (String, ACPJSON) {
        do {
            return try ProjectProjectionMCPResolver.resolve(ref, plugin: plugin)
        } catch let error as ProjectProjectionMCPResolutionError {
            throw CodexProjectAdapterError(error)
        }
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

    private func validateMCPServer(_ server: ACPJSON, name: String) throws {
        guard let object = server.objectValue else {
            throw CodexProjectAdapterError.invalidMCPServer(name)
        }
        _ = try commandParts(for: object, serverName: name)
    }

    private func renderCodexConfig(_ servers: [(name: String, value: ACPJSON)]) throws -> String {
        var lines: [String] = []
        for server in servers.sorted(by: { $0.name < $1.name }) {
            guard let object = server.value.objectValue else {
                throw CodexProjectAdapterError.invalidMCPServer(server.name)
            }
            let command = try commandParts(for: object, serverName: server.name)
            lines.append("[mcp_servers.\(tomlKey(server.name))]")
            lines.append("command = \"\(tomlString(command[0]))\"")
            if command.count > 1 {
                let args = command.dropFirst().map { "\"\(tomlString($0))\"" }.joined(separator: ", ")
                lines.append("args = [\(args)]")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func commandParts(for object: [String: ACPJSON], serverName: String) throws -> [String] {
        var parts: [String]
        if let command = object["command"]?.stringValue, !command.isEmpty {
            parts = [command]
        } else if let command = object["command"]?.arrayValue {
            parts = command.compactMap(\.stringValue)
            guard parts.count == command.count, !parts.isEmpty else {
                throw CodexProjectAdapterError.invalidMCPServer(serverName)
            }
        } else {
            throw CodexProjectAdapterError.invalidMCPServer(serverName)
        }

        if let args = object["args"]?.arrayValue {
            let values = args.compactMap(\.stringValue)
            guard values.count == args.count else {
                throw CodexProjectAdapterError.invalidMCPServer(serverName)
            }
            parts.append(contentsOf: values)
        }
        return parts
    }

    private func tomlKey(_ key: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        if key.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return key }
        return "\"\(tomlString(key))\""
    }

    private func tomlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
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
        case .invalidMCPRef(let ref): return "无效 Codex MCP 引用: \(ref)"
        case .unreadableMCPServer(let ref): return "无法读取 Codex MCP server 文件: \(ref)"
        case .missingMCPServer(let name): return "找不到 Codex MCP server: \(name)"
        case .invalidMCPServer(let name): return "无效 Codex MCP server: \(name)"
        case .duplicateMCPServer(let name): return "重复 Codex MCP server 投影: \(name)"
        case .mcpRefEscapesPlugin(let ref): return "Codex MCP 引用越界: \(ref)"
        case .skillRefEscapesPlugin(let ref): return "Codex skill 引用越界: \(ref)"
        case .missingSkill(let ref): return "找不到 Codex skill: \(ref)"
        }
    }
}
