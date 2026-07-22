import Foundation

public enum ProjectCapabilityInstallDraftKind: String, Sendable, Equatable {
    case skill
    case mcp
}

public struct ProjectCapabilityInstallDraft: Sendable, Equatable {
    public struct MCPServer: Sendable, Equatable {
        public let name: String
        public let value: ACPJSON

        public init(name: String, value: ACPJSON) {
            self.name = name
            self.value = value
        }
    }

    public let kind: ProjectCapabilityInstallDraftKind
    public let pluginID: String
    public let name: String
    public let description: String
    public let sourceMetadata: ProjectPluginSourceMetadata
    public let mcpServers: [MCPServer]
    public let skillFiles: [ProjectCapabilityImportFile]
    public let blockingReason: String?

    public init(
        kind: ProjectCapabilityInstallDraftKind,
        pluginID: String,
        name: String,
        description: String,
        sourceMetadata: ProjectPluginSourceMetadata,
        mcpServers: [MCPServer] = [],
        skillFiles: [ProjectCapabilityImportFile] = [],
        blockingReason: String? = nil
    ) {
        self.kind = kind
        self.pluginID = pluginID
        self.name = name
        self.description = description
        self.sourceMetadata = sourceMetadata
        self.mcpServers = mcpServers
        self.skillFiles = skillFiles
        self.blockingReason = blockingReason
    }

    public var canInstall: Bool { blockingReason == nil }
}
