import Testing
@testable import Orchestrator

// MARK: - ChatBehaviorStateMachine unit tests
// These are written test-first (RED) and cover the full specification in
// docs/llm-chat-design.md §1.3.

@MainActor
@Suite("ChatBehaviorStateMachine")
struct ChatBehaviorStateMachineTests {

    // MARK: 1. Initial state

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        let sm = ChatBehaviorStateMachine()
        #expect(sm.state == .idle)
    }

    // MARK: 2. nextSequenceID monotonically increases and is unique

    @Test("nextSequenceID is monotonically increasing")
    func nextSequenceIDIsMonotonicallyIncreasing() {
        let sm = ChatBehaviorStateMachine()
        let id1 = sm.nextSequenceID()
        let id2 = sm.nextSequenceID()
        let id3 = sm.nextSequenceID()
        #expect(id1 < id2)
        #expect(id2 < id3)
    }

    @Test("nextSequenceID values are unique across many calls")
    func nextSequenceIDValuesAreUnique() {
        let sm = ChatBehaviorStateMachine()
        var ids: Set<UInt64> = []
        for _ in 0..<100 {
            ids.insert(sm.nextSequenceID())
        }
        #expect(ids.count == 100)
    }

    // MARK: 3. chatSendBegan -> .watching

    @Test("chatSendBegan transitions to watching")
    func chatSendBeganTransitionsToWatching() {
        let sm = ChatBehaviorStateMachine()
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)
        #expect(sm.state == .watching)
    }

    @Test("onStateChanged fires with watching when chatSendBegan")
    func onStateChangedFiresWithWatchingOnSendBegan() {
        var received: [ChatBehaviorState] = []
        let sm = ChatBehaviorStateMachine { state in
            received.append(state)
        }
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)
        #expect(received == [.watching])
    }

    // MARK: 4. chatReplyBegan -> .thinking

    @Test("chatReplyBegan transitions from watching to thinking")
    func chatReplyBeganTransitionsToThinking() {
        let sm = ChatBehaviorStateMachine()
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)
        sm.handle(.chatReplyBegan, sequenceID: seq)
        #expect(sm.state == .thinking)
    }

    // MARK: 5. chatReplyReceived -> .talking

    @Test("chatReplyReceived transitions from thinking to talking")
    func chatReplyReceivedTransitionsToTalking() {
        let sm = ChatBehaviorStateMachine()
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)
        sm.handle(.chatReplyBegan, sequenceID: seq)
        sm.handle(.chatReplyReceived, sequenceID: seq)
        #expect(sm.state == .talking)
    }

    // MARK: 6. chatReplyFailed -> .confused

    @Test("chatReplyFailed transitions from thinking to confused")
    func chatReplyFailedTransitionsToConfused() {
        let sm = ChatBehaviorStateMachine()
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)
        sm.handle(.chatReplyBegan, sequenceID: seq)
        sm.handle(.chatReplyFailed, sequenceID: seq)
        #expect(sm.state == .confused)
    }

    // MARK: 7. Re-entrant: stale sequence reply is dropped

    @Test("Stale chatReplyReceived from old sequence is dropped")
    func staleReplyReceivedIsDropped() {
        var received: [ChatBehaviorState] = []
        let sm = ChatBehaviorStateMachine { state in
            received.append(state)
        }

        // First send
        let seq1 = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq1)
        sm.handle(.chatReplyBegan, sequenceID: seq1)

        // Second send interrupts
        let seq2 = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq2)
        // State should now be .watching from seq2
        let stateAfterSeq2Send = sm.state

        // Stale reply from seq1 arrives — must be dropped
        sm.handle(.chatReplyReceived, sequenceID: seq1)
        #expect(sm.state == stateAfterSeq2Send) // unchanged

        // Valid reply from seq2 should go through
        sm.handle(.chatReplyBegan, sequenceID: seq2)
        sm.handle(.chatReplyReceived, sequenceID: seq2)
        #expect(sm.state == .talking)
    }

    @Test("Stale chatReplyFailed from old sequence is dropped")
    func staleReplyFailedIsDropped() {
        let sm = ChatBehaviorStateMachine()

        let seq1 = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq1)
        sm.handle(.chatReplyBegan, sequenceID: seq1)

        let seq2 = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq2)

        // Stale failure from seq1 — must not transition to .confused
        sm.handle(.chatReplyFailed, sequenceID: seq1)
        #expect(sm.state == .watching) // still watching from seq2
    }

    // MARK: 8. Out-of-order / unknown sequence is dropped

    @Test("Unknown sequence reply is ignored from idle")
    func unknownSequenceReplyIsIgnoredFromIdle() {
        let sm = ChatBehaviorStateMachine()
        sm.handle(.chatReplyReceived, sequenceID: 99)
        #expect(sm.state == .idle)
    }

    @Test("Unknown sequence replyBegan is ignored from idle")
    func unknownSequenceReplyBeganIsIgnored() {
        let sm = ChatBehaviorStateMachine()
        sm.handle(.chatReplyBegan, sequenceID: 42)
        #expect(sm.state == .idle)
    }

    // MARK: 9. Timer fallback: watching -> idle after 4s

    @Test("Watching transitions to idle after 4-second tickIdleFallback")
    func watchingFallsToIdleAfter4Seconds() {
        let sm = ChatBehaviorStateMachine()
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)
        #expect(sm.state == .watching)

        // Not yet timed out at 3.9s
        sm.tickIdleFallback(now: 3.9)
        #expect(sm.state == .watching)

        // Timed out at 4.0s
        sm.tickIdleFallback(now: 4.0)
        #expect(sm.state == .idle)
    }

    @Test("Watching fallback fires onStateChanged with idle")
    func watchingFallbackFiresOnStateChanged() {
        var received: [ChatBehaviorState] = []
        let sm = ChatBehaviorStateMachine { state in
            received.append(state)
        }
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)   // fires .watching
        sm.tickIdleFallback(now: 4.0)                // fires .idle
        #expect(received.last == .idle)
    }

    // MARK: 10. Thinking does NOT timeout

    @Test("Thinking state does not time out even after 10 seconds")
    func thinkingDoesNotTimeout() {
        let sm = ChatBehaviorStateMachine()
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)
        sm.handle(.chatReplyBegan, sequenceID: seq)
        #expect(sm.state == .thinking)

        sm.tickIdleFallback(now: 10.0)
        #expect(sm.state == .thinking)

        sm.tickIdleFallback(now: 1000.0)
        #expect(sm.state == .thinking)
    }

    // MARK: 11. Talking fallback to idle after 2s

    @Test("Talking transitions to idle after 2-second tickIdleFallback")
    func talkingFallsToIdleAfter2Seconds() {
        let sm = ChatBehaviorStateMachine()
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)
        sm.handle(.chatReplyBegan, sequenceID: seq)
        sm.handle(.chatReplyReceived, sequenceID: seq)
        #expect(sm.state == .talking)

        // Not yet at 1.9s
        sm.tickIdleFallback(now: 1.9)
        #expect(sm.state == .talking)

        // At 2.0s exactly
        sm.tickIdleFallback(now: 2.0)
        #expect(sm.state == .idle)
    }

    // MARK: 12. Confused fallback to idle after 3s

    @Test("Confused transitions to idle after 3-second tickIdleFallback")
    func confusedFallsToIdleAfter3Seconds() {
        let sm = ChatBehaviorStateMachine()
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)
        sm.handle(.chatReplyBegan, sequenceID: seq)
        sm.handle(.chatReplyFailed, sequenceID: seq)
        #expect(sm.state == .confused)

        sm.tickIdleFallback(now: 2.9)
        #expect(sm.state == .confused)

        sm.tickIdleFallback(now: 3.0)
        #expect(sm.state == .idle)
    }

    // MARK: 13. onStateChanged fires only on real state changes

    @Test("onStateChanged does not fire for duplicate chatSendBegan in same state")
    func onStateChangedDoesNotFireForNoOpTransition() {
        var received: [ChatBehaviorState] = []
        let sm = ChatBehaviorStateMachine { state in
            received.append(state)
        }

        // Inject two chatSendBegan in a row — second should still transition
        // (new sequence replaces the old one), so state should remain .watching
        // but the callback should still fire because state is re-entered from .watching.
        // More precisely: after seq1 brings us to .watching, seq2.chatSendBegan
        // leaves us in .watching again — callback fires because we explicitly
        // transition (even if value is the same) only if the impl emits every
        // transition. Per spec "only fires when state truly changes" means
        // watching->watching is a no-change transition and MUST NOT fire.
        let seq1 = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq1) // idle -> watching, fires
        let countAfterFirst = received.count

        // seq2 chatSendBegan: watching -> watching (same state), must NOT fire
        let seq2 = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq2)
        #expect(received.count == countAfterFirst, "callback must not fire for same-state transition")
    }

    @Test("Full happy path fires all expected state changes in order")
    func fullHappyPathFiresAllExpectedStateChanges() {
        var received: [ChatBehaviorState] = []
        let sm = ChatBehaviorStateMachine { state in
            received.append(state)
        }
        let seq = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq)
        sm.handle(.chatReplyBegan, sequenceID: seq)
        sm.handle(.chatReplyReceived, sequenceID: seq)
        sm.tickIdleFallback(now: 2.0)

        #expect(received == [.watching, .thinking, .talking, .idle])
    }

    // MARK: Edge: idle does not fallback further

    @Test("tickIdleFallback on idle state does not re-fire onStateChanged")
    func idleDoesNotRefireOnTick() {
        var received: [ChatBehaviorState] = []
        let sm = ChatBehaviorStateMachine { state in
            received.append(state)
        }
        sm.tickIdleFallback(now: 100.0)
        #expect(received.isEmpty)
    }

    // MARK: enteredAt timestamp resets correctly for each state

    @Test("Timeout clock resets when re-entering watching via second chatSendBegan")
    func timeoutClockResetsOnReentry() {
        let sm = ChatBehaviorStateMachine()

        // First send at t=0 (implicit), tick at t=3.9 — still watching
        let seq1 = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq1)
        sm.tickIdleFallback(now: 3.9)
        #expect(sm.state == .watching)

        // Second send — clock resets (enteredAt = 3.9 notionally via current now, but
        // the SM tracks absolute TimeInterval injected via tickIdleFallback).
        // The SM's enteredAt for the new watching period should be "now" at the
        // moment of the event. But since the SM has no clock of its own, it uses
        // the last tick's `now` as reference. See implementation notes.
        // After seq2 chatSendBegan, timeout window is 4s from enteredAt (3.9).
        let seq2 = sm.nextSequenceID()
        sm.handle(.chatSendBegan, sequenceID: seq2)

        // At 7.89 (3.9 + 3.99) — must NOT have expired yet
        sm.tickIdleFallback(now: 7.89)
        #expect(sm.state == .watching)

        // At 7.9 (3.9 + 4.0) — expires
        sm.tickIdleFallback(now: 7.9)
        #expect(sm.state == .idle)
    }
}
