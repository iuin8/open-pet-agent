import Foundation
import Testing
@testable import Shell

@MainActor
@Suite("ChatCardWindowController")
struct ChatCardWindowControllerTests {
    @Test("handleSend：乐观追加 user + 流式累积进 assistant row")
    func sendAccumulates() async {
        let ctrl = ChatCardWindowController(streamProvider: { _ in
            AsyncThrowingStream { c in
                for d in ["你", "好", "呀"] { c.yield(d) }
                c.finish()
            }
        })
        ctrl.handleSend("在吗")
        await ctrl.cardState.streamTask?.value   // 等流式跑完
        let msgs = ctrl.cardState.messages
        #expect(msgs.count == 2)
        #expect(msgs[0].role == .user)
        #expect(msgs[0].text == "在吗")
        #expect(msgs[1].role == .assistant)
        #expect(msgs[1].text == "你好呀")
        #expect(ctrl.cardState.isSending == false)
        #expect(ctrl.cardState.draft == "")
    }

    @Test("handleSend：空白输入不发送")
    func emptyNoSend() {
        let ctrl = ChatCardWindowController(streamProvider: { _ in
            AsyncThrowingStream { $0.finish() }
        })
        ctrl.handleSend("   \n ")
        #expect(ctrl.cardState.messages.isEmpty)
    }

    @Test("handleSend：流式抛错 → assistant row 显示错误，isSending 复位")
    func streamErrorShown() async {
        struct Boom: Error {}
        let ctrl = ChatCardWindowController(streamProvider: { _ in
            AsyncThrowingStream { c in c.finish(throwing: Boom()) }
        })
        ctrl.handleSend("x")
        await ctrl.cardState.streamTask?.value
        #expect(ctrl.cardState.messages.last?.text.hasPrefix("❌") == true)
        #expect(ctrl.cardState.isSending == false)
    }
}
