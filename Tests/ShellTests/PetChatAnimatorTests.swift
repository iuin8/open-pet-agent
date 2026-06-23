import AppKit
import QuartzCore
import Testing
@testable import Shell
@testable import Orchestrator

// MARK: - PetChatAnimatorTests

@Suite("PetChatAnimator")
@MainActor
struct PetChatAnimatorTests {

    // MARK: - Key presence per state

    @Test("apply idle adds idle breathing animation key")
    func applyIdleAddsIdleBreathingKey() {
        let layer = CALayer()
        PetChatAnimator.apply(.idle, to: layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.idleBreathingKey))
    }

    @Test("apply watching adds watching tilt animation key")
    func applyWatchingAddsWatchingTiltKey() {
        let layer = CALayer()
        PetChatAnimator.apply(.watching, to: layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.watchingTiltKey))
    }

    @Test("apply thinking adds both thinking tilt and opacity keys")
    func applyThinkingAddsTiltAndOpacityKeys() {
        let layer = CALayer()
        PetChatAnimator.apply(.thinking, to: layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.thinkingTiltKey))
        #expect(keys.contains(PetChatAnimator.thinkingOpacityKey))
    }

    @Test("apply talking adds talking scale animation key")
    func applyTalkingAddsTalkingScaleKey() {
        let layer = CALayer()
        PetChatAnimator.apply(.talking, to: layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.talkingScaleKey))
    }

    @Test("apply confused adds confused shake animation key")
    func applyConfusedAddsConfusedShakeKey() {
        let layer = CALayer()
        PetChatAnimator.apply(.confused, to: layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.confusedShakeKey))
    }

    // MARK: - No accumulation on re-apply

    @Test("re-applying a different state replaces all previous chat animations")
    func reApplyingDifferentStateReplacesPreviousChatAnimations() {
        let layer = CALayer()
        PetChatAnimator.apply(.thinking, to: layer)
        PetChatAnimator.apply(.idle, to: layer)
        let keys = layer.animationKeys() ?? []
        #expect(keys.contains(PetChatAnimator.idleBreathingKey))
        #expect(keys.contains(PetChatAnimator.thinkingTiltKey) == false)
        #expect(keys.contains(PetChatAnimator.thinkingOpacityKey) == false)
    }

    @Test("applying idle twice does not accumulate extra animation keys")
    func applyingIdleTwiceDoesNotAccumulateExtraKeys() {
        let layer = CALayer()
        PetChatAnimator.apply(.idle, to: layer)
        PetChatAnimator.apply(.idle, to: layer)
        let keys = layer.animationKeys() ?? []
        // Only the idle key should be present; no duplicates under a different name
        let chatKeys = keys.filter { $0.hasPrefix("chat.") }
        #expect(chatKeys.count == 1)
        #expect(keys.contains(PetChatAnimator.idleBreathingKey))
    }

    // MARK: - cancelAll

    @Test("cancelAll removes all chat-prefixed animation keys")
    func cancelAllRemovesAllChatPrefixedKeys() {
        let layer = CALayer()
        PetChatAnimator.apply(.thinking, to: layer)
        PetChatAnimator.cancelAll(on: layer)
        let keys = layer.animationKeys() ?? []
        let chatKeys = keys.filter { $0.hasPrefix("chat.") }
        #expect(chatKeys.isEmpty)
    }

    @Test("cancelAll on a layer with no animations is a no-op")
    func cancelAllOnEmptyLayerIsNoOp() {
        let layer = CALayer()
        PetChatAnimator.cancelAll(on: layer)
        #expect((layer.animationKeys() ?? []).isEmpty)
    }

    // MARK: - Animation parameter spot-checks

    @Test("idle breathing animation repeats forever and autoreverses")
    func idleBreathingAnimationRepeatsForeverAndAutoreverses() {
        let layer = CALayer()
        PetChatAnimator.apply(.idle, to: layer)
        guard let anim = layer.animation(forKey: PetChatAnimator.idleBreathingKey) as? CABasicAnimation else {
            Issue.record("Expected CABasicAnimation for idle breathing")
            return
        }
        #expect(anim.repeatCount == .infinity)
        #expect(anim.autoreverses == true)
        #expect(abs(anim.duration - 1.8) < 0.01)
    }

    @Test("thinking tilt animation repeats forever")
    func thinkingTiltAnimationRepeatsForever() {
        let layer = CALayer()
        PetChatAnimator.apply(.thinking, to: layer)
        guard let anim = layer.animation(forKey: PetChatAnimator.thinkingTiltKey) as? CABasicAnimation else {
            Issue.record("Expected CABasicAnimation for thinking tilt")
            return
        }
        #expect(anim.repeatCount == .infinity)
        #expect(anim.autoreverses == true)
        #expect(abs(anim.duration - 0.6) < 0.01)
    }

    @Test("thinking opacity animation repeats forever")
    func thinkingOpacityAnimationRepeatsForever() {
        let layer = CALayer()
        PetChatAnimator.apply(.thinking, to: layer)
        guard let anim = layer.animation(forKey: PetChatAnimator.thinkingOpacityKey) as? CABasicAnimation else {
            Issue.record("Expected CABasicAnimation for thinking opacity")
            return
        }
        #expect(anim.repeatCount == .infinity)
        #expect(anim.autoreverses == true)
        #expect(abs(anim.duration - 0.6) < 0.01)
    }

    @Test("talking scale animation uses keyframe animation with correct duration")
    func talkingScaleAnimationUsesKeyframeWithCorrectDuration() {
        let layer = CALayer()
        PetChatAnimator.apply(.talking, to: layer)
        guard let anim = layer.animation(forKey: PetChatAnimator.talkingScaleKey) as? CAKeyframeAnimation else {
            Issue.record("Expected CAKeyframeAnimation for talking scale")
            return
        }
        #expect(abs(anim.duration - 0.4) < 0.01)
        #expect((anim.values?.count ?? 0) == 3)
    }

    @Test("confused shake animation uses keyframe animation with correct duration")
    func confusedShakeAnimationUsesKeyframeWithCorrectDuration() {
        let layer = CALayer()
        PetChatAnimator.apply(.confused, to: layer)
        guard let anim = layer.animation(forKey: PetChatAnimator.confusedShakeKey) as? CAKeyframeAnimation else {
            Issue.record("Expected CAKeyframeAnimation for confused shake")
            return
        }
        #expect(abs(anim.duration - 0.5) < 0.01)
        #expect((anim.values?.count ?? 0) == 5)
    }

    @Test("watching tilt animation does not repeat and preserves fill mode")
    func watchingTiltAnimationDoesNotRepeat() {
        let layer = CALayer()
        PetChatAnimator.apply(.watching, to: layer)
        guard let anim = layer.animation(forKey: PetChatAnimator.watchingTiltKey) as? CABasicAnimation else {
            Issue.record("Expected CABasicAnimation for watching tilt")
            return
        }
        #expect(anim.repeatCount <= 1)
        #expect(anim.isRemovedOnCompletion == false)
        #expect(anim.fillMode == .forwards)
        #expect(abs(anim.duration - 0.2) < 0.01)
    }
}
