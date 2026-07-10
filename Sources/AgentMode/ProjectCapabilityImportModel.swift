import Foundation

public enum ProjectCapabilityImportKind: String, Sendable, Equatable {
    case skill
    case mcp
}

public enum ProjectCapabilityImportSourceKind: String, Sendable, Equatable {
    case claudeSkill
    case agentsSkill
    case claudeMCP
    case codexMCP
}

public struct ProjectCapabilityImportSource: Sendable, Equatable {
    public let kind: ProjectCapabilityImportSourceKind
    public let url: URL

    public init(kind: ProjectCapabilityImportSourceKind, url: URL) {
        self.kind = kind
        self.url = url
    }
}

public struct ProjectCapabilityImportFile: Sendable, Equatable {
    public let relativePath: String
    public let contents: Data

    public init(relativePath: String, contents: Data) {
        self.relativePath = relativePath
        self.contents = contents
    }
}

public struct ProjectCapabilityImportCandidate:
    Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: ProjectCapabilityImportKind
    public let name: String
    public var sources: [ProjectCapabilityImportSource]
    public let skillBody: String?
    public let skillFiles: [ProjectCapabilityImportFile]
    public let mcpValue: ACPJSON?
    public var diagnostics: [ProjectConfigDiagnostic]

    public init(
        id: String,
        kind: ProjectCapabilityImportKind,
        name: String,
        sources: [ProjectCapabilityImportSource],
        skillBody: String? = nil,
        skillFiles: [ProjectCapabilityImportFile] = [],
        mcpValue: ACPJSON? = nil,
        diagnostics: [ProjectConfigDiagnostic] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.sources = sources
        self.skillBody = skillBody
        self.skillFiles = skillFiles
        self.mcpValue = mcpValue
        self.diagnostics = diagnostics
    }
}

public struct ProjectCapabilityImportScan: Sendable, Equatable {
    public var candidates: [ProjectCapabilityImportCandidate]
    public var diagnostics: [ProjectConfigDiagnostic]

    public init(
        candidates: [ProjectCapabilityImportCandidate] = [],
        diagnostics: [ProjectConfigDiagnostic] = []
    ) {
        self.candidates = candidates
        self.diagnostics = diagnostics
    }
}
