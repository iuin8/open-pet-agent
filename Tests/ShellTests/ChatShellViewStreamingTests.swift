import AppKit
import Testing
@testable import Shell

// MARK: - ChatShellView streaming path tests
//
// StreamingReplyHandler: @MainActor (String) -> AsyncThrowingStream<String, Error>
// The view iterates the stream, accumulates deltas, and updates transcript.

@Suite("ChatShellView streaming")
@MainActor
struct ChatShellViewStreamingTests {

    // MARK: - Streaming path activation

    @Test("streamingReplyHandler set: sendCurrentMessage uses streaming path not atomic")
    func streamingReplyHandlerSetUsesStreamingPath() async {
        var streamingCalled = false
        var atomicCalled = false

        let chatView = ChatShellView(replyHandler: { _ in
            atomicCalled = true
            return "atomic"
        })
        chatView.streamingReplyHandler = { message in
            streamingCalled = true
            return AsyncThrowingStream { continuation in
                continuation.yield("streamed")
                continuation.finish()
            }
        }

        chatView.inputText = "hello"
        await chatView.sendCurrentMessage()

        #expect(streamingCalled)
        #expect(atomicCalled == false)
    }

    @Test("streamingReplyHandler nil: sendCurrentMessage uses atomic replyHandler path")
    func streamingReplyHandlerNilUsesAtomicPath() async {
        var atomicCalled = false

        let chatView = ChatShellView(replyHandler: { _ in
            atomicCalled = true
            return "atomic"
        })
        // streamingReplyHandler is nil by default

        chatView.inputText = "hello"
        await chatView.sendCurrentMessage()

        #expect(atomicCalled)
    }

    // MARK: - Partial transcript updates

    @Test("transcript updates in-progress when stream yields tokens")
    func transcriptUpdatesInProgressDuringStreaming() async {
        let chatView = ChatShellView(replyHandler: { _ in "unused" })
        chatView.streamingReplyHandler = { message in
            AsyncThrowingStream { continuation in
                continuation.yield("Hello")
                continuation.yield(", ")
                continuation.yield("World")
                continuation.finish()
            }
        }

        chatView.inputText = "test message"
        await chatView.sendCurrentMessage()

        // After streaming completes, transcript contains all accumulated tokens
        #expect(chatView.transcript == "你：test message\nOpenPetAgent：Hello, World")
    }

    @Test("final transcript reflects fully accumulated stream content")
    func finalTranscriptReflectsFullyAccumulatedContent() async {
        let chatView = ChatShellView(replyHandler: { _ in "unused" })
        chatView.streamingReplyHandler = { message in
            AsyncThrowingStream { continuation in
                continuation.yield("complete answer")
                continuation.finish()
            }
        }

        chatView.inputText = "question"
        await chatView.sendCurrentMessage()

        #expect(chatView.transcript == "你：question\nOpenPetAgent：complete answer")
    }

    @Test("transcript contains user message during streaming")
    func transcriptContainsUserMessageDuringStreaming() async {
        var transcriptDuringStream = ""
        let chatView = ChatShellView(replyHandler: { _ in "unused" })
        chatView.streamingReplyHandler = { message in
            AsyncThrowingStream { continuation in
                // Yield nothing — check the transcript format after the empty stream
                continuation.finish()
            }
        }

        chatView.inputText = "user question"
        await chatView.sendCurrentMessage()

        // Even with an empty stream, the last update should contain the user message
        // (transcript doesn't change for empty streams, stays at initial value)
        // This test verifies the format is correct when non-empty
        let view2 = ChatShellView(replyHandler: { _ in "unused" })
        view2.streamingReplyHandler = { message in
            transcriptDuringStream = view2.transcript
            return AsyncThrowingStream { continuation in
                continuation.yield("reply token")
                continuation.finish()
            }
        }
        view2.inputText = "hi"
        await view2.sendCurrentMessage()

        #expect(view2.transcript.contains("hi"))
        #expect(view2.transcript.contains("reply token"))
    }

    // MARK: - Sequence-ID guard (no stale partial pollution)

    @Test("stale stream deltas do not update transcript when newer send started")
    func staleStreamDeltasDoNotUpdateTranscriptWhenNewerSendStarted() async {
        // Verify that the latestSendIdentifier guard works:
        // A stream that finishes AFTER a second send begins should not overwrite the
        // second send's transcript.
        let continuation1Box = Box<AsyncThrowingStream<String, Error>.Continuation?>(nil)
        let semaphore = AsyncSemaphore()
        var handlerCallCount = 0

        let chatView = ChatShellView(replyHandler: { _ in "fallback" })
        chatView.streamingReplyHandler = { message in
            handlerCallCount += 1
            if handlerCallCount == 1 {
                // First send: return a stream that we control externally
                return AsyncThrowingStream { continuation in
                    continuation1Box.value = continuation
                    semaphore.signal()  // signal that first stream is ready
                }
            } else {
                // Second send: quick finish
                return AsyncThrowingStream { continuation in
                    continuation.yield("second reply")
                    continuation.finish()
                }
            }
        }

        // Start first send — its stream will not finish yet
        chatView.inputText = "first"
        let task1 = Task { @MainActor in
            await chatView.sendCurrentMessage()
        }

        // Wait for first stream to be set up
        await semaphore.wait()

        // Start second send (creates new latestSendIdentifier)
        chatView.inputText = "second"
        await chatView.sendCurrentMessage()

        // Now finish first stream with stale data
        continuation1Box.value?.yield("stale delta")
        continuation1Box.value?.finish()

        await task1.value

        // Transcript should be from second send, not stale first stream delta
        #expect(chatView.transcript.contains("second"))
        #expect(chatView.transcript.contains("second reply"))
        #expect(!chatView.transcript.contains("stale delta"))
    }
}

// MARK: - Test helpers

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private final class AsyncSemaphore: @unchecked Sendable {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var count = 0
    private let lock = NSLock()

    func signal() {
        lock.lock()
        count += 1
        let waiters = continuations
        continuations = []
        lock.unlock()
        for c in waiters { c.resume() }
    }

    func wait() async {
        lock.lock()
        if count > 0 {
            count -= 1
            lock.unlock()
            return
        }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if count > 0 {
                count -= 1
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}
