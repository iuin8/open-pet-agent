import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("ChatShellView — Return key sends message")
struct ChatShellViewReturnKeyTests {
    @Test("Input field's action target is the ChatShellView itself")
    func returnKeyTargetIsSelf() {
        let view = ChatShellView()
        #expect(view.inputFieldTargetIsSelf == true)
    }

    @Test("Input field's action is wired (non-nil) so Return triggers send")
    func returnKeyActionIsWired() {
        let view = ChatShellView()
        #expect(view.inputFieldAction != nil)
    }

    @Test("sendsActionOnEndEditing is false — only Return commits, not focus loss")
    func sendsActionOnEndEditingIsDisabled() {
        let view = ChatShellView()
        #expect(view.inputFieldSendsActionOnEndEditing == false)
    }

    @Test("Firing the input field's action with non-empty text dispatches the send flow")
    func firingActionTriggersSend() async {
        var capturedMessage: String?
        let view = ChatShellView { message in
            capturedMessage = message
            return "ok"
        }
        view.inputText = "hello via Return"

        guard let action = view.inputFieldAction else {
            Issue.record("Return-key action is not wired")
            return
        }
        let dispatched = NSApp.sendAction(action, to: view, from: view)
        #expect(dispatched == true)

        // sendButtonClicked dispatches a Task; wait briefly for it to land.
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(capturedMessage == "hello via Return")
        #expect(view.inputText.isEmpty)
    }
}
