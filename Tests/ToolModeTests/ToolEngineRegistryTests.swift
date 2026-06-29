import Foundation
import Testing
@testable import ToolMode

// MARK: - ToolEngineRegistry tests
//
// P0 工具层注册表化:验证 id 字符串路由(取代写死 enum switch)+ 三个内置 entry
// 的 makeEngine 构造 + binaryName / displayName / 能力声明。覆盖 all / lookup /
// resolve / fallback / capabilities + makeEngine 反推 kind(含 opencode 兜底)。
// 与灵魂层 `SoulBackendRegistryTests` 同构。

@Suite("ToolEngineRegistry")
struct ToolEngineRegistryTests {

    // MARK: - Helpers

    private func makeUserDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "ToolEngineRegistryTests.\(name).\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        return ud
    }

    // MARK: - all / 内置 entry 清单

    @Test("all 含三个内置 engine,顺序固定,all[0] 是 claudeCode(fallback)")
    func allContainsThreeEnginesInOrder() {
        let ids = ToolEngineRegistry.all.map(\.id)
        #expect(ids == ["claudeCode", "codex", "openCode"])
        #expect(ToolEngineRegistry.all[0].id == ToolEngineKind.claudeCode.rawValue)
    }

    @Test("entry id 与 ToolEngineKind rawValue 对齐(零迁移)")
    func entryIDsAlignWithToolEngineKind() {
        #expect(ToolEngineRegistry.claudeCode.id == ToolEngineKind.claudeCode.rawValue)
        #expect(ToolEngineRegistry.codex.id == ToolEngineKind.codex.rawValue)
        #expect(ToolEngineRegistry.openCode.id == ToolEngineKind.openCode.rawValue)
    }

    @Test("all 穷尽 ToolEngineKind.allCases —— 加 case 忘加 entry 会被这条挡住")
    func allCoversEveryToolEngineKind() {
        // 防 P2 同类失败模式「加了 enum case 却没往 registry 加 entry → resolve
        // 静默 fallback claudeCode、吞掉新 engine」。registry.all 的 id 集合必须
        // 与 ToolEngineKind.allCases 的 rawValue 集合完全一致(双向:不缺不多)。
        #expect(Set(ToolEngineRegistry.all.map(\.id)) == Set(ToolEngineKind.allCases.map(\.rawValue)))
    }

    @Test("entry displayName / binaryName 是预期字面值")
    func entryDisplayAndBinaryNames() {
        #expect(ToolEngineRegistry.claudeCode.displayName == "Claude Code")
        #expect(ToolEngineRegistry.claudeCode.binaryName == "claude")
        #expect(ToolEngineRegistry.codex.displayName == "Codex")
        #expect(ToolEngineRegistry.codex.binaryName == "codex")
        #expect(ToolEngineRegistry.openCode.displayName == "opencode")
        #expect(ToolEngineRegistry.openCode.binaryName == "opencode")
    }

    // MARK: - capabilities(能力闸)

    @Test("capabilities: claude/codex 需 CLI、codex 带视觉、opencode 可 bundle")
    func capabilitiesPerEntry() {
        #expect(ToolEngineRegistry.claudeCode.capabilities.contains(.requiresCLI))
        #expect(!ToolEngineRegistry.claudeCode.capabilities.contains(.bundleable))

        #expect(ToolEngineRegistry.codex.capabilities.contains(.requiresCLI))
        #expect(ToolEngineRegistry.codex.capabilities.contains(.nativeVision))

        #expect(ToolEngineRegistry.openCode.capabilities.contains(.bundleable))
        #expect(!ToolEngineRegistry.openCode.capabilities.contains(.requiresCLI))
    }

    // MARK: - lookup

    @Test("lookup 已知 id → 对应 entry")
    func lookupKnownIDs() {
        #expect(ToolEngineRegistry.lookup(id: "claudeCode")?.id == "claudeCode")
        #expect(ToolEngineRegistry.lookup(id: "codex")?.id == "codex")
        #expect(ToolEngineRegistry.lookup(id: "openCode")?.id == "openCode")
    }

    @Test("lookup 未知 id → nil")
    func lookupUnknownIDReturnsNil() {
        #expect(ToolEngineRegistry.lookup(id: "gemini") == nil)
        #expect(ToolEngineRegistry.lookup(id: "") == nil)
    }

    // MARK: - resolve(from:) + fallback

    @Test("resolve: key 缺失 → fallback all[0](claudeCode)")
    func resolveAbsentKeyFallsBackToFirst() {
        let ud = makeUserDefaults()
        #expect(ToolEngineRegistry.resolve(from: ud).id == "claudeCode")
    }

    @Test("resolve: key='codex' → codex entry")
    func resolveCodex() {
        let ud = makeUserDefaults()
        ud.set("codex", forKey: ToolEngineKind.userDefaultsKey)
        #expect(ToolEngineRegistry.resolve(from: ud).id == "codex")
    }

    @Test("resolve: key='openCode' → openCode entry")
    func resolveOpenCode() {
        let ud = makeUserDefaults()
        ud.set("openCode", forKey: ToolEngineKind.userDefaultsKey)
        #expect(ToolEngineRegistry.resolve(from: ud).id == "openCode")
    }

    @Test("resolve: 未知 id → fallback claudeCode")
    func resolveUnknownIDFallsBack() {
        let ud = makeUserDefaults()
        ud.set("does-not-exist", forKey: ToolEngineKind.userDefaultsKey)
        #expect(ToolEngineRegistry.resolve(from: ud).id == "claudeCode")
    }

    // MARK: - makeEngine → 反推 kind

    @Test("makeEngine: claudeCode entry 造出 .claudeCode engine")
    func makeEngineClaudeCode() {
        let engine = ToolEngineRegistry.claudeCode.makeEngine()
        #expect(type(of: engine).kind == .claudeCode)
    }

    @Test("makeEngine: codex entry 造出 .codex engine")
    func makeEngineCodex() {
        let engine = ToolEngineRegistry.codex.makeEngine()
        #expect(type(of: engine).kind == .codex)
    }

    @Test("makeEngine: openCode entry 当前兜底到 .claudeCode engine(N3.x 前)")
    func makeEngineOpenCodeFallsBackToClaude() {
        // bundled opencode runtime 接入前,opencode entry 暂用 ClaudeCodeEngine
        // 兜底(与旧 switch 行为一致);N3.x 换成真 OpenCodeEngine 时改此断言。
        let engine = ToolEngineRegistry.openCode.makeEngine()
        #expect(type(of: engine).kind == .claudeCode)
    }
}
