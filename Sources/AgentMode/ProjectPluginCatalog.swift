import Foundation

public enum ProjectPluginCapability: String, Codable, Sendable, CaseIterable {
    case mcp, skills, prompts, tools, agents
}

public enum ProjectionPolicy: String, Codable, Sendable, Equatable {
    case pluginDir = "plugin-dir"
    case skillsAndMCPFiles = "skills-and-mcp-files"
    case disabled
}

public enum ProjectPluginSourceKind: String, Codable, Sendable, Equatable {
    case manual
    case imported
    case local
    case git
    case marketplace
    case unknown
}

public struct ProjectPluginSourceMetadata: Codable, Sendable, Equatable {
    public let kind: ProjectPluginSourceKind
    public let url: String?
    public let revision: String?
    public let contentHash: String?
    public let installedAt: String?

    public static let manual = ProjectPluginSourceMetadata(kind: .manual)

    public init(
        kind: ProjectPluginSourceKind,
        url: String? = nil,
        revision: String? = nil,
        contentHash: String? = nil,
        installedAt: String? = nil
    ) {
        self.kind = kind
        self.url = url
        self.revision = revision
        self.contentHash = contentHash
        self.installedAt = installedAt
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
        case revision
        case contentHash
        case installedAt
    }

    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = ProjectPluginSourceMetadata(kind: .unknown)
            return
        }
        let rawKind = try? container.decodeIfPresent(String.self, forKey: .kind)
        self.kind = rawKind.flatMap(ProjectPluginSourceKind.init(rawValue:)) ?? .unknown
        self.url = try? container.decodeIfPresent(String.self, forKey: .url)
        self.revision = try? container.decodeIfPresent(String.self, forKey: .revision)
        self.contentHash = try? container.decodeIfPresent(String.self, forKey: .contentHash)
        self.installedAt = try? container.decodeIfPresent(String.self, forKey: .installedAt)
    }
}

public struct ProjectExecutableCapabilities: Codable, Sendable, Equatable {
    public var hooks: Bool
    public var bin: Bool
    public var opencodePlugin: Bool

    public init(hooks: Bool = false, bin: Bool = false, opencodePlugin: Bool = false) {
        self.hooks = hooks
        self.bin = bin
        self.opencodePlugin = opencodePlugin
    }
}

public struct ProjectPluginDescriptor: Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String?
    public let enabled: Bool
    public let capabilities: Set<ProjectPluginCapability>
    public let unknownCapabilities: [String]
    public let executableCapabilities: ProjectExecutableCapabilities
    public let rootURL: URL
    public let mcp: [String]
    public let skills: [String]
    public let prompts: [String]
    public let enginePolicies: [String: ProjectionPolicy]
    public let sourceMetadata: ProjectPluginSourceMetadata
}

public struct ProjectPluginCatalog: Sendable {
    public init() {}

    public func listPlugins(for project: AgentProject) throws -> [ProjectPluginDescriptor] {
        let root = ProjectConfig.pluginRoot(for: project)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return try children
            .filter { ($0.lastPathComponent != ".materialized") && isDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try readPlugin(at: $0) }
    }

    public func validate(_ descriptor: ProjectPluginDescriptor) -> [ProjectConfigDiagnostic] {
        var diagnostics = descriptor.unknownCapabilities.map {
            ProjectConfigDiagnostic(severity: .warning, message: "Unknown plugin capability ignored: \($0)", path: descriptor.rootURL.path)
        }

        for (kind, refs) in [("mcp", descriptor.mcp), ("skills", descriptor.skills)] {
            var seen = Set<String>()
            var reported = Set<String>()
            for ref in refs where !seen.insert(ref).inserted && reported.insert(ref).inserted {
                diagnostics.append(ProjectConfigDiagnostic(severity: .error, message: "Duplicate plugin \(kind) reference: \(ref)", path: descriptor.rootURL.path))
            }
        }

        return diagnostics
    }

    private func readPlugin(at directory: URL) throws -> ProjectPluginDescriptor {
        let manifestURL = directory.appendingPathComponent("plugin.json")
        let data = try Data(contentsOf: manifestURL)
        let raw = try JSONDecoder().decode(RawPlugin.self, from: data)
        guard raw.id == directory.lastPathComponent else {
            throw ProjectPluginCatalogError.idMismatch(expected: directory.lastPathComponent, actual: raw.id)
        }

        var known = Set<ProjectPluginCapability>()
        var unknown: [String] = []
        for capability in raw.capabilities ?? [] {
            if let parsed = ProjectPluginCapability(rawValue: capability) { known.insert(parsed) }
            else { unknown.append(capability) }
        }

        let policies = (raw.engines ?? [:]).mapValues { policy in
            policy.enabled == false ? .disabled : (policy.projection ?? .disabled)
        }
        return ProjectPluginDescriptor(
            id: raw.id,
            name: raw.name,
            version: raw.version,
            enabled: raw.enabled ?? false,
            capabilities: known,
            unknownCapabilities: unknown,
            executableCapabilities: raw.executableCapabilities ?? ProjectExecutableCapabilities(),
            rootURL: directory,
            mcp: raw.mcp ?? [],
            skills: raw.skills ?? [],
            prompts: raw.prompts ?? [],
            enginePolicies: policies,
            sourceMetadata: raw.source ?? .manual
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

public enum ProjectPluginCatalogError: Error, Equatable, CustomStringConvertible {
    case idMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case let .idMismatch(expected, actual):
            return "Plugin id mismatch: expected \(expected), got \(actual)"
        }
    }
}

private struct RawPlugin: Decodable {
    let schemaVersion: Int?
    let id: String
    let name: String
    let version: String?
    let enabled: Bool?
    let capabilities: [String]?
    let executableCapabilities: ProjectExecutableCapabilities?
    let mcp: [String]?
    let skills: [String]?
    let prompts: [String]?
    let engines: [String: RawEnginePolicy]?
    let source: ProjectPluginSourceMetadata?
}

private struct RawEnginePolicy: Decodable {
    let enabled: Bool?
    let projection: ProjectionPolicy?
}
