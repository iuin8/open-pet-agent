import Testing
@testable import Orchestrator
import Context
import RuntimeBridge

// MARK: - Stub provider for orchestrator tests

private struct StubProvider: LLMProvider {
    let response: String

    func chat(_ messages: [LLMMessage]) async throws -> String {
        response
    }
}

private struct ThrowingProvider: LLMProvider {
    func chat(_ messages: [LLMMessage]) async throws -> String {
        throw LLMProviderError.httpError(status: 503, body: "service unavailable")
    }
}

private final class RecordingProvider: LLMProvider, @unchecked Sendable {
    private(set) var receivedMessages: [LLMMessage] = []
    let response: String

    init(response: String = "recorded response") {
        self.response = response
    }

    func chat(_ messages: [LLMMessage]) async throws -> String {
        receivedMessages = messages
        return response
    }
}

// MARK: - Echo (nil provider) tests — existing behaviour

@Test("Orchestrator returns a deterministic local chat reply")
func orchestratorReturnsDeterministicLocalChatReply() async throws {
    let reply = await CompanionOrchestrator().reply(to: "\u{4F60}\u{597D}")

    // “ = left double quotation mark, ” = right double quotation mark
    let expected = "\u{6211}\u{542C}\u{5230}\u{201C}\u{4F60}\u{597D}\u{201D}\u{4E86}\u{3002}"
    #expect(reply == expected)
}

@Test("Orchestrator bootstraps a deterministic first frame")
func orchestratorBootstrapsDeterministicFirstFrame() async throws {
    let snapshot = DesktopSnapshot(cursorPosition: Point(x: 55, y: 89))

    let bootstrap = try await CompanionOrchestrator().bootstrap(snapshot: snapshot)

    #expect(bootstrap.capabilities.version == "swift-local")
    #expect(bootstrap.initialRenderState.petPositionX == 55)
    #expect(bootstrap.initialRenderState.petPositionY == 89)
    #expect(bootstrap.initialRenderState.particleCount == 0)
    #expect(bootstrap.initialRenderState.contactCount == 0)
}

@Test("Orchestrator advances runtime ticks from the previous pet pose")
func orchestratorAdvancesRuntimeTicksFromPreviousPetPose() async throws {
    let orchestrator = CompanionOrchestrator()
    let bootstrap = try await orchestrator.bootstrap(
        snapshot: DesktopSnapshot(cursorPosition: Point(x: 0, y: 0))
    )

    let snowRenderState = RenderState(
        petPositionX: bootstrap.initialRenderState.petPositionX,
        petPositionY: bootstrap.initialRenderState.petPositionY,
        petRotation: bootstrap.initialRenderState.petRotation,
        particleCount: bootstrap.initialRenderState.particleCount,
        contactCount: bootstrap.initialRenderState.contactCount,
        isSnowEnabled: true
    )
    let renderState = try await orchestrator.tick(
        snapshot: DesktopSnapshot(cursorPosition: Point(x: 100, y: 0)),
        deltaTime: 0.5,
        previousRenderState: snowRenderState
    )

    #expect(renderState.isSnowEnabled)
    #expect(renderState.petPositionX == 80)
    #expect(renderState.petPositionY == 0)
}

@Test("Orchestrator stamps companion behavior on tick render state")
func orchestratorStampsCompanionBehaviorOnTickRenderState() async throws {
    let orchestrator = CompanionOrchestrator()
    let snowyPrevious = RenderState(
        petPositionX: 0,
        petPositionY: 0,
        petRotation: 0,
        particleCount: 5,
        contactCount: 0,
        isSnowEnabled: true
    )

    let nextState = try await orchestrator.tick(
        snapshot: DesktopSnapshot(cursorPosition: Point(x: 0, y: 0)),
        deltaTime: 1.0 / 60.0,
        previousRenderState: snowyPrevious
    )

    #expect(nextState.companionBehavior == .snowing)
}

@Test("Orchestrator surfaces window contacts in the initial render state")
func orchestratorSurfacesWindowContactsInInitialRenderState() async throws {
    let snapshot = DesktopSnapshot(
        cursorPosition: Point(x: 120, y: 80),
        visibleWindows: [
            // cursor inside
            VisibleWindowSnapshot(
                ownerName: "Finder",
                bounds: Rect(origin: Point(x: 100, y: 50), width: 200, height: 150)
            ),
            // cursor outside
            VisibleWindowSnapshot(
                ownerName: "Xcode",
                bounds: Rect(origin: Point(x: 500, y: 500), width: 100, height: 100)
            ),
            // cursor inside second eligible window
            VisibleWindowSnapshot(
                ownerName: "Safari",
                bounds: Rect(origin: Point(x: 50, y: 20), width: 300, height: 200)
            ),
        ]
    )

    let bootstrap = try await CompanionOrchestrator().bootstrap(snapshot: snapshot)

    #expect(bootstrap.initialRenderState.contactCount == 2)
}

// MARK: - LLM provider integration tests

@Test("Orchestrator with injected provider returns provider response")
func orchestratorWithInjectedProviderReturnsProviderResponse() async throws {
    let provider = StubProvider(response: "hello from LLM")
    let orchestrator = CompanionOrchestrator(llmProvider: provider)

    let reply = await orchestrator.reply(to: "hi there")

    #expect(reply == "hello from LLM")
}

@Test("Orchestrator with throwing provider falls back to echo")
func orchestratorWithThrowingProviderFallsBackToEcho() async throws {
    let provider = ThrowingProvider()
    let orchestrator = CompanionOrchestrator(llmProvider: provider)

    let reply = await orchestrator.reply(to: "\u{4F60}\u{597D}")

    let expected = "\u{6211}\u{542C}\u{5230}\u{201C}\u{4F60}\u{597D}\u{201D}\u{4E86}\u{3002}"
    #expect(reply == expected)
}

@Test("Orchestrator with nil provider uses echo path")
func orchestratorWithNilProviderUsesEchoPath() async throws {
    let orchestrator = CompanionOrchestrator(llmProvider: nil)

    let reply = await orchestrator.reply(to: "test message")

    let expected = "\u{6211}\u{542C}\u{5230}\u{201C}test message\u{201D}\u{4E86}\u{3002}"
    #expect(reply == expected)
}

@Test("Orchestrator sends system prompt as first message to provider")
func orchestratorSendsSystemPromptAsFirstMessageToProvider() async throws {
    let recorder = RecordingProvider()
    let orchestrator = CompanionOrchestrator(llmProvider: recorder)

    _ = await orchestrator.reply(to: "any message")

    #expect(recorder.receivedMessages.first?.role == .system)
    #expect(recorder.receivedMessages.first?.content.isEmpty == false)
}

@Test("Orchestrator sends user message as last message to provider")
func orchestratorSendsUserMessageAsLastMessageToProvider() async throws {
    let recorder = RecordingProvider()
    let orchestrator = CompanionOrchestrator(llmProvider: recorder)

    _ = await orchestrator.reply(to: "user input text")

    #expect(recorder.receivedMessages.last?.role == .user)
    #expect(recorder.receivedMessages.last?.content == "user input text")
}

@Test("Orchestrator sends exactly two messages to provider (system + user)")
func orchestratorSendsExactlyTwoMessagesToProvider() async throws {
    let recorder = RecordingProvider()
    let orchestrator = CompanionOrchestrator(llmProvider: recorder)

    _ = await orchestrator.reply(to: "hello")

    #expect(recorder.receivedMessages.count == 2)
}

// MARK: - onThinkingBegan / onThinkingEnded hook tests (A.3.1)

@Test("reply(to:) calls onThinkingBegan before provider.chat")
func replyCallsOnThinkingBeganBeforeProviderChat() async throws {
    final class OrderRecorder: LLMProvider, @unchecked Sendable {
        var log: [String] = []
        func chat(_ messages: [LLMMessage]) async throws -> String {
            log.append("chat")
            return "response"
        }
    }
    let recorder = OrderRecorder()
    let orchestrator = CompanionOrchestrator(llmProvider: recorder)

    _ = await orchestrator.reply(
        to: "hello",
        onThinkingBegan: { recorder.log.append("began") }
    )

    // "began" must appear before "chat" in the log
    #expect(recorder.log == ["began", "chat"])
}

@Test("reply(to:) calls onThinkingEnded with success after provider responds")
func replyCallsOnThinkingEndedWithSuccessOnGoodResponse() async throws {
    let provider = StubProvider(response: "great answer")
    let orchestrator = CompanionOrchestrator(llmProvider: provider)

    var capturedResult: Result<String, Error>?
    _ = await orchestrator.reply(
        to: "question",
        onThinkingEnded: { result in capturedResult = result }
    )

    if case .success(let value) = capturedResult {
        #expect(value == "great answer")
    } else {
        Issue.record("Expected .success but got \(String(describing: capturedResult))")
    }
}

@Test("reply(to:) calls onThinkingEnded with failure when provider throws")
func replyCallsOnThinkingEndedWithFailureWhenProviderThrows() async throws {
    let provider = ThrowingProvider()
    let orchestrator = CompanionOrchestrator(llmProvider: provider)

    var capturedResult: Result<String, Error>?
    _ = await orchestrator.reply(
        to: "question",
        onThinkingEnded: { result in capturedResult = result }
    )

    if case .failure = capturedResult {
        // correct
    } else {
        Issue.record("Expected .failure but got \(String(describing: capturedResult))")
    }
}

@Test("reply(to:) with nil hooks preserves existing echo behaviour")
func replyWithNilHooksPreservesEchoBehaviour() async throws {
    let orchestrator = CompanionOrchestrator(llmProvider: nil)
    let reply = await orchestrator.reply(to: "test", onThinkingBegan: nil, onThinkingEnded: nil)
    let expected = "\u{6211}\u{542C}\u{5230}\u{201C}test\u{201D}\u{4E86}\u{3002}"
    #expect(reply == expected)
}
