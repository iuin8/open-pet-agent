import Foundation

enum ProjectCapabilityImportBuilder {
    static func plugin(
        candidates: [ProjectCapabilityImportCandidate],
        pluginID: String,
        pluginName: String,
        root: URL
    ) -> CapabilityPlugin {
        let pluginTargets = targetUnion(for: candidates)
        let skills = candidates.filter { $0.kind == .skill }.map { candidate in
            CapabilitySkill(
                id: "\(pluginID):skills/\(candidate.name)",
                name: candidate.name,
                relativePath: "skills/\(candidate.name)",
                summary: candidate.skillBody.flatMap(skillSummary),
                body: candidate.skillBody,
                bodyPreview: candidate.skillBody.map { String($0.prefix(240)) },
                targets: pluginTargets,
                diagnostics: []
            )
        }
        let servers = candidates.compactMap { candidate -> CapabilityMCPServer? in
            guard candidate.kind == .mcp,
                  let value = candidate.mcpValue,
                  let object = value.objectValue else { return nil }
            let transport: MCPTransport
            switch object["type"]?.stringValue
                ?? object["transport"]?.stringValue {
            case "sse": transport = .sse
            case "http": transport = .http
            default: transport = object["url"] == nil ? .stdio : .http
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return CapabilityMCPServer(
                id: "\(pluginID):\(candidate.name)",
                name: candidate.name,
                fileRef: "mcp/servers.json",
                transport: transport,
                command: ProjectCapabilityMCPResolver.commandParts(for: value) ?? [],
                url: object["url"]?.stringValue,
                env: object["env"]?.objectValue?
                    .compactMapValues(\.stringValue) ?? [:],
                cwd: object["cwd"]?.stringValue,
                rawJSON: (try? encoder.encode(value)).flatMap {
                    String(data: $0, encoding: .utf8)
                },
                targets: pluginTargets,
                diagnostics: []
            )
        }
        return CapabilityPlugin(
            id: pluginID,
            name: pluginName.isEmpty ? pluginID : pluginName,
            version: nil,
            enabled: true,
            source: .local(path: root.path),
            skills: skills.sorted { $0.name < $1.name },
            mcpServers: servers.sorted { $0.name < $1.name },
            profiles: [],
            diagnostics: []
        )
    }

    static func engines(
        for candidates: [ProjectCapabilityImportCandidate]
    ) -> [String: Any] {
        let targetSet = Set(targetUnion(for: candidates))
        var engines: [String: Any] = [:]
        if targetSet.contains(.codex) {
            engines["codex"] = [
                "enabled": true,
                "projection": "skills-and-mcp-files"
            ]
        }
        if targetSet.contains(.claudeCode) {
            engines["claude-code"] = [
                "enabled": true,
                "projection": "skills-and-mcp-files"
            ]
        }
        if targetSet.contains(.opencode) {
            engines["opencode"] = [
                "enabled": true,
                "projection": "skills-and-mcp-files"
            ]
        }
        return engines
    }

    private static func targetUnion(
        for candidates: [ProjectCapabilityImportCandidate]
    ) -> [CapabilityTarget] {
        let targetSet = Set(candidates.flatMap { targets(for: $0) })
        return targetSet.sorted { $0.rawValue < $1.rawValue }
    }

    private static func targets(
        for candidate: ProjectCapabilityImportCandidate
    ) -> [CapabilityTarget] {
        var targetSet = Set<CapabilityTarget>()
        for source in candidate.sources {
            switch source.kind {
            case .claudeSkill, .claudeMCP:
                targetSet.insert(.claudeCode)
            case .agentsSkill, .codexMCP:
                targetSet.insert(.codex)
            case .opencodeSkill, .opencodeMCP:
                targetSet.insert(.opencode)
            }
        }
        return targetSet.sorted { $0.rawValue < $1.rawValue }
    }

    private static func skillSummary(_ body: String) -> String? {
        body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
