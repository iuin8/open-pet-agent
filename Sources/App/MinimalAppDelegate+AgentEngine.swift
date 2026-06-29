import Foundation
import AgentMode

// MARK: - Tool engine routing

extension MinimalAppDelegate {
    /// N2.4 — 按 UserDefaults `tool.engine.kind` 把对应 engine 装到 router。
    ///
    /// 不再写死 `switch kind`:经 `AgentEngineRegistry.resolve(from:)` 选中 entry
    /// (UD 没设 / 值不识别 → fallback `all[0]` = claudeCode,5417612 起的默认行为),
    /// 再调 `entry.makeEngine()` 构造 engine。新增 engine = 注册表加一条 entry,
    /// 这里零改动(镜像「形象插件化」,与灵魂层 `SoulBackendRegistry` 同构)。
    /// 注:opencode entry 的 `makeEngine` 当前兜底到 ClaudeCodeEngine(bundled
    /// opencode runtime N3.x 接入前),细节见 `AgentEngineRegistry.openCode`。
    ///
    /// 两个调用方:
    /// - `didFinishLaunching` 启动时初始化 router
    /// - `onSaveAgentModeEnabled` callback 切 toggle 时即时刷新
    /// 两条路径必须用同一份选 engine 逻辑,避免一处改了另一处遗漏。
    static func applySelectedAgentEngine(
        to router: AgentModeRouter?,
        defaults: UserDefaults
    ) {
        guard let router else { return }
        router.setEngine(AgentEngineRegistry.resolve(from: defaults).makeEngine())
    }
}
