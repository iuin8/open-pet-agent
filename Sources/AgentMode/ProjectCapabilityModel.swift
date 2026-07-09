import Foundation

public struct ProjectCapabilityCatalogModel: Sendable, Equatable {
    public let projectID: String
    public let plugins: [CapabilityPlugin]
    public let diagnostics: [ProjectConfigDiagnostic]
    public let targets: [CapabilityTargetSummary]
    public let audit: CapabilityAuditState?

    public init(projectID: String, plugins: [CapabilityPlugin], diagnostics: [ProjectConfigDiagnostic] = [], targets: [CapabilityTargetSummary] = [], audit: CapabilityAuditState? = nil) {
        self.projectID = projectID
        self.plugins = plugins
        self.diagnostics = diagnostics
        self.targets = targets
        self.audit = audit
    }

    public static func build(for project: AgentProject, catalog: ProjectPluginCatalog = ProjectPluginCatalog()) throws -> ProjectCapabilityCatalogModel {
        let builder = ProjectCapabilityModelBuilder(project: project, catalog: catalog)
        return try builder.build()
    }
}

public struct CapabilityPlugin: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var version: String?
    public var enabled: Bool
    public var source: CapabilitySource
    public var skills: [CapabilitySkill]
    public var mcpServers: [CapabilityMCPServer]
    public var profiles: [CapabilityProfile]
    public var diagnostics: [ProjectConfigDiagnostic]
}

public struct CapabilitySkill: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var relativePath: String
    public var summary: String?
    public var bodyPreview: String?
    public var targets: [CapabilityTarget]
    public var diagnostics: [ProjectConfigDiagnostic]
}

public struct CapabilityMCPServer: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var transport: MCPTransport
    public var command: [String]
    public var url: String?
    public var env: [String: String]
    public var cwd: String?
    public var rawJSON: String?
    public var targets: [CapabilityTarget]
    public var diagnostics: [ProjectConfigDiagnostic]
}

public struct CapabilityProfile: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var pluginIDs: [String]
    public var skillIDs: [String]
    public var mcpServerIDs: [String]
    public var diagnostics: [ProjectConfigDiagnostic]
}

public enum CapabilitySource: Sendable, Equatable {
    case local(path: String)
}

public enum CapabilityTarget: String, Sendable, Equatable, CaseIterable {
    case codex
    case claudeCode = "claude-code"
    case opencode
}

public struct CapabilityTargetSummary: Sendable, Equatable {
    public let target: CapabilityTarget
    public let enabledCount: Int
    public let diagnostics: [ProjectConfigDiagnostic]

    public init(target: CapabilityTarget, enabledCount: Int, diagnostics: [ProjectConfigDiagnostic] = []) {
        self.target = target
        self.enabledCount = enabledCount
        self.diagnostics = diagnostics
    }
}

public struct CapabilityAuditState: Sendable, Equatable {
    public let lastValidationDescription: String?

    public init(lastValidationDescription: String? = nil) {
        self.lastValidationDescription = lastValidationDescription
    }
}

public enum MCPTransport: String, Sendable, Equatable {
    case stdio
    case http
    case sse
}

private struct ProjectCapabilityModelBuilder {
    let project: AgentProject
    let catalog: ProjectPluginCatalog

    func build() throws -> ProjectCapabilityCatalogModel {
        let plugins = try catalog.listPlugins(for: project).map(buildPlugin)
        let diagnostics = try ProjectCapabilityValidator().validate(project: project, catalog: catalog)
        return ProjectCapabilityCatalogModel(projectID: project.id, plugins: plugins, diagnostics: diagnostics)
    }

    private func buildPlugin(_ descriptor: ProjectPluginDescriptor) throws -> CapabilityPlugin {
        CapabilityPlugin(
            id: descriptor.id,
            name: descriptor.name,
            version: descriptor.version,
            enabled: descriptor.enabled,
            source: .local(path: descriptor.rootURL.path),
            skills: descriptor.skills.map { buildSkill($0, plugin: descriptor) },
            mcpServers: descriptor.mcp.compactMap { try? buildMCP($0, plugin: descriptor) },
            profiles: [],
            diagnostics: catalog.validate(descriptor)
        )
    }

    private func buildSkill(_ ref: String, plugin: ProjectPluginDescriptor) -> CapabilitySkill {
        let url = plugin.rootURL.appendingPathComponent(ref, isDirectory: true)
        let body = try? String(contentsOf: url.appendingPathComponent("SKILL.md"), encoding: .utf8)
        return CapabilitySkill(
            id: "\(plugin.id):\(ref)",
            name: url.lastPathComponent,
            relativePath: ref,
            summary: body.flatMap(Self.skillSummary),
            bodyPreview: body.map { String($0.prefix(240)) },
            targets: targets(for: plugin),
            diagnostics: []
        )
    }

    private func buildMCP(_ ref: String, plugin: ProjectPluginDescriptor) throws -> CapabilityMCPServer {
        let resolved = try ProjectCapabilityMCPResolver.resolve(ref, plugin: plugin)
        let object = resolved.value.objectValue ?? [:]
        return CapabilityMCPServer(
            id: "\(plugin.id):\(resolved.name)",
            name: resolved.name,
            transport: Self.transport(for: object),
            command: ProjectCapabilityMCPResolver.commandParts(for: resolved.value) ?? [],
            url: object["url"]?.stringValue,
            env: Self.stringMap(object["env"]),
            cwd: object["cwd"]?.stringValue,
            rawJSON: nil,
            targets: targets(for: plugin),
            diagnostics: []
        )
    }

    private func targets(for plugin: ProjectPluginDescriptor) -> [CapabilityTarget] {
        plugin.enginePolicies.compactMap { key, policy in
            guard policy != .disabled else { return nil }
            switch key {
            case AgentEngineKind.codex.rawValue, "codex": return .codex
            case AgentEngineKind.claudeCode.rawValue, "claude-code", "claude": return .claudeCode
            case AgentEngineKind.openCode.rawValue, "opencode": return .opencode
            default: return nil
            }
        }.sorted { $0.rawValue < $1.rawValue }
    }

    private static func skillSummary(_ body: String) -> String? {
        body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func transport(for object: [String: ACPJSON]) -> MCPTransport {
        switch object["type"]?.stringValue ?? object["transport"]?.stringValue {
        case "http": return .http
        case "sse": return .sse
        default: return object["url"]?.stringValue == nil ? .stdio : .http
        }
    }

    private static func stringMap(_ value: ACPJSON?) -> [String: String] {
        value?.objectValue?.compactMapValues(\.stringValue) ?? [:]
    }
}
