import Foundation
import Testing
@testable import AgentMode

// MARK: - AgentEngineRegistry tests
//
// P0 工具层注册表化:验证 id 字符串路由(取代写死 enum switch)+ 三个内置 entry
// 的 makeEngine 构造 + binaryName / displayName / 能力声明。覆盖 all / lookup /
// resolve / fallback / capabilities + makeEngine 反推 kind(含 opencode 兜底)。
// 与灵魂层 `SoulBackendRegistryTests` 同构。

@Suite("AgentEngineRegistry")
struct AgentEngineRegistryTests {

    // MARK: - Helpers

    private func makeUserDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "AgentEngineRegistryTests.\(name).\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        return ud
    }

    // MARK: - all / 内置 entry 清单

    @Test("all 含三个内置 engine,顺序固定,all[0] 是 claudeCode(fallback)")
    func allContainsThreeEnginesInOrder() {
        let ids = AgentEngineRegistry.all.map(\.id)
        #expect(ids == ["claudeCode", "codex", "openCode"])
        #expect(AgentEngineRegistry.all[0].id == AgentEngineKind.claudeCode.rawValue)
    }

    @Test("entry id 与 AgentEngineKind rawValue 对齐(零迁移)")
    func entryIDsAlignWithAgentEngineKind() {
        #expect(AgentEngineRegistry.claudeCode.id == AgentEngineKind.claudeCode.rawValue)
        #expect(AgentEngineRegistry.codex.id == AgentEngineKind.codex.rawValue)
        #expect(AgentEngineRegistry.openCode.id == AgentEngineKind.openCode.rawValue)
    }

    @Test("all 穷尽 AgentEngineKind.allCases —— 加 case 忘加 entry 会被这条挡住")
    func allCoversEveryAgentEngineKind() {
        // 防 P2 同类失败模式「加了 enum case 却没往 registry 加 entry → resolve
        // 静默 fallback claudeCode、吞掉新 engine」。registry.all 的 id 集合必须
        // 与 AgentEngineKind.allCases 的 rawValue 集合完全一致(双向:不缺不多)。
        #expect(Set(AgentEngineRegistry.all.map(\.id)) == Set(AgentEngineKind.allCases.map(\.rawValue)))
    }

    @Test("entry displayName / binaryName 是预期字面值")
    func entryDisplayAndBinaryNames() {
        #expect(AgentEngineRegistry.claudeCode.displayName == "Claude Code")
        #expect(AgentEngineRegistry.claudeCode.binaryName == "claude")
        #expect(AgentEngineRegistry.codex.displayName == "Codex")
        #expect(AgentEngineRegistry.codex.binaryName == "codex")
        #expect(AgentEngineRegistry.openCode.displayName == "opencode")
        #expect(AgentEngineRegistry.openCode.binaryName == "opencode")
    }

    // MARK: - capabilities(能力闸)

    @Test("capabilities: claude/codex 需 CLI、codex 带视觉、opencode 可 bundle")
    func capabilitiesPerEntry() {
        #expect(AgentEngineRegistry.claudeCode.capabilities.contains(.requiresCLI))
        #expect(!AgentEngineRegistry.claudeCode.capabilities.contains(.bundleable))

        #expect(AgentEngineRegistry.codex.capabilities.contains(.requiresCLI))
        #expect(AgentEngineRegistry.codex.capabilities.contains(.nativeVision))

        #expect(AgentEngineRegistry.openCode.capabilities.contains(.bundleable))
        #expect(!AgentEngineRegistry.openCode.capabilities.contains(.requiresCLI))
    }

    // MARK: - lookup

    @Test("lookup 已知 id → 对应 entry")
    func lookupKnownIDs() {
        #expect(AgentEngineRegistry.lookup(id: "claudeCode")?.id == "claudeCode")
        #expect(AgentEngineRegistry.lookup(id: "codex")?.id == "codex")
        #expect(AgentEngineRegistry.lookup(id: "openCode")?.id == "openCode")
    }

    @Test("lookup 未知 id → nil")
    func lookupUnknownIDReturnsNil() {
        #expect(AgentEngineRegistry.lookup(id: "gemini") == nil)
        #expect(AgentEngineRegistry.lookup(id: "") == nil)
    }

    // MARK: - resolve(from:) + fallback

    @Test("resolve: key 缺失 → fallback all[0](claudeCode)")
    func resolveAbsentKeyFallsBackToFirst() {
        let ud = makeUserDefaults()
        #expect(AgentEngineRegistry.resolve(from: ud).id == "claudeCode")
    }

    @Test("resolve: key='codex' → codex entry")
    func resolveCodex() {
        let ud = makeUserDefaults()
        ud.set("codex", forKey: AgentEngineKind.userDefaultsKey)
        #expect(AgentEngineRegistry.resolve(from: ud).id == "codex")
    }

    @Test("resolve: key='openCode' → openCode entry")
    func resolveOpenCode() {
        let ud = makeUserDefaults()
        ud.set("openCode", forKey: AgentEngineKind.userDefaultsKey)
        #expect(AgentEngineRegistry.resolve(from: ud).id == "openCode")
    }

    @Test("resolve: 未知 id → fallback claudeCode")
    func resolveUnknownIDFallsBack() {
        let ud = makeUserDefaults()
        ud.set("does-not-exist", forKey: AgentEngineKind.userDefaultsKey)
        #expect(AgentEngineRegistry.resolve(from: ud).id == "claudeCode")
    }

    // MARK: - makeEngine → 反推 kind

    @Test("makeEngine: claudeCode entry 造出 .claudeCode engine")
    func makeEngineClaudeCode() {
        let engine = AgentEngineRegistry.claudeCode.makeEngine()
        #expect(type(of: engine).kind == .claudeCode)
    }

    @Test("makeEngine: codex entry 造出 .codex engine")
    func makeEngineCodex() {
        let engine = AgentEngineRegistry.codex.makeEngine()
        #expect(type(of: engine).kind == .codex)
    }

    @Test("makeEngine: openCode entry 当前兜底到 .claudeCode engine(N3.x 前)")
    func makeEngineOpenCodeFallsBackToClaude() {
        // bundled opencode runtime 接入前,opencode entry 暂用 ClaudeCodeEngine
        // 兜底(与旧 switch 行为一致);N3.x 换成真 OpenCodeEngine 时改此断言。
        let engine = AgentEngineRegistry.openCode.makeEngine()
        #expect(type(of: engine).kind == .claudeCode)
    }
}
