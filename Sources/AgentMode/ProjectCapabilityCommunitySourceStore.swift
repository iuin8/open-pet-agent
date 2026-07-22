import Foundation

public struct ProjectCapabilityCommunitySourceStore: Sendable {
    public init() {}

    public func load(project: AgentProject) throws -> [ProjectCapabilityCommunitySource] {
        let url = ProjectConfig.communitySourcesURL(for: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([ProjectCapabilityCommunitySource].self, from: data)
        } catch {
            return []
        }
    }

    public func save(_ sources: [ProjectCapabilityCommunitySource], project: AgentProject) throws {
        let url = ProjectConfig.communitySourcesURL(for: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sources).write(to: url, options: .atomic)
    }

    public func upsert(_ source: ProjectCapabilityCommunitySource, project: AgentProject) throws {
        let sources = try load(project: project)
        let next: [ProjectCapabilityCommunitySource]
        if sources.contains(where: { $0.id == source.id }) {
            next = sources.map { $0.id == source.id ? source : $0 }
        } else {
            next = sources + [source]
        }
        try save(next, project: project)
    }

    public func delete(id: String, project: AgentProject) throws {
        try save(try load(project: project).filter { $0.id != id }, project: project)
    }
}
