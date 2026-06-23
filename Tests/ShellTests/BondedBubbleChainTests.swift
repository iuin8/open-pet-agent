import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("BondedBubbleChain — 同列垂直堆叠 + 自动消失 (phase A.5.3 phase 3 v2)")
struct BondedBubbleChainTests {

    private func makeParent() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 80, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    private func teardown(_ parent: NSWindow, _ chain: BondedBubbleChain) {
        chain.clear()
        parent.orderOut(nil)
    }

    @Test("空链初始化：bubbleCount == 0，bubble(at: 0) == nil")
    func emptyChainOnInit() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        #expect(chain.bubbleCount == 0)
        #expect(chain.bubble(at: 0) == nil)
        teardown(parent, chain)
    }

    @Test("appendUserMessage 后 bubbleCount == 1，索引 0 kind == .userMessage")
    func appendUserMessageStartsRound() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("你好")
        #expect(chain.bubbleCount == 1)
        #expect(chain.bubble(at: 0)?.kind == .userMessage)
        #expect(chain.bubble(at: 0)?.tailPercent == BondedBubble.userTailPercent)
        teardown(parent, chain)
    }

    @Test("user + assistant：索引 0 = user，索引 1 = assistant")
    func userPlusAssistantInOneRound() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("Q1")
        chain.appendAssistantReply("A1")
        #expect(chain.bubbleCount == 2)
        #expect(chain.bubble(at: 0)?.kind == .userMessage)
        #expect(chain.bubble(at: 1)?.kind == .assistantReply)
        teardown(parent, chain)
    }

    @Test("user / assistant 同列：x 中心都对齐 pet 中心")
    func bothBubblesCenteredOverPet() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("Q1")
        chain.appendAssistantReply("A1")

        let userPanel = chain.bubble(at: 0)!.panel.frame
        let assistantPanel = chain.bubble(at: 1)!.panel.frame
        let petCenter = parent.frame.midX

        #expect(abs(userPanel.midX - petCenter) < 0.5)
        #expect(abs(assistantPanel.midX - petCenter) < 0.5)
        teardown(parent, chain)
    }

    @Test("assistant 在 user 上方：assistant.panel.minY > user.panel.maxY")
    func assistantStacksAboveUser() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("Q")
        chain.appendAssistantReply("A")

        let userPanel = chain.bubble(at: 0)!.panel.frame
        let assistantPanel = chain.bubble(at: 1)!.panel.frame
        #expect(assistantPanel.minY >= userPanel.maxY,
                "assistant 应叠在 user 上方（AppKit y 增大向上）")
        teardown(parent, chain)
    }

    @Test("新一轮 appendUserMessage 自动 clear 旧轮")
    func newRoundClearsOldOne() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("Q1")
        chain.appendAssistantReply("A1")
        let oldUserPanel = chain.bubble(at: 0)!.panel
        let oldAssistantPanel = chain.bubble(at: 1)!.panel
        #expect(chain.bubbleCount == 2)

        chain.appendUserMessage("Q2")
        #expect(chain.bubbleCount == 1)
        #expect(chain.bubble(at: 0)?.currentText == "Q2")
        #expect(parent.childWindows?.contains(oldUserPanel) != true)
        #expect(parent.childWindows?.contains(oldAssistantPanel) != true)

        teardown(parent, chain)
    }

    @Test("appendUserInput 别名等价 appendUserMessage")
    func userInputAliasMatchesUserMessage() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserInput("legacy")
        #expect(chain.bubbleCount == 1)
        #expect(chain.bubble(at: 0)?.kind == .userMessage)
        #expect(chain.bubble(at: 0)?.currentText == "legacy")
        teardown(parent, chain)
    }

    @Test("链长上限 = maxBubbles (2)")
    func chainLengthClamped() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("u")
        chain.appendAssistantReply("a")
        #expect(chain.bubbleCount == BondedBubbleChain.maxBubbles)
        chain.appendAssistantReply("a2")
        #expect(chain.bubbleCount == BondedBubbleChain.maxBubbles)
        #expect(chain.bubble(at: 1)?.currentText == "a2")
        teardown(parent, chain)
    }

    @Test("clear() 后 bubbleCount == 0，parent.childWindows 不再含链中 panel")
    func clearRemovesAllBubbles() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("x")
        chain.appendAssistantReply("y")
        let panelsBeforeClear: [NSWindow] = (0..<chain.bubbleCount).compactMap {
            chain.bubble(at: $0)?.panel
        }
        #expect(chain.bubbleCount == 2)

        chain.clear()
        #expect(chain.bubbleCount == 0)
        for panel in panelsBeforeClear {
            #expect(parent.childWindows?.contains(panel) != true)
        }
        parent.orderOut(nil)
    }

    @Test("链中所有 panel 都是 parent 的 childWindow（跟随桌宠移动）")
    func allBubblesAreChildWindowsOfParent() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("a")
        chain.appendAssistantReply("b")
        for i in 0..<chain.bubbleCount {
            guard let panel = chain.bubble(at: i)?.panel else {
                Issue.record("bubble(at: \(i)) returned nil")
                continue
            }
            #expect(parent.childWindows?.contains(panel) == true)
        }
        teardown(parent, chain)
    }

    // MARK: - Auto dismiss

    @Test("appendAssistantReply 启动 dismiss countdown（user 也参与一起消）")
    func assistantReplyStartsDismissCountdown() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("Q")
        #expect(chain.isDismissCountdownActive == false,
                "user 单独存在不启动倒计时，等 assistant 一起")
        chain.appendAssistantReply("A")
        #expect(chain.isDismissCountdownActive == true)
        #expect(chain.dismissRemainingForTest == BondedBubbleChain.autoDismissSeconds)
        teardown(parent, chain)
    }

    @Test("clear() 取消 dismiss countdown")
    func clearCancelsCountdown() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("Q")
        chain.appendAssistantReply("A")
        #expect(chain.isDismissCountdownActive == true)
        chain.clear()
        #expect(chain.isDismissCountdownActive == false)
        #expect(chain.dismissRemainingForTest == nil)
        parent.orderOut(nil)
    }

    @Test("新一轮 appendUserMessage 取消旧倒计时（clear 路径）")
    func newRoundResetsCountdown() {
        let parent = makeParent()
        let chain = BondedBubbleChain(attachedTo: parent)
        chain.appendUserMessage("Q1")
        chain.appendAssistantReply("A1")
        #expect(chain.isDismissCountdownActive == true)
        chain.appendUserMessage("Q2")
        #expect(chain.isDismissCountdownActive == false,
                "新一轮 user 单独存在时倒计时已 cancel，等下一颗 assistant")
        teardown(parent, chain)
    }
}
