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
    public var sourceMetadata: ProjectPluginSourceMetadata = .manual
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
    public var body: String?
    public var bodyPreview: String?
    public var targets: [CapabilityTarget]
    public var diagnostics: [ProjectConfigDiagnostic]
}

public struct CapabilityMCPServer: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var fileRef: String
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

public struct CapabilityAuditState: Sendable, Equatable, Codable {
    public struct GeneratedTarget: Sendable, Equatable, Codable {
        public let engineID: String
        public let pluginID: String
        public let path: String
        public let hash: String
        public let recordedAtDescription: String

        public init(
            engineID: String,
            pluginID: String,
            path: String,
            hash: String,
            recordedAtDescription: String
        ) {
            self.engineID = engineID
            self.pluginID = pluginID
            self.path = path
            self.hash = hash
            self.recordedAtDescription = recordedAtDescription
        }
    }

    public struct Backup: Sendable, Equatable, Codable {
        public let engineID: String
        public let pluginID: String
        public let targetPath: String
        public let backupPath: String
        public let recordedAtDescription: String
        public let batchID: String?

        public init(
            engineID: String,
            pluginID: String,
            targetPath: String,
            backupPath: String,
            recordedAtDescription: String,
            batchID: String? = nil
        ) {
            self.engineID = engineID
            self.pluginID = pluginID
            self.targetPath = targetPath
            self.backupPath = backupPath
            self.recordedAtDescription = recordedAtDescription
            self.batchID = batchID
        }
    }

    public let lastValidationDescription: String?
    public let lastSyncDescription: String?
    public let generatedTargets: [GeneratedTarget]
    public let backups: [Backup]
    public let acknowledgedDiagnostics: Set<String>

    public init(
        lastValidationDescription: String? = nil,
        lastSyncDescription: String? = nil,
        generatedTargets: [GeneratedTarget] = [],
        backups: [Backup] = [],
        acknowledgedDiagnostics: Set<String> = []
    ) {
        self.lastValidationDescription = lastValidationDescription
        self.lastSyncDescription = lastSyncDescription
        self.generatedTargets = generatedTargets
        self.backups = backups
        self.acknowledgedDiagnostics = acknowledgedDiagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case lastValidationDescription
        case lastSyncDescription
        case generatedTargets
        case backups
        case acknowledgedDiagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.lastValidationDescription = try container.decodeIfPresent(String.self, forKey: .lastValidationDescription)
        self.lastSyncDescription = try container.decodeIfPresent(String.self, forKey: .lastSyncDescription)
        self.generatedTargets = try container.decodeIfPresent([GeneratedTarget].self, forKey: .generatedTargets) ?? []
        self.backups = try container.decodeIfPresent([Backup].self, forKey: .backups) ?? []
        self.acknowledgedDiagnostics = try container.decodeIfPresent(Set<String>.self, forKey: .acknowledgedDiagnostics) ?? []
    }
}

public struct CapabilitySourceConfirmation: Sendable, Equatable, Codable {
    public let pluginID: String
    public let source: ProjectPluginSourceMetadata
    public let contentHash: String
    public let confirmedAtDescription: String
    public let expiresAtDescription: String?

    public init(
        pluginID: String,
        source: ProjectPluginSourceMetadata,
        contentHash: String,
        confirmedAtDescription: String,
        expiresAtDescription: String? = nil
    ) {
        self.pluginID = pluginID
        self.source = source
        self.contentHash = contentHash
        self.confirmedAtDescription = confirmedAtDescription
        self.expiresAtDescription = expiresAtDescription
    }

    public func isActive(at date: Date = Date()) -> Bool {
        guard let expiresAtDescription else { return true }
        guard let expiresAt = Self.isoDate(expiresAtDescription) else { return false }
        return date < expiresAt
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

public struct CapabilitySourceConfirmationState: Sendable, Equatable, Codable {
    public let confirmations: [CapabilitySourceConfirmation]

    public init(confirmations: [CapabilitySourceConfirmation] = []) {
        self.confirmations = confirmations
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
            sourceMetadata: descriptor.sourceMetadata,
            skills: descriptor.skills.map { buildSkill($0, plugin: descriptor) },
            mcpServers: descriptor.mcp.map { buildMCP($0, plugin: descriptor) },
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
            body: body,
            bodyPreview: body.map { String($0.prefix(240)) },
            targets: targets(for: plugin),
            diagnostics: []
        )
    }

    private func buildMCP(_ ref: String, plugin: ProjectPluginDescriptor) -> CapabilityMCPServer {
        let parts = ref.split(separator: "#", maxSplits: 1).map(String.init)
        let fileRef = parts.first ?? ref
        let fallbackName = parts.count == 2 ? parts[1] : URL(fileURLWithPath: ref).lastPathComponent
        do {
            let resolved = try ProjectCapabilityMCPResolver.resolve(ref, plugin: plugin)
            let object = resolved.value.objectValue ?? [:]
            return CapabilityMCPServer(
                id: "\(plugin.id):\(resolved.name)",
                name: resolved.name,
                fileRef: fileRef,
                transport: Self.transport(for: object),
                command: ProjectCapabilityMCPResolver.commandParts(for: resolved.value) ?? [],
                url: object["url"]?.stringValue,
                env: Self.stringMap(object["env"]),
                cwd: object["cwd"]?.stringValue,
                rawJSON: Self.rawJSON(resolved.value),
                targets: targets(for: plugin),
                diagnostics: ProjectCapabilityMCPHealth.diagnostics(name: resolved.name, value: resolved.value, pluginRoot: plugin.rootURL)
            )
        } catch let error as ProjectCapabilityValidationError {
            return unresolvedMCP(
                ref: ref,
                fileRef: fileRef,
                name: fallbackName,
                plugin: plugin,
                diagnostic: mcpDiagnostic(for: error.message, path: plugin.rootURL.path)
            )
        } catch {
            return unresolvedMCP(
                ref: ref,
                fileRef: fileRef,
                name: fallbackName,
                plugin: plugin,
                diagnostic: .error("Malformed MCP reference: \(ref)", path: plugin.rootURL.path)
            )
        }
    }

    private func unresolvedMCP(
        ref: String,
        fileRef: String,
        name: String,
        plugin: ProjectPluginDescriptor,
        diagnostic: ProjectConfigDiagnostic
    ) -> CapabilityMCPServer {
        CapabilityMCPServer(
            id: "\(plugin.id):\(ref)",
            name: name,
            fileRef: fileRef,
            transport: .stdio,
            command: [],
            url: nil,
            env: [:],
            cwd: nil,
            rawJSON: "{}",
            targets: targets(for: plugin),
            diagnostics: [diagnostic]
        )
    }

    private func mcpDiagnostic(for message: String, path: String?) -> ProjectConfigDiagnostic {
        let isRecoverableInputProblem = message.hasPrefix("Missing MCP server:")
            || message.hasPrefix("Missing MCP server file:")
        return ProjectConfigDiagnostic(
            severity: isRecoverableInputProblem ? .warning : .error,
            message: message,
            path: path
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

    private static func rawJSON(_ value: ACPJSON) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
