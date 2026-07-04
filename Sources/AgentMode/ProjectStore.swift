import Foundation

/// 多项目注册表(P1a)。项目列表 `~/.open-pet-agent/projects.json`;当前选中 UD `tool.project.id`。
/// 在 AgentMode target 供 App(`applySelectedAgentEngine`/`wireProjectConfiguration`)+ ACPSmoke 共用。
///
/// 镜像 `ProjectConfig` 风格(enum static,无状态,纯文件操作)。`current()` 给
/// `applySelectedAgentEngine` 选中项目;`list()` 给 UI 列表;`create(name:)` 建新托管项目。
///
/// 首次启动 `ensureDefaultProjectRegistered()` 迁移:projects.json 不存在 → ensure default +
/// 写入含 default + UD = "default"。幂等。失败不致命(`current()` fallback default,行为 = P0)。
///
/// 详见 `docs/project-config-architecture-design.md`。
public enum ProjectStore {

    /// UserDefaults 持久化 key(当前选中项目 id)。沿用 engine 的 `tool.*` 命名。
    public static var currentProjectIDKey: String { "tool.project.id" }

    /// 项目列表文件:`~/.open-pet-agent/projects.json`(顶层 index)。
    public static var projectListURL: URL {
        ProjectConfig.homeRoot.appendingPathComponent(".open-pet-agent/projects.json", isDirectory: false)
    }

    /// 列出所有项目。projects.json 不存在/损坏/空 → [default](永不返回空)。
    public static func list() -> [AgentProject] {
        guard let data = try? Data(contentsOf: projectListURL),
              let projects = try? JSONDecoder().decode([AgentProject].self, from: data) else {
            return [ProjectConfig.defaultProject]
        }
        return projects.isEmpty ? [ProjectConfig.defaultProject] : projects
    }

    /// 当前选中项目。UD `tool.project.id` 缺失/对应项目不存在 → fallback default。
    /// `defaults` 注入便于测试与调用方传同一份 UD(生产 `.standard`)。
    public static func current(defaults: UserDefaults = .standard) -> AgentProject {
        let id = defaults.string(forKey: currentProjectIDKey)
        if let id, let project = list().first(where: { $0.id == id }) {
            return project
        }
        return ProjectConfig.defaultProject
    }

    /// 设置当前选中项目。
    public static func setCurrent(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: currentProjectIDKey)
    }

    /// 创建新托管项目。生成 UUID + 建 `.open-pet-agent/` + opencode.json + 写入 projects.json。
    /// 返回新项目(已 ensure)。
    @discardableResult
    public static func create(name: String) throws -> AgentProject {
        let id = UUID().uuidString
        let root = ProjectConfig.homeRoot
            .appendingPathComponent(".open-pet-agent/projects/\(id)", isDirectory: true)
        return try appendProject(AgentProject(id: id, name: name, rootURL: root, isExternal: false, createdAt: Date()))
    }

    /// 创建外部项目(跟项目走,VSCode 模式)。rootURL = 用户外部目录(如 `~/work/my-app/`)。
    /// 建 rootURL/.open-pet-agent/ + opencode.json + 写入 projects.json。
    @discardableResult
    public static func createExternal(name: String, rootURL: URL) throws -> AgentProject {
        let id = UUID().uuidString
        return try appendProject(AgentProject(id: id, name: name, rootURL: rootURL, isExternal: true, createdAt: Date()))
    }

    /// 重命名项目(改 projects.json 的 name;default 不可改名 — 系统项目)。
    @discardableResult
    public static func rename(id: String, newName: String) throws {
        guard id != ProjectConfig.defaultProject.id else { return }
        var projects = list()
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].name = newName
        try writeList(projects)
    }

    /// 删除项目(从 projects.json 移除;default 不可删)。**不删文件**(托管项目 dir 留给
    /// 用户手动清理;外部项目目录是用户的,绝不动)。调用方删后应 `setCurrent(default)`。
    @discardableResult
    public static func delete(id: String) throws {
        guard id != ProjectConfig.defaultProject.id else { return }
        var projects = list()
        projects.removeAll { $0.id == id }
        try writeList(projects)
    }

    /// 内部:ensure 项目目录 + opencode.json + 追加到 projects.json(create/createExternal 共用,DRY)。
    private static func appendProject(_ project: AgentProject) throws -> AgentProject {
        try ProjectConfig.ensure(for: project)
        var projects = list()
        projects.append(project)
        try writeList(projects)
        return project
    }

    /// 首次迁移:projects.json 不存在 → ensure default + 写入含 default + UD="default"。幂等。
    /// ensure/write 失败不致命(`current()` 会 fallback default,行为 = P0);启动路径不应因此崩。
    public static func ensureDefaultProjectRegistered(defaults: UserDefaults = .standard) {
        guard !FileManager.default.fileExists(atPath: projectListURL.path) else { return }
        do {
            try ProjectConfig.ensure(for: ProjectConfig.defaultProject)
            try writeList([ProjectConfig.defaultProject])
            setCurrent(ProjectConfig.defaultProject.id, defaults: defaults)
        } catch {
            // 不 throw:启动路径不因项目注册失败而崩;current() fallback default。
        }
    }

    /// 写入项目列表(原子)。创建父目录。
    private static func writeList(_ projects: [AgentProject]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: projectListURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(projects)
        try data.write(to: projectListURL, options: .atomic)
    }
}
