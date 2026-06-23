import AppKit
import Orchestrator
import Testing
@testable import Shell

@MainActor
@Suite("BondedSession — chat driver (phase A.5.3 phase 3 v2：同列垂直堆叠)")
struct BondedSessionTests {

    // MARK: - Fixtures

    private func makeParent() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 80, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    private func teardown(_ parent: NSWindow, _ session: BondedSession) {
        session.clear()
        parent.orderOut(nil)
    }

    // MARK: - Tests

    @Test("init 后 chain 为空，isStreaming == false")
    func emptyOnInit() {
        let parent = makeParent()
        let session = BondedSession(
            attachedToPet: parent,
            replyHandler: { _ in "" }
        )
        #expect(session.chain.bubbleCount == 0)
        #expect(session.isStreaming == false)
        teardown(parent, session)
    }

    @Test("atomic 路径：appendUserInputAndSend 之后链长 = 2，user 在 0、assistant 在 1")
    func atomicReplyAppendsBothBubbles() async {
        let parent = makeParent()
        let session = BondedSession(
            attachedToPet: parent,
            replyHandler: { msg in "echo:\(msg)" }
        )

        await session.appendUserInputAndSend("你好")

        #expect(session.chain.bubbleCount == 2)
        // 索引 0 = user (新设计左右分布)
        #expect(session.chain.bubble(at: 0)?.kind == .userMessage)
        #expect(session.chain.bubble(at: 0)?.currentText == "你好")
        // 索引 1 = assistant
        #expect(session.chain.bubble(at: 1)?.kind == .assistantReply)
        #expect(session.chain.bubble(at: 1)?.currentText == "echo:你好")
        #expect(session.isStreaming == false)

        teardown(parent, session)
    }

    @Test("streaming 路径：tokens 累积写到当前轮 assistant 气泡 (索引 1)")
    func streamingTokensAccumulateInAssistantBubble() async {
        let parent = makeParent()
        let session = BondedSession(
            attachedToPet: parent,
            replyHandler: { _ in "unused" },
            streamingReplyHandler: { _ in
                AsyncThrowingStream<String, Error> { continuation in
                    continuation.yield("Hi")
                    continuation.yield(", ")
                    continuation.yield("there")
                    continuation.finish()
                }
            }
        )

        await session.appendUserInputAndSend("ping")

        #expect(session.chain.bubbleCount == 2)
        #expect(session.chain.bubble(at: 1)?.kind == .assistantReply)
        #expect(session.chain.bubble(at: 1)?.currentText == "Hi, there")
        #expect(session.isStreaming == false)

        teardown(parent, session)
    }

    @Test("空白消息直接 return：不创建任何气泡")
    func whitespaceMessageIsIgnored() async {
        let parent = makeParent()
        let session = BondedSession(
            attachedToPet: parent,
            replyHandler: { _ in "should-not-fire" }
        )

        await session.appendUserInputAndSend("   ")
        #expect(session.chain.bubbleCount == 0)

        await session.appendUserInputAndSend("\n\t  ")
        #expect(session.chain.bubbleCount == 0)

        teardown(parent, session)
    }

    @Test("clear() 后链空、isStreaming == false")
    func clearResetsEverything() async {
        let parent = makeParent()
        let session = BondedSession(
            attachedToPet: parent,
            replyHandler: { msg in "r:\(msg)" }
        )

        await session.appendUserInputAndSend("a")
        await session.appendUserInputAndSend("b")
        // 新设计：第二轮自动清第一轮。链中仍只有 b 这一轮的 2 颗气泡。
        #expect(session.chain.bubbleCount == 2)
        #expect(session.chain.bubble(at: 0)?.currentText == "b")

        session.clear()
        #expect(session.chain.bubbleCount == 0)
        #expect(session.isStreaming == false)

        teardown(parent, session)
    }

    @Test("setStreamingHandler 可热替换：从 atomic 切到 streaming 路径（每轮自动清旧）")
    func hotSwapStreamingHandler() async {
        let parent = makeParent()
        let session = BondedSession(
            attachedToPet: parent,
            replyHandler: { _ in "atomic-reply" }
        )

        // 先走 atomic 路径
        await session.appendUserInputAndSend("q1")
        #expect(session.chain.bubble(at: 1)?.currentText == "atomic-reply")

        // 切到 streaming
        session.setStreamingHandler { _ in
            AsyncThrowingStream<String, Error> { continuation in
                continuation.yield("stream-")
                continuation.yield("reply")
                continuation.finish()
            }
        }

        await session.appendUserInputAndSend("q2")
        // 新一轮自动 clear，链长仍 = 2（q2 + stream-reply）。
        #expect(session.chain.bubbleCount == 2)
        #expect(session.chain.bubble(at: 0)?.currentText == "q2")
        #expect(session.chain.bubble(at: 1)?.currentText == "stream-reply")

        teardown(parent, session)
    }

    @Test("streaming done 后 chain.restartDismissCountdown 让 8s 从内容齐全开始数")
    func streamingDoneRestartsDismissCountdown() async {
        let parent = makeParent()
        let session = BondedSession(
            attachedToPet: parent,
            replyHandler: { _ in "unused" },
            streamingReplyHandler: { _ in
                AsyncThrowingStream<String, Error> { continuation in
                    continuation.yield("hello ")
                    continuation.yield("world")
                    continuation.finish()
                }
            }
        )

        await session.appendUserInputAndSend("q")
        // stream 已 done. countdown 应已 restart (=autoDismissSeconds full)
        #expect(session.chain.isDismissCountdownActive == true)
        #expect(session.chain.dismissRemainingForTest == BondedBubbleChain.autoDismissSeconds)

        teardown(parent, session)
    }

    // MARK: - S2 LLM 错误友好显示

    @Test("streaming 出错 + 0 token: 创建只含错误文案的 assistant 气泡")
    func streamingErrorBeforeAnyToken() async {
        let parent = makeParent()
        let session = BondedSession(
            attachedToPet: parent,
            replyHandler: { _ in "should-not-fire" },
            streamingReplyHandler: { _ in
                AsyncThrowingStream<String, Error> { continuation in
                    continuation.finish(throwing: URLError(.notConnectedToInternet))
                }
            }
        )

        await session.appendUserInputAndSend("q")
        // 链长 2: user + assistant (含错误文案), 不是只有 user 那种 silent failure
        #expect(session.chain.bubbleCount == 2)
        let reply = session.chain.bubble(at: 1)?.currentText ?? ""
        #expect(reply.contains("⚠️"))
        #expect(reply.contains("没有网络"))

        teardown(parent, session)
    }

    @Test("streaming 出错 + 已有累积内容: 错误文案追加到已读部分,不丢失内容")
    func streamingErrorPreservesAccumulatedContent() async {
        let parent = makeParent()
        let session = BondedSession(
            attachedToPet: parent,
            replyHandler: { _ in "atomic" },
            streamingReplyHandler: { _ in
                AsyncThrowingStream<String, Error> { continuation in
                    continuation.yield("已读到的部分")
                    continuation.finish(throwing: URLError(.timedOut))
                }
            }
        )

        await session.appendUserInputAndSend("q")
        #expect(session.chain.bubbleCount == 2)
        let reply = session.chain.bubble(at: 1)?.currentText ?? ""
        #expect(reply.contains("已读到的部分"))
        #expect(reply.contains("超时"))

        teardown(parent, session)
    }

    @Test("streaming 出错 + 友好文案是 Markdown(⚠️ + 加粗)")
    func streamingErrorMessageIsMarkdown() async {
        let parent = makeParent()
        let session = BondedSession(
            attachedToPet: parent,
            replyHandler: { _ in "" },
            streamingReplyHandler: { _ in
                AsyncThrowingStream<String, Error> { continuation in
                    continuation.finish(throwing: URLError(.userAuthenticationRequired))
                }
            }
        )

        await session.appendUserInputAndSend("q")
        let reply = session.chain.bubble(at: 1)?.currentText ?? ""
        // BondedMarkdownBubble 会渲染 **加粗** 与 emoji
        #expect(reply.contains("**"))
        #expect(reply.contains("API key"))

        teardown(parent, session)
    }

}
