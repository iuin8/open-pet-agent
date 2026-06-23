import AppKit
import Testing
import Orchestrator
@testable import Shell

@MainActor
@Suite("PetEmotionBubble — state → copy mapping + view wiring")
struct PetEmotionBubbleTests {

    @Test("`.idle` hides the bubble (returns nil)")
    func idleHidesBubble() {
        #expect(PetEmotionBubble.text(for: .idle) == nil)
    }

    @Test(
        "Each non-idle chat state maps to a short Chinese cue",
        arguments: [
            (ChatBehaviorState.watching, "嗯？"),
            (.thinking, "想想…"),
            (.talking, "好啦"),
            (.confused, "嗯？？"),
        ]
    )
    func nonIdleStatesMap(state: ChatBehaviorState, expected: String) {
        #expect(PetEmotionBubble.text(for: state) == expected)
    }

    @Test("Attaching to a parent window adds the panel as a child window")
    func attachAddsAsChildWindow() {
        let parent = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 80, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let bubble = PetEmotionBubble(attachedTo: parent)
        // addChildWindow should have registered the panel as a child.
        #expect(parent.childWindows?.contains(bubble.panel) == true)
        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("updateForState writes the matching copy into the bubble view")
    func updateForStateSetsLabel() {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let bubble = PetEmotionBubble(attachedTo: parent)
        bubble.panel.contentView?.layoutSubtreeIfNeeded()

        bubble.updateForState(.thinking)
        let view = try? #require(bubble.panel.contentView as? PetEmotionBubbleView)
        #expect(view?.currentText == "想想…")

        bubble.updateForState(.talking)
        #expect(view?.currentText == "好啦")

        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("Pet emotion bubble panel ignores mouse so pet stays draggable")
    func panelIgnoresMouse() {
        let parent = NSWindow(
            contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false
        )
        let bubble = PetEmotionBubble(attachedTo: parent)
        // The bubble must NOT intercept mouse — the pet underneath needs
        // mouseDown for drag + showChat to keep working.
        #expect(bubble.panel.ignoresMouseEvents == true)
        parent.orderOut(nil)
        bubble.panel.orderOut(nil)
    }

    @Test("Bubble view installs CALayer shadow path (consistent with chat bubble)")
    func viewShadowConfigured() {
        let view = PetEmotionBubbleView(frame: NSRect(x: 0, y: 0, width: 130, height: 70))
        view.layoutSubtreeIfNeeded()
        view.updateLayer()
        #expect(view.layer?.shadowPath != nil)
        #expect((view.layer?.shadowOpacity ?? 0) > 0)
    }

    @Test("DesktopShellController owns an emotion bubble attached to the pet window")
    func controllerOwnsBubble() {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let bubble = try? #require(controller.petEmotionBubble)
        #expect(controller.windowSet.petWindow.childWindows?.contains(bubble?.panel ?? NSWindow()) == true)
        controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        bubble?.panel.orderOut(nil)
    }

    @Test("applyPetChatBehavior drives the emotion bubble copy")
    func applyPetChatBehaviorUpdatesBubble() {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        controller.applyPetChatBehavior(.thinking)
        let view = controller.petEmotionBubble?.panel.contentView as? PetEmotionBubbleView
        #expect(view?.currentText == "想想…")

        controller.applyPetChatBehavior(.confused)
        #expect(view?.currentText == "嗯？？")

        // `.idle` keeps the last text in the view (it's just faded out)
        // — that's fine because the panel is invisible. We assert the
        // text-mapping helper directly to confirm `.idle` returns nil.
        #expect(PetEmotionBubble.text(for: .idle) == nil)

        controller.windowSet.allWindows.forEach { $0.orderOut(nil) }
        controller.petEmotionBubble?.panel.orderOut(nil)
    }
}
