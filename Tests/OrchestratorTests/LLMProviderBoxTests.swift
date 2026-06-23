import Foundation
import Testing
@testable import Orchestrator

private actor StubProvider: LLMProvider {
    let id: String
    init(_ id: String) { self.id = id }
    func chat(_ messages: [LLMMessage]) async throws -> String { id }
}

@Suite("LLMProviderBox")
struct LLMProviderBoxTests {
    @Test("Default init starts with nil current")
    func defaultInitIsNil() async {
        let box = LLMProviderBox()
        let current = await box.current
        #expect(current == nil)
    }

    @Test("Init with initial provider exposes it via current")
    func initWithProvider() async throws {
        let provider = StubProvider("alpha")
        let box = LLMProviderBox(provider)
        let current = await box.current
        let reply = try await #require(current).chat([])
        #expect(reply == "alpha")
    }

    @Test("set replaces the current provider")
    func setReplaces() async throws {
        let box = LLMProviderBox(StubProvider("first"))
        await box.set(StubProvider("second"))
        let reply = try await #require(await box.current).chat([])
        #expect(reply == "second")
    }

    @Test("set to nil clears the current provider")
    func setToNilClears() async {
        let box = LLMProviderBox(StubProvider("alpha"))
        await box.set(nil)
        let current = await box.current
        #expect(current == nil)
    }
}
