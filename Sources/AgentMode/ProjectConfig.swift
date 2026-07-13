import Foundation

/// PetAgent 项目配置(production-grade 架构,详见 `docs/project-config-architecture-design.md`)。
/// 在 AgentMode target 供 App(`applySelectedAgentEngine`/`wireProjectConfiguration`)+ ACPSmoke 共用。
///
/// P0:默认项目 + `.open-pet-agent/opencode.json`(model=用户全局 provider)。ACP engine 用此为
/// cwd + `OPENCODE_CONFIG` env,解决「app cwd=/ 无 opencode.json → big-pickle 卡」(问题 2)。
/// P1a:泛化到任意 `AgentProject`(`ensure(for:)`/`opencodeConfig(for:)`)。`ProjectStore.current()`
/// 选中的项目做 cwd + env,default 逻辑保留(P0 兼容 + current fallback)。
public enum ProjectConfig {

    /// 测试钩子:覆盖 HOME 解析(nil → 真 `~`)。生产 nil,测试 setUp 设临时目录隔离,绝不污染真 `~/.open-pet-agent/`。
    /// internal:仅 `@testable import AgentMode` 可访问(App 不用)。
    internal static var homeDirectoryOverride: URL?

    /// HOME 根(测试可 override)。
    public static var homeRoot: URL {
        homeDirectoryOverride ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// 默认项目根:`~/.open-pet-agent/projects/default/`。
    public static var defaultProjectRoot: URL {
        homeRoot.appendingPathComponent(".open-pet-agent/projects/default", isDirectory: true)
    }

    /// 默认项目 `.open-pet-agent/opencode.json` 路径(真源)。
    public static var defaultOpencodeConfig: URL {
        defaultProjectRoot.appendingPathComponent(".open-pet-agent/opencode.json", isDirectory: false)
    }

    /// 默认项目(`AgentProject` 形态;id="default" 确定性,跨机器一致)。
    public static var defaultProject: AgentProject {
        AgentProject(
            id: "default",
            name: "默认项目",
            rootURL: defaultProjectRoot,
            isExternal: false,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// 指定项目 `.open-pet-agent/opencode.json` 路径。
    public static func opencodeConfig(for project: AgentProject) -> URL {
        project.rootURL.appendingPathComponent(".open-pet-agent/opencode.json", isDirectory: false)
    }

    /// 指定项目 `.open-pet-agent/plugins/` 路径(project plugin canonical root)。
    public static func pluginRoot(for project: AgentProject) -> URL {
        project.rootURL.appendingPathComponent(".open-pet-agent/plugins", isDirectory: true)
    }

    /// 指定项目 local-only 能力状态路径。只记录 PetAgent 自己的审计元数据,不投影给外部 agent。
    public static func capabilityAuditStateURL(for project: AgentProject) -> URL {
        project.rootURL.appendingPathComponent(".open-pet-agent/state/capabilities.local.json", isDirectory: false)
    }

    /// 指定项目某个 plugin bundle 路径:`.open-pet-agent/plugins/<plugin-id>/`。
    public static func pluginDirectory(for project: AgentProject, pluginID: String) -> URL {
        pluginRoot(for: project).appendingPathComponent(pluginID, isDirectory: true)
    }

    public static func pluginMCPDirectory(for project: AgentProject, pluginID: String) -> URL {
        pluginDirectory(for: project, pluginID: pluginID).appendingPathComponent("mcp", isDirectory: true)
    }

    public static func pluginSkillsDirectory(for project: AgentProject, pluginID: String) -> URL {
        pluginDirectory(for: project, pluginID: pluginID).appendingPathComponent("skills", isDirectory: true)
    }

    public static func pluginPromptsDirectory(for project: AgentProject, pluginID: String) -> URL {
        pluginDirectory(for: project, pluginID: pluginID).appendingPathComponent("prompts", isDirectory: true)
    }

    public static func pluginToolsDirectory(for project: AgentProject, pluginID: String) -> URL {
        pluginDirectory(for: project, pluginID: pluginID).appendingPathComponent("tools", isDirectory: true)
    }

    public static func pluginAgentsDirectory(for project: AgentProject, pluginID: String) -> URL {
        pluginDirectory(for: project, pluginID: pluginID).appendingPathComponent("agents", isDirectory: true)
    }

    public static func materializedPluginDirectory(for project: AgentProject, engineID: String, pluginID: String) -> URL {
        pluginRoot(for: project)
            .appendingPathComponent(".materialized", isDirectory: true)
            .appendingPathComponent(engineID, isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(pluginID, isDirectory: true)
    }

    /// 确保默认项目存在(创建目录 + opencode.json)。返回项目根 URL。幂等。
    /// P0 API,保留兼容;内部委托 `ensure(for:)`。
    @discardableResult
    public static func ensureDefaultProject() throws -> URL {
        try ensure(for: defaultProject)
    }

    /// 确保指定项目的 `.open-pet-agent/` + opencode.json 存在。幂等(已存在不覆盖 opencode.json)。返回项目根。
    @discardableResult
    public static func ensure(for project: AgentProject) throws -> URL {
        let fm = FileManager.default
        let dotDir = project.rootURL.appendingPathComponent(".open-pet-agent", isDirectory: true)
        try fm.createDirectory(at: dotDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: pluginRoot(for: project), withIntermediateDirectories: true)
        let configURL = opencodeConfig(for: project)
        guard !fm.fileExists(atPath: configURL.path) else { return project.rootURL }
        let json = makeDefaultOpencodeJSON()
        try json.data(using: .utf8)?.write(to: configURL, options: .atomic)
        return project.rootURL
    }

    /// 生成默认 opencode.json:`{"model":"<provider>/<model>"}`(用户全局 provider 的第一个 model)。
    /// 全局无 provider → fallback `opencode/big-pickle`。internal:`ensure(for:)` 内部用,不外暴露。
    static func makeDefaultOpencodeJSON() -> String {
        let globalConfig = homeRoot.appendingPathComponent(".config/opencode/opencode.json")
        guard let data = try? Data(contentsOf: globalConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = json["provider"] as? [String: Any],
              let firstProvider = providers.keys.first,
              let providerObj = providers[firstProvider] as? [String: Any],
              let models = providerObj["models"] as? [String: Any],
              let firstModel = models.keys.first else {
            return #"{"model":"opencode/big-pickle"}"#
        }
        return #"{"model":"\#(firstProvider)/\#(firstModel)"}"#
    }
}
