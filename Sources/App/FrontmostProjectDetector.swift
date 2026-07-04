import AppKit
import AgentMode

/// 检测前台 app cwd → 匹配 project → 自动切(P3 current-project 检测)。
///
/// 触发:`NSWorkspace.didActivateApplicationNotification`(App 接线)→ `detect()`。
/// 匹配:cwd 是某 `ProjectStore` project rootURL 子目录(最长前缀匹配,嵌套取最深)→ setCurrent + 重 apply。
/// 无匹配(GUI app cwd=`/` 或非项目目录)→ 不切(保持当前)。手动切项目后调 `reset()` 避免立即切回。
@MainActor
final class FrontmostProjectDetector {
    private let defaults: UserDefaults
    private let router: AgentModeRouter?
    private var lastDetectedID: String?

    init(defaults: UserDefaults, router: AgentModeRouter?) {
        self.defaults = defaults
        self.router = router
        self.lastDetectedID = ProjectStore.current(defaults: defaults).id
    }

    /// 检测前台 app cwd → 匹配 project → 切(若变化)。无匹配 → 不切。
    func detect() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let cwd = ProcCWDReader.cwd(of: pid) else { return }
        guard let matched = Self.matchProject(cwd: cwd, in: ProjectStore.list()),
              matched.id != lastDetectedID else { return }
        lastDetectedID = matched.id
        ProjectStore.setCurrent(matched.id, defaults: defaults)
        MinimalAppDelegate.applySelectedAgentEngine(to: router, defaults: defaults)
    }

    /// 重置 lastDetectedID(用户手动切项目后调,避免 detector 立即切回)。
    func reset() {
        lastDetectedID = ProjectStore.current(defaults: defaults).id
    }

    /// 匹配 cwd → project(最长前缀匹配:cwd 是 rootURL 子目录或 == rootURL)。
    /// 嵌套项目取最深(如 ~/work/ 下有 my-app 和 my-app/sub,取 my-app/sub)。
    /// nonisolated:纯函数,不依赖 actor,测试可同步调。
    nonisolated static func matchProject(cwd: URL, in projects: [AgentProject]) -> AgentProject? {
        let cwdPath = cwd.standardizedFileURL.path
        return projects
            .filter { cwdPath.hasPrefix($0.rootURL.standardizedFileURL.path) }
            .max(by: { $0.rootURL.path.count < $1.rootURL.path.count })
    }
}
