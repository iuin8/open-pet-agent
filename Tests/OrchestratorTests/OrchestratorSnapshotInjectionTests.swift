import Testing
import Foundation
@testable import Orchestrator
import Context
import Rendering

// MARK: - Stubs (local to this file)

private actor RecordingProvider: LLMProvider {
    private(set) var receivedMessageBatches: [[LLMMessage]] = []
    let response: String

    init(response: String = "ok") {
        self.response = response
    }

    func chat(_ messages: [LLMMessage]) async throws -> String {
        receivedMessageBatches.append(messages)
        return response
    }

    var lastSystemPrompt: String? {
        receivedMessageBatches.last?.first(where: { $0.role == .system })?.content
    }
}

private func makeTmpURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("snap-inject-\(UUID().uuidString).json")
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func makeStore() async throws -> (ConversationStore, URL) {
    let url = makeTmpURL()
    let store = ConversationStore(storeURL: url)
    try await store.load()
    return (store, url)
}

// MARK: - Suite

@Suite("CompanionOrchestrator snapshot injection")
struct OrchestratorSnapshotInjectionTests {

    // MARK: 1. snapshot + pet → system prompt contains [Desktop Context]

    @Test("reply with snapshot and pet builds system prompt with [Desktop Context]")
    func replyWithSnapshotAndPetBuildsContextBlock() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let snapshot = DesktopSnapshot(
            displays: [DisplaySnapshot(id: 0, width: 1440, height: 900)],
            cursorPosition: Point(x: 720, y: 450),
            visibleApplicationName: "TextEdit"
        )
        let pet = PetContext(behavior: .idle, isSnowEnabled: false)
        let provider = RecordingProvider()

        let box = LiveContextBox()
        await box.setSnapshotProvider { snapshot }
        await box.setPetContextProvider { pet }

        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store,
            liveContextBox: box
        )

        _ = await orchestrator.reply(to: "hello")

        let systemPrompt = await provider.lastSystemPrompt
        #expect(systemPrompt != nil)
        #expect(systemPrompt!.contains("[Desktop Context]"))
        #expect(systemPrompt!.contains("TextEdit"))
    }

    // MARK: 2. nil providers → system prompt is base prompt only

    @Test("nil providers produce base-only system prompt")
    func nilProvidersProduceBaseOnlyPrompt() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let provider = RecordingProvider()
        let box = LiveContextBox() // no setters called

        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store,
            liveContextBox: box
        )

        _ = await orchestrator.reply(to: "hello")

        let systemPrompt = await provider.lastSystemPrompt
        #expect(systemPrompt != nil)
        #expect(!systemPrompt!.contains("[Desktop Context]"))
        #expect(systemPrompt!.contains("OpenPetAgent"))
    }

    // MARK: 3. snapshot only, pet nil → partial block

    @Test("snapshot set but petContext nil produces partial [Desktop Context] block")
    func snapshotOnlyProducesPartialBlock() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let snapshot = DesktopSnapshot(
            displays: [DisplaySnapshot(id: 0, width: 1440, height: 900)],
            cursorPosition: Point(x: 100, y: 800),
            visibleApplicationName: "Terminal"
        )
        let provider = RecordingProvider()
        let box = LiveContextBox()
        await box.setSnapshotProvider { snapshot }
        // petContextProvider NOT set

        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store,
            liveContextBox: box
        )

        _ = await orchestrator.reply(to: "test")

        let systemPrompt = await provider.lastSystemPrompt
        #expect(systemPrompt != nil)
        #expect(systemPrompt!.contains("[Desktop Context]"))
        #expect(systemPrompt!.contains("Terminal"))
        #expect(!systemPrompt!.contains("桌宠状态"))
        #expect(!systemPrompt!.contains("雪景模式"))
    }

    // MARK: 4. snapshot + pet → full block (complete path)

    @Test("full snapshot and pet produces complete [Desktop Context] block")
    func fullSnapshotAndPetProducesCompleteBlock() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let snapshot = DesktopSnapshot(
            displays: [
                DisplaySnapshot(id: 0, width: 2560, height: 1440),
                DisplaySnapshot(id: 1, width: 1920, height: 1080)
            ],
            cursorPosition: Point(x: 500, y: 1200),
            visibleApplicationName: "Xcode"
        )
        let pet = PetContext(behavior: .snowing, isSnowEnabled: true)
        let provider = RecordingProvider()
        let box = LiveContextBox()
        await box.setSnapshotProvider { snapshot }
        await box.setPetContextProvider { pet }

        let orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            conversationStore: store,
            liveContextBox: box
        )

        _ = await orchestrator.reply(to: "what are you doing")

        let systemPrompt = await provider.lastSystemPrompt
        #expect(systemPrompt != nil)
        let p = systemPrompt!
        #expect(p.contains("[Desktop Context]"))
        #expect(p.contains("Xcode"))
        #expect(p.contains("桌宠状态"))
        #expect(p.contains("雪景模式"))
        // 2 displays
        #expect(p.contains("2"))
    }
}
