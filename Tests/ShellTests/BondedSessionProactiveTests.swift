import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("BondedSession 主动建议注入")
struct BondedSessionProactiveTests {
    private func makeSession() -> BondedSession {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        return BondedSession(
            attachedToPet: win,
            replyHandler: { _ in "" }
        )
    }

    @Test("injectProactiveSuggestion → 单颗暖染色气泡，count==1")
    func injectSingleBubble() {
        let session = makeSession()
        session.injectProactiveSuggestion(context: "深夜", reply: "凌晨了，注意休息", onDismiss: { _ in })
        #expect(session.chain.bubbleCount == 1)
        #expect(session.chain.bubble(at: 0)?.kind == .assistantReply)
    }

    @Test("空 reply → 不注入")
    func emptyReplyNoOp() {
        let session = makeSession()
        session.injectProactiveSuggestion(context: "深夜", reply: "   ", onDismiss: { _ in })
        #expect(session.chain.bubbleCount == 0)
    }

    private func makeSession(onProactiveBubbleShown: @escaping () -> Void) -> BondedSession {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        return BondedSession(
            attachedToPet: win,
            replyHandler: { _ in "" },
            onProactiveBubbleShown: onProactiveBubbleShown
        )
    }

    @Test("反应路由 B#2:气泡冒出 → 触发 onProactiveBubbleShown(pet perk-up)")
    func bubbleShownFiresSignalCallback() {
        var fired = 0
        let session = makeSession(onProactiveBubbleShown: { fired += 1 })
        session.injectProactiveSuggestion(context: "专注中", reply: "需要帮忙吗", onDismiss: { _ in })
        #expect(fired == 1)
    }

    @Test("空 reply → 不触发 onProactiveBubbleShown(无气泡=无反应)")
    func emptyReplyNoSignal() {
        var fired = 0
        let session = makeSession(onProactiveBubbleShown: { fired += 1 })
        session.injectProactiveSuggestion(context: "专注中", reply: "  ", onDismiss: { _ in })
        #expect(fired == 0)
    }

    @Test("onDismiss 接到 chain.onAutoDismissed")
    func dismissWired() {
        let session = makeSession()
        var dismissed = false
        session.injectProactiveSuggestion(context: "专注中", reply: "需要帮忙吗", onDismiss: { _ in dismissed = true })
        // 直接驱动 chain 回调验证 wiring（不等真实 8s timer）
        session.chain.onAutoDismissed?(false)
        #expect(dismissed == true)
    }
}
