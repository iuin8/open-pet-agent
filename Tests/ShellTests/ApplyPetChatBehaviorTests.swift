import AppKit
import QuartzCore
import Testing
@testable import Shell
@testable import Orchestrator

// MARK: - DesktopShellController.applyPetChatBehavior Tests

@Suite("DesktopShellController.applyPetChatBehavior")
@MainActor
struct ApplyPetChatBehaviorTests {

    @Test("pet contentView has wantsLayer true after controller init")
    func petContentViewHasWantsLayerTrue() throws {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        let contentView = try #require(controller.windowSet.petWindow.contentView)
        #expect(contentView.wantsLayer == true)
    }

    @Test("applyPetChatBehavior thinking adds thinking animation keys to pet layer")
    func applyPetChatBehaviorThinkingAddsAnimationKeys() throws {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        controller.applyPetChatBehavior(.thinking)

        let layer = try #require(controller.windowSet.petWindow.contentView?.layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.thinkingTiltKey))
        #expect(keys.contains(PetChatAnimator.thinkingOpacityKey))
    }

    @Test("applyPetChatBehavior idle adds idle breathing key to pet layer")
    func applyPetChatBehaviorIdleAddsIdleKey() throws {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        controller.applyPetChatBehavior(.idle)

        let layer = try #require(controller.windowSet.petWindow.contentView?.layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.idleBreathingKey))
    }

    @Test("applyPetChatBehavior talking adds talking scale key to pet layer")
    func applyPetChatBehaviorTalkingAddsTalkingKey() throws {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        controller.applyPetChatBehavior(.talking)

        let layer = try #require(controller.windowSet.petWindow.contentView?.layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.talkingScaleKey))
    }

    @Test("applyPetChatBehavior replaces existing chat animations on state transition")
    func applyPetChatBehaviorReplacesExistingAnimationsOnStateTransition() throws {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        controller.applyPetChatBehavior(.thinking)
        controller.applyPetChatBehavior(.idle)

        let layer = try #require(controller.windowSet.petWindow.contentView?.layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.idleBreathingKey))
        #expect(keys.contains(PetChatAnimator.thinkingTiltKey) == false)
    }

    @Test("applyPetChatBehavior talking → idle triggers LifeSigns jump on pet layer (M2.3)")
    func applyPetChatBehaviorTalkingToIdleTriggersJump() throws {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        controller.applyPetChatBehavior(.talking)
        controller.applyPetChatBehavior(.idle)

        let layer = try #require(controller.windowSet.petWindow.contentView?.layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.jumpKey))
        // jump 与 idle breathing additive 叠加,两者共存。
        #expect(keys.contains(PetChatAnimator.idleBreathingKey))
    }

    @Test("applyPetChatBehavior idle → idle does NOT trigger jump (only talking → idle does)")
    func applyPetChatBehaviorIdleToIdleDoesNotTriggerJump() throws {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        controller.applyPetChatBehavior(.idle)
        controller.applyPetChatBehavior(.idle)

        let layer = try #require(controller.windowSet.petWindow.contentView?.layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.jumpKey) == false)
    }

    @Test("applyPetChatBehavior talking → talking does NOT trigger jump (no transition to idle)")
    func applyPetChatBehaviorTalkingToTalkingDoesNotTriggerJump() throws {
        let controller = DesktopShellController(
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        defer { controller.windowSet.allWindows.forEach { $0.orderOut(nil) } }

        controller.applyPetChatBehavior(.talking)
        controller.applyPetChatBehavior(.talking)

        let layer = try #require(controller.windowSet.petWindow.contentView?.layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.jumpKey) == false)
    }
}
