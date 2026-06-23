import Foundation
import Testing
@testable import App
@testable import Orchestrator

@Suite("AppBootstrap.reloadLLMProvider — hot reload after settings save")
struct AppBootstrapReloadTests {
    private static let kBaseURL = LLMSettingsKeys.openAIBaseURL
    private static let kModel = LLMSettingsKeys.openAIModel
    private static let kAPIKey = LLMSettingsKeys.openAIApiKey

    /// Build an isolated UserDefaults suite per test so writes don't leak
    /// between tests or into `.standard`.
    private func makeUserDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "AppBootstrapReloadTests.\(name).\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        return ud
    }

    @Test("Default state (no key, no UD) → box.current stays nil after reload")
    func reloadWithoutConfigClearsBox() async throws {
        let box = LLMProviderBox()
        let ud = makeUserDefaults()

        await AppBootstrap.reloadLLMProvider(
            into: box,
            userDefaults: ud
        )

        let current = await box.current
        #expect(current == nil)
    }

    @Test("Writing API key then reloading → box.current becomes non-nil")
    func reloadAfterKeyWritePopulatesBox() async throws {
        let box = LLMProviderBox()
        let ud = makeUserDefaults()

        ud.set("sk-test-12345", forKey: Self.kAPIKey)

        await AppBootstrap.reloadLLMProvider(
            into: box,
            userDefaults: ud
        )

        let current = await box.current
        #expect(current != nil, "Box should contain a provider after key is written")
    }

    @Test("Removing API key then reloading → box.current goes back to nil (default endpoint)")
    func reloadAfterKeyRemovalClearsBox() async throws {
        let box = LLMProviderBox()
        let ud = makeUserDefaults()

        ud.set("sk-test", forKey: Self.kAPIKey)
        await AppBootstrap.reloadLLMProvider(into: box, userDefaults: ud)
        #expect(await box.current != nil)

        ud.removeObject(forKey: Self.kAPIKey)
        await AppBootstrap.reloadLLMProvider(into: box, userDefaults: ud)

        let current = await box.current
        #expect(current == nil)
    }

    @Test("Custom baseURL + no key (Ollama path) → reload populates box")
    func reloadCustomBaseURLNoKey() async throws {
        let box = LLMProviderBox()
        let ud = makeUserDefaults()

        ud.set("http://localhost:11434/v1", forKey: Self.kBaseURL)
        ud.set("llama3", forKey: Self.kModel)

        await AppBootstrap.reloadLLMProvider(
            into: box,
            userDefaults: ud
        )

        let current = await box.current
        #expect(current != nil, "Custom (non-OpenAI) endpoint should instantiate a provider even without a key")
    }

    @Test("Reload is idempotent — calling twice yields the same nil/non-nil state")
    func reloadIsIdempotent() async throws {
        let box = LLMProviderBox()
        let ud = makeUserDefaults()

        ud.set("sk-test", forKey: Self.kAPIKey)
        await AppBootstrap.reloadLLMProvider(into: box, userDefaults: ud)
        let firstNonNil = await box.current != nil

        await AppBootstrap.reloadLLMProvider(into: box, userDefaults: ud)
        let secondNonNil = await box.current != nil

        #expect(firstNonNil == secondNonNil)
        #expect(secondNonNil == true)
    }
}
