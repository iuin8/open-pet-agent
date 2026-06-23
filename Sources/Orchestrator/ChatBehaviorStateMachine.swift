// ChatBehaviorStateMachine.swift
// Pure-logic state machine for chat-driven pet behavior (A.3.1).
// No AppKit, no timers, no UI. Caller drives `tickIdleFallback(now:)`.

// MARK: - State + Event types

public enum ChatBehaviorState: Equatable, Sendable {
    case idle
    case watching   // user pressed Send / reply not yet started
    case thinking   // provider.chat awaiting
    case talking    // reply received successfully
    case confused   // reply failed / fallback to echo
}

public enum ChatBehaviorEvent: Sendable {
    case chatSendBegan
    case chatReplyBegan
    case chatReplyReceived
    case chatReplyFailed
}

// MARK: - State machine

/// Pure-logic chat behavior state machine. `@MainActor` so all mutations
/// happen on the main thread, matching A.3.2's CALayer requirements.
@MainActor
public final class ChatBehaviorStateMachine {

    // MARK: Public API

    public typealias StateListener = @MainActor (ChatBehaviorState) -> Void

    public private(set) var state: ChatBehaviorState = .idle
    public var onStateChanged: StateListener?

    public init(onStateChanged: StateListener? = nil) {
        self.onStateChanged = onStateChanged
    }

    // MARK: Sequence management

    private var nextID: UInt64 = 0
    private var currentSequenceID: UInt64 = 0

    /// Returns a fresh, monotonically-increasing sequence ID.
    /// Callers must pass the same ID to the matching reply events.
    public func nextSequenceID() -> UInt64 {
        nextID &+= 1
        return nextID
    }

    // MARK: Idle-fallback timing

    // The SM has no real timer. A.3.2 will drive `tickIdleFallback(now:)`
    // using a display-link / CADisplayLink. `now` is an injected TimeInterval
    // (e.g. `CACurrentMediaTime()`), letting tests inject arbitrary values.

    private var enteredAt: Double = 0
    private var lastTickNow: Double = 0   // used as "current time" when events fire

    // Timeouts per state (seconds). `thinking` has no timeout (returns nil).
    private func idleTimeout(for behaviorState: ChatBehaviorState) -> Double? {
        switch behaviorState {
        case .idle:     return nil
        case .watching: return 4.0
        case .thinking: return nil
        case .talking:  return 2.0
        case .confused: return 3.0
        }
    }

    // MARK: Event handling

    /// Process an event. Events with a `sequenceID` that does not match the
    /// current sequence (except `chatSendBegan`, which always starts a new
    /// sequence) are silently dropped.
    public func handle(_ event: ChatBehaviorEvent, sequenceID: UInt64) {
        switch event {
        case .chatSendBegan:
            // Always accept — begins a new sequence.
            currentSequenceID = sequenceID
            // Record entry time using the most recent tick's `now` value.
            enteredAt = lastTickNow
            transition(to: .watching)

        case .chatReplyBegan:
            guard sequenceID == currentSequenceID else { return }
            transition(to: .thinking)

        case .chatReplyReceived:
            guard sequenceID == currentSequenceID else { return }
            enteredAt = lastTickNow
            transition(to: .talking)

        case .chatReplyFailed:
            guard sequenceID == currentSequenceID else { return }
            enteredAt = lastTickNow
            transition(to: .confused)
        }
    }

    // MARK: Timer-driven idle fallback

    /// Called by A.3.2 (or tests) with the current monotonic time.
    /// Transitions timed-out states back to `.idle`.
    public func tickIdleFallback(now: Double) {
        lastTickNow = now
        guard let timeout = idleTimeout(for: state) else { return }
        let elapsed = now - enteredAt
        if elapsed >= timeout {
            transition(to: .idle)
        }
    }

    // MARK: Private transition

    private func transition(to newState: ChatBehaviorState) {
        guard newState != state else { return }
        state = newState
        onStateChanged?(newState)
    }
}
