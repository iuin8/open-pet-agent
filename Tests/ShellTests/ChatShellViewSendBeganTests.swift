import AppKit
import Testing
@testable import Shell

// MARK: - ChatShellView.onSendBegan Tests

@Suite("ChatShellView.onSendBegan")
@MainActor
struct ChatShellViewSendBeganTests {

    @Test("onSendBegan fires once when sendCurrentMessage is called with non-empty input")
    func onSendBeganFiresOnceOnSend() async {
        var fireCount = 0
        let chatView = ChatShellView(replyHandler: { _ in "ok" })
        chatView.onSendBegan = { fireCount += 1 }

        chatView.inputText = "hello"
        await chatView.sendCurrentMessage()

        #expect(fireCount == 1)
    }

    @Test("onSendBegan fires before the reply handler is awaited")
    func onSendBeganFiresBeforeReplyHandler() async {
        var order: [String] = []
        let chatView = ChatShellView(replyHandler: { _ in
            order.append("reply")
            return "ok"
        })
        chatView.onSendBegan = { order.append("began") }

        chatView.inputText = "test"
        await chatView.sendCurrentMessage()

        #expect(order.first == "began")
        #expect(order.contains("reply"))
    }

    @Test("onSendBegan does not fire when input is empty")
    func onSendBeganDoesNotFireOnEmptyInput() async {
        var fireCount = 0
        let chatView = ChatShellView(replyHandler: { _ in "ok" })
        chatView.onSendBegan = { fireCount += 1 }

        chatView.inputText = ""
        await chatView.sendCurrentMessage()

        #expect(fireCount == 0)
    }

    @Test("onSendBegan does not fire when input is only whitespace")
    func onSendBeganDoesNotFireOnWhitespaceOnlyInput() async {
        var fireCount = 0
        let chatView = ChatShellView(replyHandler: { _ in "ok" })
        chatView.onSendBegan = { fireCount += 1 }

        chatView.inputText = "   "
        await chatView.sendCurrentMessage()

        #expect(fireCount == 0)
    }

    @Test("onSendBegan fires on each successive send")
    func onSendBeganFiresOnEachSuccessiveSend() async {
        var fireCount = 0
        let chatView = ChatShellView(replyHandler: { _ in "ok" })
        chatView.onSendBegan = { fireCount += 1 }

        chatView.inputText = "first"
        await chatView.sendCurrentMessage()
        chatView.inputText = "second"
        await chatView.sendCurrentMessage()

        #expect(fireCount == 2)
    }
}
