import Foundation
import Testing
@testable import App
@testable import Orchestrator

// MARK: - SoulBackendRegistry tests
//
// P2 灵魂层后端注册表化:验证 id 字符串路由(取代写死 enum switch)+ 三个内置
// entry 的 makeProvider 构造 + openclaw 专属槽 + 能力声明。覆盖 resolve / lookup /
// fallback / capabilities + 三 entry makeProvider(含 openclaw 空槽返回 nil)。

@Suite("SoulBackendRegistry")
struct SoulBackendRegistryTests {

    // MARK: - Helpers

    private func makeUserDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "SoulBackendRegistryTests.\(name).\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        return ud
    }

    // MARK: - all / 内置 entry 清单

    @Test("all 含三个内置后端,顺序固定,all[0] 是 openAICompatible(fallback)")
    func allContainsThreeBackendsInOrder() {
        let ids = SoulBackendRegistry.all.map(\.id)
        #expect(ids == ["openAICompatible", "anthropic", "openclaw"])
        #expect(SoulBackendRegistry.all[0].id == LLMProviderKind.openAICompatible.rawValue)
    }

    @Test("entry id 与 LLMProviderKind rawValue 对齐(零迁移)")
    func entryIDsAlignWithLLMProviderKind() {
        #expect(SoulBackendRegistry.openAICompatible.id == LLMProviderKind.openAICompatible.rawValue)
        #expect(SoulBackendRegistry.anthropic.id == LLMProviderKind.anthropic.rawValue)
        #expect(SoulBackendRegistry.openclaw.id == "openclaw")
    }

    // MARK: - lookup

    @Test("lookup 已知 id → 对应 entry")
    func lookupKnownIDs() {
        #expect(SoulBackendRegistry.lookup(id: "openAICompatible")?.id == "openAICompatible")
        #expect(SoulBackendRegistry.lookup(id: "anthropic")?.id == "anthropic")
        #expect(SoulBackendRegistry.lookup(id: "openclaw")?.id == "openclaw")
    }

    @Test("lookup 未知 id → nil")
    func lookupUnknownIDReturnsNil() {
        #expect(SoulBackendRegistry.lookup(id: "gemini") == nil)
        #expect(SoulBackendRegistry.lookup(id: "") == nil)
    }

    // MARK: - resolve(from:) + fallback

    @Test("resolve: key 缺失 → fallback all[0](openAICompatible)")
    func resolveAbsentKeyFallsBackToFirst() {
        let ud = makeUserDefaults()
        #expect(SoulBackendRegistry.resolve(from: ud).id == "openAICompatible")
    }

    @Test("resolve: key='anthropic' → anthropic entry")
    func resolveAnthropic() {
        let ud = makeUserDefaults()
        ud.set("anthropic", forKey: LLMProviderKind.userDefaultsKey)
        #expect(SoulBackendRegistry.resolve(from: ud).id == "anthropic")
    }

    @Test("resolve: key='openclaw' → openclaw entry")
    func resolveOpenClaw() {
        let ud = makeUserDefaults()
        ud.set("openclaw", forKey: LLMProviderKind.userDefaultsKey)
        #expect(SoulBackendRegistry.resolve(from: ud).id == "openclaw")
    }

    @Test("resolve: 无法识别的值 → fallback all[0]")
    func resolveInvalidValueFallsBack() {
        let ud = makeUserDefaults()
        ud.set("gemini", forKey: LLMProviderKind.userDefaultsKey)
        #expect(SoulBackendRegistry.resolve(from: ud).id == "openAICompatible")
    }

    // MARK: - capabilities

    @Test("能力声明:云后端 cloudHosted;openclaw 本地网关 + 原生记忆/人格")
    func capabilitiesDeclared() {
        #expect(SoulBackendRegistry.openAICompatible.capabilities.contains(.cloudHosted))
        #expect(SoulBackendRegistry.anthropic.capabilities.contains(.cloudHosted))
        #expect(SoulBackendRegistry.openclaw.capabilities.contains(.localGateway))
        #expect(SoulBackendRegistry.openclaw.capabilities.contains(.nativeMemory))
        #expect(SoulBackendRegistry.openclaw.capabilities.contains(.nativePersona))
        // openclaw 不是云托管,也不可 bundle。
        #expect(SoulBackendRegistry.openclaw.capabilities.contains(.cloudHosted) == false)
        #expect(SoulBackendRegistry.openclaw.capabilities.contains(.bundleable) == false)
    }

    // MARK: - picker info(设置面板展示 / 槽位映射,Settings 层不写死类型分支)

    @Test("picker:云后端声明三槽(读写用)+ 标签/占位,isManaged=false")
    func cloudBackendsDeclarePickerSlots() {
        let openAI = SoulBackendRegistry.openAICompatible.picker
        #expect(openAI.apiKeySlot == LLMSettingsKeys.openAIApiKey)
        #expect(openAI.baseURLSlot == LLMSettingsKeys.openAIBaseURL)
        #expect(openAI.modelSlot == LLMSettingsKeys.openAIModel)
        #expect(openAI.keyLabel == "OpenAI Key")
        #expect(openAI.isManaged == false)

        let anthropic = SoulBackendRegistry.anthropic.picker
        #expect(anthropic.apiKeySlot == LLMSettingsKeys.anthropicApiKey)
        #expect(anthropic.baseURLSlot == LLMSettingsKeys.anthropicBaseURL)
        #expect(anthropic.modelSlot == LLMSettingsKeys.anthropicModel)
        #expect(anthropic.keyLabel == "Anthropic Key")
        #expect(anthropic.baseURLPlaceholder == "https://api.anthropic.com")
        #expect(anthropic.isManaged == false)
    }

    @Test("picker:openclaw 三槽 nil → isManaged=true(自动管理,picker 隐藏字段)+ 有说明文案")
    func openClawPickerIsManaged() {
        let p = SoulBackendRegistry.openclaw.picker
        #expect(p.apiKeySlot == nil)
        #expect(p.baseURLSlot == nil)
        #expect(p.modelSlot == nil)
        #expect(p.isManaged == true)
        #expect(p.managedNote.isEmpty == false)
    }

    // MARK: - makeProvider:openAICompatible entry

    @Test("openAICompatible entry: 有 OpenAIAPIKey → OpenAIProvider;无 → nil")
    func openAICompatibleMakeProvider() {
        let withKey = makeUserDefaults()
        withKey.set("sk-test-key", forKey: LLMSettingsKeys.openAIApiKey)
        #expect(SoulBackendRegistry.openAICompatible.makeProvider(withKey) is OpenAIProvider)

        let empty = makeUserDefaults()
        #expect(SoulBackendRegistry.openAICompatible.makeProvider(empty) == nil)
    }

    // MARK: - makeProvider:anthropic entry

    @Test("anthropic entry: 有 AnthropicAPIKey → AnthropicProvider;无 → nil")
    func anthropicMakeProvider() {
        let withKey = makeUserDefaults()
        withKey.set("sk-ant-test", forKey: LLMSettingsKeys.anthropicApiKey)
        #expect(SoulBackendRegistry.anthropic.makeProvider(withKey) is AnthropicProvider)

        let empty = makeUserDefaults()
        #expect(SoulBackendRegistry.anthropic.makeProvider(empty) == nil)
    }

    // MARK: - makeProvider:openclaw entry(专属槽)

    @Test("openclaw entry: 有 OpenClawBaseURL → OpenAIProvider(底层复用)")
    func openClawMakeProviderWithSlot() {
        let ud = makeUserDefaults()
        ud.set("http://localhost:18789/v1", forKey: LLMSettingsKeys.openClawBaseURL)
        ud.set("tok-abc", forKey: LLMSettingsKeys.openClawToken)
        #expect(SoulBackendRegistry.openclaw.makeProvider(ud) is OpenAIProvider)
    }

    @Test("openclaw entry: 专属槽空 → nil(没 bootstrap / 没装)")
    func openClawMakeProviderEmptySlotReturnsNil() {
        let empty = makeUserDefaults()
        #expect(SoulBackendRegistry.openclaw.makeProvider(empty) == nil)
        // token 有但 baseURL 空 → 仍 nil(baseURL 是必需)。
        let tokenOnly = makeUserDefaults()
        tokenOnly.set("tok-abc", forKey: LLMSettingsKeys.openClawToken)
        #expect(SoulBackendRegistry.openclaw.makeProvider(tokenOnly) == nil)
    }

    // MARK: - 端到端:resolveLLMProvider 经 registry 路由到 openclaw

    @Test("resolveLLMProvider: LLMProvider=openclaw + 专属槽 → OpenAIProvider(走 registry)")
    func resolveLLMProviderRoutesToOpenClaw() {
        let ud = makeUserDefaults()
        ud.set("openclaw", forKey: LLMProviderKind.userDefaultsKey)
        ud.set("http://localhost:18789/v1", forKey: LLMSettingsKeys.openClawBaseURL)
        ud.set("tok-abc", forKey: LLMSettingsKeys.openClawToken)
        #expect(AppBootstrap.resolveLLMProvider(userDefaults: ud) is OpenAIProvider)
    }

    @Test("resolveLLMProvider: LLMProvider=openclaw 但专属槽空 → nil(echo fallback)")
    func resolveLLMProviderOpenClawEmptySlotNil() {
        let ud = makeUserDefaults()
        ud.set("openclaw", forKey: LLMProviderKind.userDefaultsKey)
        #expect(AppBootstrap.resolveLLMProvider(userDefaults: ud) == nil)
    }
}
