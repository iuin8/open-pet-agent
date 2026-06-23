import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("ChatShellView — scrollable transcript (long replies no longer clipped)")
struct ChatShellViewScrollableTranscriptTests {

    @Test("Transcript is hosted inside an NSScrollView with vertical scrolling")
    func transcriptIsHostedInScrollView() {
        let view = ChatShellView()
        #expect(view.transcriptIsScrollable)
    }

    @Test("Setting an extremely long transcript does not crash and stays accessible")
    func longTranscriptStoredCorrectly() async {
        let view = ChatShellView { _ in "" }
        let longReply = String(repeating: "这是一行很长的回复, 用来测试滚动。", count: 200)
        // Use the public reply path so the didSet fires through the TextView.
        view.inputText = "测试"
        // Inject a reply handler that returns the long reply.
        let view2 = ChatShellView(replyHandler: { _ in longReply })
        view2.inputText = "测试"
        await view2.sendCurrentMessage()
        // After send completes the transcript should contain the long reply.
        #expect(view2.transcript.contains(longReply))
        // Also verify the initial transcript reads back through the public property
        // (the new TextView didSet path keeps `transcript` as the source of truth).
        #expect(view.transcript == "OpenPetAgent 已就绪。")
    }

    @Test("Initial transcript text matches the default greeting")
    func initialTranscriptRendered() {
        let view = ChatShellView()
        #expect(view.transcript == "OpenPetAgent 已就绪。")
    }
}
