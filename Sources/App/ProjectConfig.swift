import Foundation

/// PetAgent 项目配置(production-grade 架构,详见 `docs/project-config-architecture-design.md`)。
///
/// P0:默认项目 `~/.open-pet-agent/projects/default/` + `.open-pet-agent/opencode.json`
/// (model = 用户全局 provider 的第一个 model)。ACP engine 用此为 cwd + `OPENCODE_CONFIG` env,
/// 解决「app cwd=/ 无 opencode.json → 默认 model `big-pickle` 卡」(问题 2)。
///
/// 后续(P1+):多项目创建/切换 UI、外部项目(跟项目走)、persona 可配、current-project 检测。
enum ProjectConfig {

    /// 默认项目根:`~/.open-pet-agent/projects/default/`。
    static var defaultProjectRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".open-pet-agent/projects/default", isDirectory: true)
    }

    /// 默认项目 `.open-pet-agent/opencode.json` 路径(真源)。
    static var defaultOpencodeConfig: URL {
        defaultProjectRoot.appendingPathComponent(".open-pet-agent/opencode.json", isDirectory: false)
    }

    /// 确保默认项目存在(创建目录 + opencode.json)。返回项目根 URL。
    /// 幂等:已存在不覆盖 opencode.json(用户改的保留)。
    @discardableResult
    static func ensureDefaultProject() throws -> URL {
        let fm = FileManager.default
        let dotDir = defaultProjectRoot.appendingPathComponent(".open-pet-agent", isDirectory: true)
        try fm.createDirectory(at: dotDir, withIntermediateDirectories: true)
        let configURL = defaultOpencodeConfig
        guard !fm.fileExists(atPath: configURL.path) else { return defaultProjectRoot }
        let json = makeDefaultOpencodeJSON()
        try json.data(using: .utf8)?.write(to: configURL, options: .atomic)
        return defaultProjectRoot
    }

    /// 生成默认 opencode.json:`{"model":"<provider>/<model>"}`(用户全局 provider 的第一个 model)。
    /// 全局无 provider → fallback `opencode/big-pickle`(opencode 默认;用户需配全局 provider)。
    static func makeDefaultOpencodeJSON() -> String {
        let globalConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/opencode.json")
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
