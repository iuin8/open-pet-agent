import Foundation
import Testing
@testable import Orchestrator

private actor TaggedProvider: LLMProvider {
    let tag: String
    init(_ tag: String) { self.tag = tag }
    func chat(_ messages: [LLMMessage]) async throws -> String { tag }
}

@Suite("CompanionOrchestrator hot-reload via LLMProviderBox")
struct CompanionOrchestratorHotReloadTests {
    @Test("Initial reply uses the provider currently in the box")
    func usesBoxedProvider() async {
        let box = LLMProviderBox(TaggedProvider("v1"))
        let orchestrator = CompanionOrchestrator(llmProviderBox: box)
        let reply = await orchestrator.reply(to: "hello")
        #expect(reply == "v1")
    }

    @Test("After box.set(new), next reply uses the new provider — no re-init")
    func swapProviderMidLife() async {
        let box = LLMProviderBox(TaggedProvider("old"))
        let orchestrator = CompanionOrchestrator(llmProviderBox: box)

        let first = await orchestrator.reply(to: "msg1")
        #expect(first == "old")

        await box.set(TaggedProvider("new"))

        let second = await orchestrator.reply(to: "msg2")
        #expect(second == "new")
    }

    @Test("After box.set(nil), reply falls back to echo path")
    func clearProviderFallsBackToEcho() async {
        let box = LLMProviderBox(TaggedProvider("alpha"))
        let orchestrator = CompanionOrchestrator(llmProviderBox: box)

        await box.set(nil)

        let reply = await orchestrator.reply(to: "ping")
        #expect(reply.contains("ping"))
        #expect(reply != "alpha")
    }

    @Test("Legacy init(llmProvider:) wraps into a box that is still hot-swappable")
    func legacyInitExposesBox() async {
        let orchestrator = CompanionOrchestrator(llmProvider: TaggedProvider("legacy"))

        let first = await orchestrator.reply(to: "msg")
        #expect(first == "legacy")

        await orchestrator.llmProviderBox.set(TaggedProvider("upgraded"))

        let second = await orchestrator.reply(to: "msg")
        #expect(second == "upgraded")
    }
}
