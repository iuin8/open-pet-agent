import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("ChatShellView — transcript accumulates multi-turn history")
struct ChatShellViewHistoryTests {

    @Test("Initial transcript is the greeting before any send")
    func initialGreeting() {
        let view = ChatShellView()
        #expect(view.transcript == "OpenPetAgent 已就绪。")
    }

    @Test("Atomic reply appends a turn; second send keeps the first turn visible")
    func atomicMultiTurnAppends() async {
        var counter = 0
        let view = ChatShellView { message in
            counter += 1
            return "reply\(counter): \(message)"
        }

        view.inputText = "first"
        await view.sendCurrentMessage()

        view.inputText = "second"
        await view.sendCurrentMessage()

        // Both turns visible, separated by a blank line.
        #expect(view.transcript.contains("你：first"))
        #expect(view.transcript.contains("OpenPetAgent：reply1: first"))
        #expect(view.transcript.contains("你：second"))
        #expect(view.transcript.contains("OpenPetAgent：reply2: second"))
        #expect(view.transcript.contains("\n\n"),
                "Turns must be separated by a blank line")
    }

    @Test("Streaming turn appears in-progress, then commits after the stream ends")
    func streamingTurnCommits() async {
        let view = ChatShellView()
        view.streamingReplyHandler = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield("Hel")
                continuation.yield("lo")
                continuation.finish()
            }
        }
        view.inputText = "ping"
        await view.sendCurrentMessage()

        // After stream completes, the turn lives in history.
        #expect(view.transcript.contains("你：ping"))
        #expect(view.transcript.contains("OpenPetAgent：Hello"))
    }

    @Test("clearTranscript restores the initial greeting")
    func clearTranscriptResets() async {
        let view = ChatShellView { _ in "ok" }
        view.inputText = "hi"
        await view.sendCurrentMessage()
        #expect(view.transcript.contains("hi"))

        view.clearTranscript()
        #expect(view.transcript == "OpenPetAgent 已就绪。")
    }

    @Test("Mixed atomic + streaming turns both stay in the transcript")
    func mixedAtomicAndStreaming() async {
        let view = ChatShellView { _ in "atomic-reply" }
        view.streamingReplyHandler = nil

        view.inputText = "atomic"
        await view.sendCurrentMessage()

        view.streamingReplyHandler = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield("stream-reply")
                continuation.finish()
            }
        }
        view.inputText = "streamed"
        await view.sendCurrentMessage()

        #expect(view.transcript.contains("OpenPetAgent：atomic-reply"))
        #expect(view.transcript.contains("OpenPetAgent：stream-reply"))
    }
}
