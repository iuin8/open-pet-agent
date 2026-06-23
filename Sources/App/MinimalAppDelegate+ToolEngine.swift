import Foundation
import ToolMode

// MARK: - Tool engine routing

extension MinimalAppDelegate {
    /// N2.4 — 按 UserDefaults `tool.engine.kind` 把对应 engine 装到 router。
    ///
    /// 决策:UserDefaults 里没设、或值不识别 → fallback 到 `.claudeCode`
    /// (5417612 commit 起的默认行为,不破坏老用户体验)。
    /// `.openCode` 暂时也 fallback 到 ClaudeCodeEngine —— bundled opencode
    /// runtime N3.x 接入后再实现,提前在 enum 里留 case 是为了避免后续 schema
    /// 漂移。
    ///
    /// 两个调用方:
    /// - `didFinishLaunching` 启动时初始化 router
    /// - `onSaveToolModeEnabled` callback 切 toggle 时即时刷新
    /// 两条路径必须用同一份选 engine 逻辑,避免一处改了另一处遗漏。
    static func applySelectedToolEngine(
        to router: ToolModeRouter?,
        defaults: UserDefaults
    ) {
        guard let router else { return }
        let raw = defaults.string(forKey: ToolEngineKind.userDefaultsKey)
        let kind = raw.flatMap(ToolEngineKind.init(rawValue:)) ?? .claudeCode
        switch kind {
        case .codex:
            router.setEngine(CodexEngine())
        case .openCode, .claudeCode:
            // openCode 暂时 fallback 到 ClaudeCodeEngine,N3.x bundled opencode
            // runtime 接入后再补真实 engine。这样 UI 即便提前暴露 .openCode
            // 选项也不会让 router 进入无 engine 的废态。
            router.setEngine(ClaudeCodeEngine())
        }
    }
}
