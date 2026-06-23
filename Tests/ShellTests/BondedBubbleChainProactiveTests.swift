import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("BondedBubbleChain 主动建议支持")
struct BondedBubbleChainProactiveTests {
    private func makeChain() -> (BondedBubbleChain, NSWindow) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                           styleMask: [.borderless], backing: .buffered, defer: true)
        return (BondedBubbleChain(attachedTo: win), win)
    }

    @Test("appendProactiveSuggestion → 单颗气泡 + 倒计时启动")
    func proactiveSuggestionSingleBubble() {
        let (chain, _) = makeChain()
        chain.appendProactiveSuggestion(context: "深夜", text: "凌晨了，注意休息")
        #expect(chain.bubbleCount == 1)
        #expect(chain.isDismissCountdownActive == true)
    }

    @Test("appendProactiveSuggestion 唯一气泡 kind == .assistantReply")
    func proactiveSuggestionKind() {
        let (chain, _) = makeChain()
        chain.appendProactiveSuggestion(context: "专注中", text: "需要帮忙吗")
        #expect(chain.bubbleCount == 1)
        #expect(chain.bubble(at: 0)?.kind == .assistantReply)
    }

    @Test("clear 不 fire onAutoDismissed")
    func clearDoesNotFireDismiss() {
        let (chain, _) = makeChain()
        var fired = false
        chain.onAutoDismissed = { _ in fired = true }
        chain.appendProactiveSuggestion(context: "深夜", text: "休息吧")
        chain.clear()
        #expect(fired == false)
    }
}
