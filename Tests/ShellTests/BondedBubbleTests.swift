import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("BondedBubble — 同列垂直堆叠版 (phase A.5.3 phase 3 v2)")
struct BondedBubbleTests {

    private func makeParent() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 80, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    @Test("init / setText / show / hide 不抛，且 panel 起手 alpha = 0")
    func basicLifecycleDoesNotThrow() {
        let parent = makeParent()
        let bubble = BondedBubble(kind: .userMessage, text: "你好", attachedTo: parent)
        #expect(bubble.panel.alphaValue == 0)

        bubble.setText("你好世界")
        bubble.show()
        bubble.hide()

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("userMessage tail 朝下、偏右 (0.80) 表'用户在右'")
    func userMessageTail() {
        let parent = makeParent()
        let bubble = BondedBubble(kind: .userMessage, text: "嗯", attachedTo: parent)
        bubble.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(bubble.bubbleView.tailSide == .bottom)
        #expect(bubble.tailPercent == BondedBubble.userTailPercent)
        #expect(bubble.tailPercent == 0.80)

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("assistantReply tail 朝下、偏左 (0.20) 表'AI 在左'")
    func assistantReplyTail() {
        let parent = makeParent()
        let bubble = BondedBubble(kind: .assistantReply, text: "好的", attachedTo: parent)
        bubble.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(bubble.bubbleView.tailSide == .bottom)
        #expect(bubble.tailPercent == BondedBubble.assistantTailPercent)
        #expect(bubble.tailPercent == 0.20)

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("userInput backward-compat：与 userMessage 同 tailPercent")
    func userInputBackwardCompatMatchesUserMessage() {
        let parent = makeParent()
        let bubble = BondedBubble(kind: .userInput, text: "x", attachedTo: parent)
        #expect(bubble.tailPercent == BondedBubble.userTailPercent)

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("attachedTo parent 后 panel 是 parent.childWindows 之一（跟随 pet）")
    func attachAddsAsChildWindow() {
        let parent = makeParent()
        let bubble = BondedBubble(kind: .userMessage, text: "test", attachedTo: parent)
        #expect(parent.childWindows?.contains(bubble.panel) == true)

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("默认 reposition：panel x 中心对齐 pet 中心，panel 底缘略低于 pet 顶")
    func repositionCentersPanelAbovePet() {
        let parent = makeParent()  // 200, 200, 80, 80 → midX=240, maxY=280
        let bubble = BondedBubble(kind: .userMessage, text: "hi", attachedTo: parent)

        let panelFrame = bubble.panel.frame
        let expectedX = parent.frame.midX - panelFrame.width / 2
        #expect(abs(panelFrame.origin.x - expectedX) < 0.5)
        // 垂直：parent.maxY - 4，让 tail tip 略低于 pet 顶缘
        let expectedY = parent.frame.maxY - 4
        #expect(abs(panelFrame.origin.y - expectedY) < 0.5)

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("offsetY 正值：panel 上移（assistant 叠在 user 上方）")
    func repositionWithOffsetMovesPanelUp() {
        let parent = makeParent()
        let bubble = BondedBubble(kind: .assistantReply, text: "hi", attachedTo: parent)

        let baseY = bubble.panel.frame.origin.y
        bubble.repositionRelativeTo(parent, offsetY: 60)
        let newY = bubble.panel.frame.origin.y
        #expect(abs(newY - (baseY + 60)) < 0.5)
        // x 仍居中
        let expectedX = parent.frame.midX - bubble.panel.frame.width / 2
        #expect(abs(bubble.panel.frame.origin.x - expectedX) < 0.5)

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("setText 写入 view.currentText（测试访问器路径）")
    func setTextUpdatesView() {
        let parent = makeParent()
        let bubble = BondedBubble(kind: .userMessage, text: "原始", attachedTo: parent)
        bubble.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(bubble.bubbleView.currentText == "原始")

        bubble.setText("替换后")
        #expect(bubble.bubbleView.currentText == "替换后")

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("panel 不抢焦点 / 不拦鼠标（桌宠 drag 必须穿透）")
    func panelDoesNotStealInput() {
        let parent = makeParent()
        let bubble = BondedBubble(kind: .userMessage, text: "x", attachedTo: parent)
        #expect(bubble.panel.ignoresMouseEvents == true)
        #expect(bubble.panel.styleMask.contains(.nonactivatingPanel))

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("BondedBubbleView updateLayer 装配 CALayer.shadowPath + mask")
    func viewInstallsShadowPathAndMask() {
        let view = BondedBubbleView(
            frame: NSRect(x: 0, y: 0, width: 160, height: 80),
            kind: .userMessage,
            tailPercent: BondedBubble.userTailPercent
        )
        view.layoutSubtreeIfNeeded()
        view.updateLayer()
        #expect(view.layer?.shadowPath != nil)
        #expect((view.layer?.shadowOpacity ?? 0) > 0)
        #expect(view.layer?.mask != nil)
    }

    @Test("pet 移动后 bubble.panel 跟随更新 (didMoveNotification 兜底)")
    func bubbleFollowsPetWhenParentMoves() async throws {
        let parent = makeParent()
        let bubble = BondedBubble(kind: .userMessage, text: "follow", attachedTo: parent)
        let initialPanelX = bubble.panel.frame.origin.x

        parent.setFrameOrigin(NSPoint(x: parent.frame.origin.x + 60, y: parent.frame.origin.y))

        try await Task.sleep(nanoseconds: 50_000_000)

        let newPanelX = bubble.panel.frame.origin.x
        #expect(newPanelX > initialPanelX, "panel 应该跟随 parent 向右移动")
        // 新位置：仍居中 pet 中心
        let expectedNewX = parent.frame.midX - bubble.panel.frame.width / 2
        #expect(abs(newPanelX - expectedNewX) < 2.0)

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }
}
