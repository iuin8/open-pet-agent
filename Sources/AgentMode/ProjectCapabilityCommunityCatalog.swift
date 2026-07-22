import Foundation

public enum ProjectCapabilityCommunityCatalogError: Error, LocalizedError, Equatable {
    case invalidCatalog
    case invalidEntry(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: return "社区源 catalog 格式无效"
        case .invalidEntry(let message): return message
        }
    }
}

public enum ProjectCapabilityCommunityCatalog {
    public static func parse(_ data: Data, source: ProjectCapabilityCommunitySource) throws -> [ProjectCapabilityInstallDraft] {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.schemaVersion == 1 else { throw ProjectCapabilityCommunityCatalogError.invalidCatalog }
        return try catalog.entries.map { try draft(from: $0, source: source) }
    }

    private static func draft(from entry: Entry, source: ProjectCapabilityCommunitySource) throws -> ProjectCapabilityInstallDraft {
        try validateEntryID(entry.id)
        try validateContentHash(entry.contentHash)
        if let sourceURL = entry.sourceURL {
            _ = try ProjectCapabilityCommunitySource.validatedURL(sourceURL)
        }
        let metadata = ProjectPluginSourceMetadata(
            kind: .marketplace,
            url: "\(source.url)#\(entry.id)",
            revision: entry.revision,
            contentHash: entry.contentHash
        )
        let blockingReason = entry.contentHash == nil
            ? "远端社区条目缺少 contentHash，只能浏览或手动复制 JSON"
            : nil
        switch entry.kind {
        case "mcp":
            guard let serverName = entry.serverName, !serverName.isEmpty,
                  let serverJSON = entry.serverJSON else {
                throw ProjectCapabilityCommunityCatalogError.invalidEntry("MCP 条目缺少 serverName 或 serverJSON")
            }
            try validateMCP(serverJSON)
            return ProjectCapabilityInstallDraft(
                kind: .mcp,
                pluginID: entry.id,
                name: entry.name,
                description: entry.description,
                sourceMetadata: metadata,
                mcpServers: [.init(name: serverName, value: serverJSON)],
                blockingReason: blockingReason
            )
        case "skill":
            let files = try skillFiles(entry)
            return ProjectCapabilityInstallDraft(
                kind: .skill,
                pluginID: entry.id,
                name: entry.name,
                description: entry.description,
                sourceMetadata: metadata,
                skillFiles: files,
                blockingReason: blockingReason
            )
        default:
            throw ProjectCapabilityCommunityCatalogError.invalidEntry("不支持的社区能力类型: \(entry.kind)")
        }
    }

    private static func validateMCP(_ value: ACPJSON) throws {
        guard ProjectCapabilityMCPResolver.isValidConfiguration(value) else {
            throw ProjectCapabilityCommunityCatalogError.invalidEntry("MCP server JSON 格式无效")
        }
    }

    private static func validateEntryID(_ value: String) throws {
        guard !value.isEmpty,
              !value.hasPrefix("."),
              !value.contains("/"),
              value != ".." else {
            throw ProjectCapabilityCommunityCatalogError.invalidEntry("社区条目 id 无效: \(value)")
        }
    }

    private static func validateContentHash(_ value: String?) throws {
        guard let value else { return }
        let prefix = "sha256:"
        guard value.hasPrefix(prefix), value.count == prefix.count + 64 else {
            throw ProjectCapabilityCommunityCatalogError.invalidEntry("contentHash 必须是 sha256:<64 hex>")
        }
        let hex = value.dropFirst(prefix.count)
        guard hex.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) || ("A"..."F").contains($0) }) else {
            throw ProjectCapabilityCommunityCatalogError.invalidEntry("contentHash 必须是 sha256:<64 hex>")
        }
    }

    private static func skillFiles(_ entry: Entry) throws -> [ProjectCapabilityImportFile] {
        guard let files = entry.skillFiles, !files.isEmpty else {
            throw ProjectCapabilityCommunityCatalogError.invalidEntry("Skill 条目缺少文件")
        }
        var result: [ProjectCapabilityImportFile] = []
        var seen = Set<String>()
        for file in files {
            guard isContainedRelativePath(file.path) else {
                throw ProjectCapabilityCommunityCatalogError.invalidEntry("Skill 文件路径越界: \(file.path)")
            }
            guard seen.insert(file.path).inserted else {
                throw ProjectCapabilityCommunityCatalogError.invalidEntry("Skill 文件路径重复: \(file.path)")
            }
            result.append(.init(relativePath: file.path, contents: Data(file.text.utf8)))
        }
        guard result.contains(where: { $0.relativePath == "SKILL.md" }) else {
            throw ProjectCapabilityCommunityCatalogError.invalidEntry("Skill 条目缺少 SKILL.md")
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private static func isContainedRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("//") else { return false }
        return !path.split(separator: "/").contains("..")
    }
}

private struct Catalog: Decodable {
    let schemaVersion: Int
    let name: String
    let entries: [Entry]
}

private struct Entry: Decodable {
    let id: String
    let kind: String
    let name: String
    let description: String
    let sourceURL: String?
    let revision: String?
    let contentHash: String?
    let serverName: String?
    let serverJSON: ACPJSON?
    let skillFiles: [SkillFile]?
}

private struct SkillFile: Decodable {
    let path: String
    let text: String
}
