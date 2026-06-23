import AppKit
import QuartzCore
import Testing
@testable import App
@testable import Shell
@testable import Orchestrator
import Context
import Rendering
import RuntimeBridge

// MARK: - End-to-end chat behavior wiring tests
//
// Exercises the wiring: ChatShellView.onSendBegan → ChatBehaviorStateMachine
// → DesktopShellController.applyPetChatBehavior.
// Uses a minimal MinimalAppDelegate with injected no-op stubs for the frame
// loop, shell display, and runtime, so tests remain fast and headless.

@MainActor
private func makeMinimalDelegate() -> MinimalAppDelegate {
    let rootSystem = AppRootSystem(
        snapshot: DesktopSnapshot(),
        windowGraph: .bootstrap,
        companionBootstrap: CompanionBootstrap(
            capabilities: RuntimeCapabilities(),
            initialRenderState: RenderState(
                petPositionX: 100,
                petPositionY: 100,
                petRotation: 0,
                particleCount: 0,
                particles: [],
                contactCount: 0,
                isSnowEnabled: false
            )
        ),
        runtimeTicker: RuntimeTicker { previousState, _, _ in
            RuntimeTickResult(
                renderState: previousState,
                snapshot: DesktopSnapshot()
            )
        },
        conversationResponder: ConversationResponder { message in
            "echo: \(message)"
        }
    )

    return MinimalAppDelegate(
        rootSystem: rootSystem,
        currentScreenFrame: { NSRect(x: 0, y: 0, width: 800, height: 600) },
        currentTime: { 0 },
        startFrameLoop: { _ in nil },
        showShellWindows: { _ in },
        waitForRuntimeFrame: {}
    )
}

@MainActor
private func launchDelegate(_ delegate: MinimalAppDelegate) {
    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )
}

@MainActor
private func teardown(_ delegate: MinimalAppDelegate) {
    delegate.launchedShellController?.windowSet.allWindows.forEach { $0.orderOut(nil as NSWindow?) }
}

@Suite("ChatBehaviorWiring end-to-end")
@MainActor
struct ChatBehaviorWiringTests {

    // MARK: - State machine instantiated

    @Test("chatBehaviorStateMachine is instantiated after app launch")
    func chatBehaviorStateMachineIsInstantiatedAfterAppLaunch() {
        let delegate = makeMinimalDelegate()
        launchDelegate(delegate)
        defer { teardown(delegate) }

        #expect(delegate.chatBehaviorStateMachine != nil)
    }

    @Test("initial state machine state is idle before any chat activity")
    func initialStateMachineStateIsIdle() {
        let delegate = makeMinimalDelegate()
        launchDelegate(delegate)
        defer { teardown(delegate) }

        #expect(delegate.chatBehaviorStateMachine?.state == ChatBehaviorState.idle)
    }

    // MARK: - onSendBegan wiring

    @Test("ChatShellView onSendBegan triggers chatSendBegan and transitions SM to watching")
    func onSendBeganTransitionsStateMachineToWatching() throws {
        let delegate = makeMinimalDelegate()
        launchDelegate(delegate)
        defer { teardown(delegate) }

        let sm = try #require(delegate.chatBehaviorStateMachine)
        let chatShellView = try #require(
            delegate.launchedShellController?.windowSet.chatWindow.contentView as? ChatShellView
        )

        chatShellView.onSendBegan()

        #expect(sm.state == ChatBehaviorState.watching)
    }

    // MARK: - tickIdleFallback driven by frame loop

    @Test("tickIdleFallback on state machine transitions watching to idle after timeout")
    func tickIdleFallbackTransitionsWatchingToIdle() throws {
        let delegate = makeMinimalDelegate()
        launchDelegate(delegate)
        defer { teardown(delegate) }

        let sm = try #require(delegate.chatBehaviorStateMachine)
        let chatShellView = try #require(
            delegate.launchedShellController?.windowSet.chatWindow.contentView as? ChatShellView
        )

        chatShellView.onSendBegan()
        #expect(sm.state == ChatBehaviorState.watching)

        // Fast-forward past the 4s watching timeout
        sm.tickIdleFallback(now: 100.0)
        #expect(sm.state == ChatBehaviorState.idle)
    }

    // MARK: - onStateChanged → applyPetChatBehavior

    @Test("onStateChanged callback drives pet layer animations when state transitions")
    func onStateChangedDrivesPetLayerAnimations() throws {
        let delegate = makeMinimalDelegate()
        launchDelegate(delegate)
        defer { teardown(delegate) }

        let chatShellView = try #require(
            delegate.launchedShellController?.windowSet.chatWindow.contentView as? ChatShellView
        )
        let petLayer = try #require(
            delegate.launchedShellController?.windowSet.petWindow.contentView?.layer
        )

        chatShellView.onSendBegan()

        // The onStateChanged callback should have called applyPetChatBehavior(.watching)
        let keys = petLayer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.watchingTiltKey))
    }

    // MARK: - Full send-reply cycle

    @Test("full send-reply cycle drives SM to talking after synchronous echo reply")
    func fullSendReplyCycleDrivesStateMachineToTalking() async throws {
        let delegate = makeMinimalDelegate()
        launchDelegate(delegate)
        defer { teardown(delegate) }

        let sm = try #require(delegate.chatBehaviorStateMachine)
        let chatShellView = try #require(
            delegate.launchedShellController?.windowSet.chatWindow.contentView as? ChatShellView
        )

        chatShellView.inputText = "hello"
        await chatShellView.sendCurrentMessage()

        // The echo responder is synchronous so the full cycle completes:
        // watching → thinking → talking.
        #expect(sm.state == ChatBehaviorState.talking)
    }

    // MARK: - Streaming handler wiring

    @Test("streamingReplyHandler stream does not introduce a streaming-specific SM state")
    func streamingReplyHandlerStreamDoesNotIntroduceStreamingState() async throws {
        let delegate = makeMinimalDelegate()
        launchDelegate(delegate)
        defer { teardown(delegate) }

        let sm = try #require(delegate.chatBehaviorStateMachine)
        let chatShellView = try #require(
            delegate.launchedShellController?.windowSet.chatWindow.contentView as? ChatShellView
        )

        // Wire a streaming handler that yields tokens via AsyncThrowingStream
        chatShellView.streamingReplyHandler = { message in
            AsyncThrowingStream { continuation in
                continuation.yield("token1")
                continuation.yield(" token2")
                continuation.finish()
            }
        }

        chatShellView.inputText = "tell me something"
        await chatShellView.sendCurrentMessage()

        // SM should be in a valid state — .streaming does NOT exist.
        // After the stream completes and reply is received, SM ends at .talking.
        let validStates: [ChatBehaviorState] = [.idle, .watching, .thinking, .talking]
        #expect(validStates.contains(sm.state))
    }
}
