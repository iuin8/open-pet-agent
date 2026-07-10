import Foundation

public extension ProjectCapabilityWriter {
    @discardableResult
    func importCandidates(
        _ candidates: [ProjectCapabilityImportCandidate],
        project: AgentProject,
        pluginID: String,
        pluginName: String
    ) throws -> CapabilityPlugin {
        try validateImportPluginID(pluginID)
        guard !candidates.isEmpty else {
            throw ProjectCapabilityValidationError("No import candidates selected")
        }
        guard candidates.allSatisfy({ $0.diagnostics.isEmpty }) else {
            throw ProjectCapabilityValidationError("Import contains conflicts")
        }

        let pluginRoot = ProjectConfig.pluginRoot(for: project)
            .standardizedFileURL
        let resolvedPluginRoot = pluginRoot.resolvingSymlinksInPath()
        let resolvedProjectRoot = project.rootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard ProjectionTrust.isPath(
            resolvedPluginRoot,
            inside: resolvedProjectRoot
        ) else {
            throw ProjectCapabilityValidationError(
                "Canonical plugin root escapes project"
            )
        }
        let destination = ProjectConfig.pluginDirectory(
            for: project,
            pluginID: pluginID
        ).standardizedFileURL
        guard ProjectionTrust.isPath(destination, inside: pluginRoot),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProjectCapabilityValidationError(
                "Canonical plugin already exists: \(pluginID)"
            )
        }

        let staging = pluginRoot.appendingPathComponent(
            ".import-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try writeImport(
            candidates,
            pluginID: pluginID,
            pluginName: pluginName,
            to: staging
        )
        let plugin = ProjectCapabilityImportBuilder.plugin(
            candidates: candidates,
            pluginID: pluginID,
            pluginName: pluginName,
            root: destination
        )
        try FileManager.default.moveItem(at: staging, to: destination)
        return plugin
    }

    private func validateImportPluginID(_ pluginID: String) throws {
        guard !pluginID.isEmpty,
              !pluginID.hasPrefix("."),
              !pluginID.contains("/"),
              pluginID != ".." else {
            throw ProjectCapabilityValidationError(
                "Invalid plugin id: \(pluginID)"
            )
        }
    }

    private func writeImport(
        _ candidates: [ProjectCapabilityImportCandidate],
        pluginID: String,
        pluginName: String,
        to root: URL
    ) throws {
        let skills = candidates.filter { $0.kind == .skill }
        let mcp = candidates.filter { $0.kind == .mcp }
        try validateUniqueNames(skills, kind: "skill")
        try validateUniqueNames(mcp, kind: "MCP")

        for candidate in skills {
            guard candidate.skillBody != nil,
                  !candidate.skillFiles.isEmpty else {
                throw ProjectCapabilityValidationError(
                    "Missing import skill body: \(candidate.name)"
                )
            }
            let directory = root
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent(candidate.name, isDirectory: true)
            guard ProjectionTrust.isPath(directory, inside: root) else {
                throw ProjectCapabilityValidationError(
                    "Invalid import skill name: \(candidate.name)"
                )
            }
            for file in candidate.skillFiles {
                let destination = directory
                    .appendingPathComponent(file.relativePath, isDirectory: false)
                    .standardizedFileURL
                guard ProjectionTrust.isPath(destination, inside: directory),
                      destination.path != directory.path else {
                    throw ProjectCapabilityValidationError(
                        "Invalid import skill file: \(file.relativePath)"
                    )
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.contents.write(to: destination, options: .atomic)
            }
        }

        if !mcp.isEmpty {
            var servers: [String: Any] = [:]
            for candidate in mcp {
                guard let value = candidate.mcpValue,
                      ProjectCapabilityMCPResolver
                          .isValidConfiguration(value) else {
                    throw ProjectCapabilityValidationError(
                        "Malformed MCP import: \(candidate.name)"
                    )
                }
                servers[candidate.name] = value.importJSONObject
            }
            let mcpURL = root.appendingPathComponent(
                "mcp/servers.json",
                isDirectory: false
            )
            try FileManager.default.createDirectory(
                at: mcpURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeImportJSON(["mcpServers": servers], to: mcpURL)
        }

        var capabilities: [String] = []
        if !skills.isEmpty { capabilities.append("skills") }
        if !mcp.isEmpty { capabilities.append("mcp") }
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "id": pluginID,
            "name": pluginName.isEmpty ? pluginID : pluginName,
            "enabled": true,
            "capabilities": capabilities,
            "skills": skills.map { "skills/\($0.name)" }.sorted(),
            "mcp": mcp.map { "mcp/servers.json#\($0.name)" }.sorted(),
            "engines": ProjectCapabilityImportBuilder.engines(
                for: candidates
            )
        ]
        try writeImportJSON(
            manifest,
            to: root.appendingPathComponent("plugin.json")
        )
    }

    private func validateUniqueNames(
        _ candidates: [ProjectCapabilityImportCandidate],
        kind: String
    ) throws {
        var seen = Set<String>()
        for candidate in candidates {
            guard !candidate.name.isEmpty,
                  !candidate.name.contains("/"),
                  candidate.name != ".",
                  candidate.name != "..",
                  seen.insert(candidate.name).inserted else {
                throw ProjectCapabilityValidationError(
                    "Invalid or duplicate import \(kind): \(candidate.name)"
                )
            }
        }
    }

    private func writeImportJSON(
        _ object: [String: Any],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}

private extension ACPJSON {
    var importJSONObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.importJSONObject)
        case .object(let values):
            return values.mapValues(\.importJSONObject)
        }
    }
}
