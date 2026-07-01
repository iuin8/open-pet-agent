import Foundation
import AgentMode
import Shell

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

    // MARK: - 回复来源 segmented 配置（聊天面板 Composer 上方，直觉可用性）

    /// 从 UserDefaults 派生回复来源配置：当前 target + 可选项列表。
    /// 灵魂层（🐾 默认首项）+ `AgentEngineRegistry.all` 每个 engine 一项。聊天面板
    /// 开卡时调，同步 segmented 与设置面板（两处写同一份 UD）。
    nonisolated static func replyConfiguration(
        for defaults: UserDefaults
    ) -> (target: ReplyTarget, options: [ReplyOption]) {
        let enabled = defaults.bool(forKey: agentModeEnabledKey)
        let target: ReplyTarget = enabled
            ? .agent(AgentEngineRegistry.resolve(from: defaults).id)
            : .soul
        var options: [ReplyOption] = [
            ReplyOption(target: .soul, label: "聊天", systemImage: "pawprint.fill")
        ]
        options += AgentEngineRegistry.all.map { entry in
            // 短标签：取 displayName 首词（"Claude Code"→"Claude"，"opencode (ACP)"→"opencode"）。
            let short = entry.displayName.split(separator: " ").first.map(String.init) ?? entry.displayName
            return ReplyOption(target: .agent(entry.id), label: short, systemImage: replyIcon(for: entry.id))
        }
        return (target, options)
    }

    /// engine id → SF Symbol 图标（segmented 紧凑展示用）。
    /// 写死 id 映射（图标本就是 per-engine 定制）；未来 entry 加 iconSymbol 字段可去除此处 switch。
    nonisolated private static func replyIcon(for engineId: String) -> String {
        switch engineId {
        case AgentEngineKind.claudeCode.rawValue: return "bolt.fill"
        case AgentEngineKind.codex.rawValue:      return "chevron.left.forwardslash.chevron.right"
        case AgentEngineKind.openCode.rawValue:   return "terminal.fill"
        default:                                  return "wrench.and.screwdriver"
        }
    }
}
