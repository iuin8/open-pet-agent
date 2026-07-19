import Foundation

/// 投影生成物所有权清单(production-grade 单一事实来源)。
///
/// 记录 PetAgent 投影到项目内的文件/目录(`.mcp.json`、`opencode.json`、`.codex/config.toml`、
/// `.claude/skills/<x>/`、`.agents/skills/<x>/`、`.opencode/skills/<x>/`、`.open-pet-agent/plugins/.materialized/...`)。
/// 项目根与各 skill 目录不出现任何 PetAgent bookkeeping 文件,ownership 全部收敛于此清单。
///
/// 落盘位置:`<projectRoot>/.open-pet-agent/state/generated-targets.json`(原子写,路径相对项目根,
/// 项目目录整体移动后仍有效)。ownership 判定 fail-closed:清单缺失/损坏 → 一律视为非 PetAgent 生成,
/// 拒绝覆盖;目标已存在而 ownership 无法证明时,下一次 sync 以 unownedDestination 明确报错,
/// 不会误覆盖用户文件。
///
/// 簿记失败契约(与「审计状态写失败不回滚也不伪装 materialize 失败」同级):
/// `.open-pet-agent/state` 损坏时登记静默失败、sync 仍须成功;代价是该目标暂失 ownership 记录,
/// 待 state 修复后由 sync 重新登记或按 unownedDestination 显式报错,绝不静默吞掉用户文件。
public struct ProjectionGeneratedTarget: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
    }

    /// 相对项目根的 POSIX 路径(如 `.mcp.json`、`.claude/skills/dev-toolkit-code-review`)。
    public let path: String
    public let kind: Kind
    public let engineID: String

    public init(path: String, kind: Kind, engineID: String) {
        self.path = path
        self.kind = kind
        self.engineID = engineID
    }
}

public struct ProjectionGeneratedManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public private(set) var targets: [ProjectionGeneratedTarget]

    public init(schemaVersion: Int = ProjectionGeneratedManifest.currentSchemaVersion, targets: [ProjectionGeneratedTarget] = []) {
        self.schemaVersion = schemaVersion
        self.targets = targets.sorted { ($0.path, $0.engineID) < ($1.path, $1.engineID) }
    }

    public func contains(path: String) -> Bool {
        targets.contains { $0.path == path }
    }

    public mutating func claim(path: String, kind: ProjectionGeneratedTarget.Kind, engineID: String) {
        targets.removeAll { $0.path == path }
        targets.append(ProjectionGeneratedTarget(path: path, kind: kind, engineID: engineID))
        targets.sort { ($0.path, $0.engineID) < ($1.path, $1.engineID) }
    }

    public mutating func release(path: String) {
        targets.removeAll { $0.path == path }
    }
}

public enum ProjectionGeneratedManifestStore {
    /// 清单路径:`<projectRoot>/.open-pet-agent/state/generated-targets.json`。
    public static func manifestURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".open-pet-agent/state/generated-targets.json", isDirectory: false)
    }

    /// 读取清单。文件不存在 → 空清单;损坏 → 抛错(调用方决定 fail-closed 策略)。
    public static func load(projectRoot: URL) throws -> ProjectionGeneratedManifest {
        let url = manifestURL(projectRoot: projectRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProjectionGeneratedManifest()
        }
        return try JSONDecoder().decode(ProjectionGeneratedManifest.self, from: Data(contentsOf: url))
    }

    /// 原子写清单(先写临时文件再落盘,crash 不留半截 JSON)。
    public static func save(_ manifest: ProjectionGeneratedManifest, projectRoot: URL) throws {
        let url = manifestURL(projectRoot: projectRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    /// 相对项目根的 POSIX 路径;url 不在项目内 → nil。
    /// 双端都先 resolve symlink(scanner/audit 传入的多为 resolved 路径;macOS 上 /var→/private/var
    /// 这类系统级 symlink 不能让前缀匹配失败,否则 ownership 判定会漏)。
    public static func relativePath(for url: URL, projectRoot: URL) -> String? {
        let root = normalize(projectRoot.resolvingSymlinksInPath())
        let path = normalize(url.resolvingSymlinksInPath())
        guard path != root, path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// ownership 判定:仅以清单为准(fail-closed,任何读取错误 → false)。
    public static func isGeneratedTarget(_ url: URL, projectRoot: URL) -> Bool {
        guard let relative = relativePath(for: url, projectRoot: projectRoot),
              let manifest = try? load(projectRoot: projectRoot) else { return false }
        return manifest.contains(path: relative)
    }

    /// materializer 专用登记:先登记再写 payload(crash 也不留「自己写的文件没有 ownership 记录」
    /// 的自锁);簿记失败静默放行,绝不阻断 materialize(见文件头契约说明)。
    public static func claimBestEffort(_ url: URL, kind: ProjectionGeneratedTarget.Kind, engineID: String, projectRoot: URL) {
        guard let relative = relativePath(for: url, projectRoot: projectRoot) else { return }
        var manifest = (try? load(projectRoot: projectRoot)) ?? ProjectionGeneratedManifest()
        manifest.claim(path: relative, kind: kind, engineID: engineID)
        try? save(manifest, projectRoot: projectRoot)
    }

    /// removeGenerated 专用摘除:簿记失败不阻断删除(残留登记指向已不存在的路径,无害)。
    public static func releaseBestEffort(_ url: URL, projectRoot: URL) {
        guard let relative = relativePath(for: url, projectRoot: projectRoot),
              var manifest = try? load(projectRoot: projectRoot) else { return }
        manifest.release(path: relative)
        try? save(manifest, projectRoot: projectRoot)
    }

    private static func normalize(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
