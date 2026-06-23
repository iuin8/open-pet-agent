import Foundation
import Testing
@testable import App
@testable import Orchestrator

// MARK: - LLMProviderKind routing tests
//
// Verifies that UserDefaults["LLMProvider"] correctly routes resolveLLMProvider
// to the right concrete provider type and that the apiKey namespaces are isolated.

@Suite("LLMProviderKind routing")
struct LLMProviderKindRoutingTests {

    // MARK: - Helpers

    private func makeUserDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "LLMProviderKindRoutingTests.\(name).\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        return ud
    }

    // MARK: - LLMProviderKind.resolve tests

    @Test("UserDefaults key absent → kind defaults to openAICompatible")
    func absentKeyDefaultsToOpenAICompatible() {
        let ud = makeUserDefaults()
        // key not set
        let kind = LLMProviderKind.resolve(from: ud)
        #expect(kind == .openAICompatible)
    }

    @Test("UserDefaults key = 'anthropic' → kind is anthropic")
    func anthropicStringResolvesToAnthropicKind() {
        let ud = makeUserDefaults()
        ud.set("anthropic", forKey: LLMProviderKind.userDefaultsKey)
        let kind = LLMProviderKind.resolve(from: ud)
        #expect(kind == .anthropic)
    }

    @Test("UserDefaults key = 'openAICompatible' → kind is openAICompatible")
    func openAICompatibleStringResolvesToOpenAICompatibleKind() {
        let ud = makeUserDefaults()
        ud.set("openAICompatible", forKey: LLMProviderKind.userDefaultsKey)
        let kind = LLMProviderKind.resolve(from: ud)
        #expect(kind == .openAICompatible)
    }

    @Test("Invalid UserDefaults value falls back to openAICompatible")
    func invalidValueFallsBackToOpenAICompatible() {
        let ud = makeUserDefaults()
        ud.set("gemini", forKey: LLMProviderKind.userDefaultsKey)
        let kind = LLMProviderKind.resolve(from: ud)
        #expect(kind == .openAICompatible)
    }

    // MARK: - resolveLLMProvider routing

    @Test("No UserDefaults key + no apiKey → nil provider (openAI default endpoint, no key)")
    func noConfigNilProvider() {
        let ud = makeUserDefaults()

        let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)

        #expect(provider == nil)
    }

    @Test("kind=anthropic + AnthropicAPIKey in UserDefaults → non-nil AnthropicProvider")
    func anthropicKindPlusKeyProducesAnthropicProvider() throws {
        let ud = makeUserDefaults()
        ud.set("anthropic", forKey: LLMProviderKind.userDefaultsKey)
        ud.set("sk-ant-test-key", forKey: LLMSettingsKeys.anthropicApiKey)

        let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)

        #expect(provider != nil)
        // We can verify the type via the module-qualified name
        #expect(provider is AnthropicProvider)
    }

    @Test("kind=anthropic + NO AnthropicAPIKey → nil provider")
    func anthropicKindWithoutKeyReturnsNil() {
        let ud = makeUserDefaults()
        ud.set("anthropic", forKey: LLMProviderKind.userDefaultsKey)

        let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)

        #expect(provider == nil)
    }

    @Test("kind=openAICompatible + OpenAIAPIKey in UserDefaults → non-nil OpenAIProvider")
    func openAICompatibleKindPlusKeyProducesOpenAIProvider() throws {
        let ud = makeUserDefaults()
        ud.set("openAICompatible", forKey: LLMProviderKind.userDefaultsKey)
        ud.set("sk-test-key", forKey: LLMSettingsKeys.openAIApiKey)

        let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)

        #expect(provider != nil)
        #expect(provider is OpenAIProvider)
    }

    @Test("Anthropic key does not leak into OpenAI path (key namespaces are isolated)")
    func keyNamespacesAreIsolated() throws {
        let ud = makeUserDefaults()
        // Kind is openAICompatible (default)
        // Only anthropic key is written; openai key is absent
        ud.set("sk-ant-test", forKey: LLMSettingsKeys.anthropicApiKey)

        let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)

        // OpenAI-compatible path should NOT use AnthropicAPIKey → nil (default endpoint, no OpenAIAPIKey)
        #expect(provider == nil)
    }

    @Test("Switching kind from anthropic back to openAICompatible uses openai key, not anthropic key")
    func switchingKindUsesCorrectKey() throws {
        let ud = makeUserDefaults()
        // Both keys are in UserDefaults
        ud.set("sk-ant-test", forKey: LLMSettingsKeys.anthropicApiKey)
        ud.set("sk-test", forKey: LLMSettingsKeys.openAIApiKey)

        ud.set("openAICompatible", forKey: LLMProviderKind.userDefaultsKey)
        let provider = AppBootstrap.resolveLLMProvider(userDefaults: ud)

        #expect(provider is OpenAIProvider)
    }
}
