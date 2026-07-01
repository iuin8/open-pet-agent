import Foundation
import Testing
import AgentMode
import Shell
@testable import App

// MARK: - ReplyConfiguration tests
//
// 聊天面板回复来源 segmented 的配置派生(ACP-UX):验证 UserDefaults → ReplyTarget
// 映射 + 可选项列表结构。覆盖:默认灵魂层 / agentModeEnabled 开关优先于 engine kind /
// 未知 engine id fallback / options = soul(首) + registry.all / 短标签取首词。

@Suite("ReplyConfiguration")
struct ReplyConfigurationTests {

    // MARK: - Helpers

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "ReplyConfigurationTests.\(name).\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        return ud
    }

    // MARK: - target 派生(UD → ReplyTarget)

    @Test("默认(UD 空)→ 灵魂层 soul(开箱即用)")
    func defaultIsSoul() {
        let cfg = MinimalAppDelegate.replyConfiguration(for: makeDefaults())
        #expect(cfg.target == .soul)
    }

    @Test("agentModeEnabled=false → 灵魂层(即使 engine kind 已设,开关优先)")
    func disabledOverridesEngineKind() {
        let ud = makeDefaults()
        ud.set(false, forKey: MinimalAppDelegate.agentModeEnabledKey)
        ud.set(AgentEngineKind.codex.rawValue, forKey: AgentEngineKind.userDefaultsKey)
        #expect(MinimalAppDelegate.replyConfiguration(for: ud).target == .soul)
    }

    @Test("agentModeEnabled=true + codex → agent(codex)")
    func enabledCodex() {
        let ud = makeDefaults()
        ud.set(true, forKey: MinimalAppDelegate.agentModeEnabledKey)
        ud.set(AgentEngineKind.codex.rawValue, forKey: AgentEngineKind.userDefaultsKey)
        #expect(MinimalAppDelegate.replyConfiguration(for: ud).target == .agent(AgentEngineKind.codex.rawValue))
    }

    @Test("agentModeEnabled=true + 未知 engine id → fallback claudeCode")
    func enabledUnknownEngineFallsBack() {
        let ud = makeDefaults()
        ud.set(true, forKey: MinimalAppDelegate.agentModeEnabledKey)
        ud.set("nonexistent-engine", forKey: AgentEngineKind.userDefaultsKey)
        #expect(MinimalAppDelegate.replyConfiguration(for: ud).target == .agent(AgentEngineKind.claudeCode.rawValue))
    }

    // MARK: - options 列表结构

    @Test("options = soul(首项) + AgentEngineRegistry.all,顺序固定")
    func optionsShape() {
        let cfg = MinimalAppDelegate.replyConfiguration(for: makeDefaults())
        // 首项灵魂层(开箱默认) + registry.all 的每个 engine。
        let expectedCount = 1 + AgentEngineRegistry.all.count
        #expect(cfg.options.count == expectedCount)
        #expect(cfg.options.first?.target == .soul)
        let agentIds = cfg.options.compactMap { opt -> String? in
            if case .agent(let id) = opt.target { return id } else { return nil }
        }
        #expect(agentIds == AgentEngineRegistry.all.map(\.id))
    }

    @Test("灵魂层选项 label=聊天, icon=pawprint.fill")
    func soulOptionDisplay() {
        let cfg = MinimalAppDelegate.replyConfiguration(for: makeDefaults())
        let soul = cfg.options.first { $0.target == .soul }
        #expect(soul?.label == "聊天")
        #expect(soul?.systemImage == "pawprint.fill")
    }

    @Test("engine 短标签取 displayName 首词(Claude Code→Claude, opencode (ACP)→opencode)")
    func engineShortLabels() {
        let cfg = MinimalAppDelegate.replyConfiguration(for: makeDefaults())
        let byId = Dictionary(
            uniqueKeysWithValues: cfg.options.compactMap { opt -> (String, String)? in
                if case .agent(let id) = opt.target { return (id, opt.label) }
                return nil
            }
        )
        #expect(byId[AgentEngineKind.claudeCode.rawValue] == "Claude")
        #expect(byId[AgentEngineKind.codex.rawValue] == "Codex")
        #expect(byId[AgentEngineKind.openCode.rawValue] == "opencode")
    }

    @Test("每项都有非空 label + systemImage(渲染不崩)")
    func allOptionsHaveDisplay() {
        let cfg = MinimalAppDelegate.replyConfiguration(for: makeDefaults())
        for opt in cfg.options {
            #expect(!opt.label.isEmpty)
            #expect(!opt.systemImage.isEmpty)
        }
    }
}
