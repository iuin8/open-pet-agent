import AppKit
import QuartzCore
import Orchestrator
import Rendering

// MARK: - PetChatAnimator
//
// AppKit + CALayer helper that translates ChatBehaviorState into animations
// on a given layer. All chat-keyed animations share the "chat." prefix so
// they can be atomically replaced on every state transition.
//
// Design constraints:
// - No retained state; all methods are static.
// - Every apply(_:to:) call cancels all existing chat-* animations first
//   to prevent accumulation across rapid state transitions.
// - Degree values are converted to radians at the call site.

@MainActor
public enum PetChatAnimator {

    // MARK: - Animation key constants

    public static let idleBreathingKey   = "chat.idle.breathing"
    public static let watchingTiltKey    = "chat.watching.tilt"
    public static let thinkingTiltKey    = "chat.thinking.tilt"
    public static let thinkingOpacityKey = "chat.thinking.opacity"
    public static let talkingScaleKey    = "chat.talking.scale"
    public static let confusedShakeKey   = "chat.confused.shake"
    /// LifeSigns 完成跳跃(M2.3) —— `talking → idle` 时触发,
    /// `isAdditive = true` 与 idle breathing translation 叠加不冲突。
    public static let jumpKey            = "chat.jump.translation"

    // MARK: - Public API

    /// Applies the animation suite for the given state to `layer`.
    /// Cancels all prior chat-keyed animations first.
    public static func apply(_ state: ChatBehaviorState, to layer: CALayer) {
        cancelAll(on: layer)
        switch state {
        case .idle:     applyIdle(to: layer)
        case .watching: applyWatching(to: layer)
        case .thinking: applyThinking(to: layer)
        case .talking:  applyTalking(to: layer)
        case .confused: applyConfused(to: layer)
        }
    }

    /// Removes all animations whose key starts with "chat." from the layer.
    public static func cancelAll(on layer: CALayer) {
        let chatKeys = (layer.animationKeys() ?? []).filter { $0.hasPrefix("chat.") }
        for key in chatKeys {
            layer.removeAnimation(forKey: key)
        }
    }

    /// LifeSigns 完成跳跃 —— talking → idle 时(reply 流式结束的语义)由
    /// `DesktopShellController.applyPetChatBehavior` 触发。
    ///
    /// 用 `isAdditive = true` 让 jump 的 `transform.translation.y` 跟 idle
    /// breathing 的 translation.y autoreverse 叠加(不互相覆盖)。jump 0.4s
    /// 内自然结束,下次 state 切换的 `cancelAll` 会清理任何 stale 残留。
    public static func triggerJump(on layer: CALayer) {
        let jump = CAKeyframeAnimation(keyPath: "transform.translation.y")
        jump.values   = [0, -CGFloat(LifeSignsTokens.jumpOffset), 0]
        jump.keyTimes = [0, 0.4, 1]
        jump.duration = LifeSignsTokens.jumpDuration
        jump.timingFunction = AnimTok.easeInOut
        jump.isAdditive = true
        layer.add(jump, forKey: jumpKey)
    }

    // MARK: - State-specific animation builders

    /// `.idle` — slow sinusoidal vertical breathing, repeats forever.
    private static func applyIdle(to layer: CALayer) {
        let anim = CABasicAnimation(keyPath: "transform.translation.y")
        anim.fromValue = -4.0
        anim.toValue   =  4.0
        anim.duration  = AnimTok.breathe
        anim.autoreverses = true
        anim.repeatCount  = .infinity
        anim.timingFunction = AnimTok.easeInOut
        layer.add(anim, forKey: idleBreathingKey)
    }

    /// `.watching` — a +5° tilt held with fillMode .forwards, no repeat.
    private static func applyWatching(to layer: CALayer) {
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.toValue  = 5.0 * .pi / 180.0
        anim.duration = AnimTok.smooth
        anim.timingFunction = AnimTok.easeInOut
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: watchingTiltKey)
    }

    /// `.thinking` — continuous ±8° head-sway + opacity 1.0↔0.85 pulse.
    private static func applyThinking(to layer: CALayer) {
        let tilt = CABasicAnimation(keyPath: "transform.rotation.z")
        tilt.fromValue   = -8.0 * .pi / 180.0
        tilt.toValue     =  8.0 * .pi / 180.0
        tilt.duration    = AnimTok.thinking
        tilt.autoreverses = true
        tilt.repeatCount  = .infinity
        tilt.timingFunction = AnimTok.easeInOut
        layer.add(tilt, forKey: thinkingTiltKey)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue   = 1.0
        opacity.toValue     = 0.85
        opacity.duration    = AnimTok.thinking
        opacity.autoreverses = true
        opacity.repeatCount  = .infinity
        opacity.timingFunction = AnimTok.easeInOut
        layer.add(opacity, forKey: thinkingOpacityKey)
    }

    /// `.talking` — scale burst 1.0→1.12→1.0.
    private static func applyTalking(to layer: CALayer) {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values   = [1.0, 1.12, 1.0]
        scale.keyTimes = [0, 0.5, 1]
        scale.duration = AnimTok.talking
        scale.timingFunction = AnimTok.easeInOut
        layer.add(scale, forKey: talkingScaleKey)
    }

    /// `.confused` — rapid ±12° shake × 3 cycles.
    private static func applyConfused(to layer: CALayer) {
        let deg: (Double) -> Double = { $0 * .pi / 180.0 }
        let shake = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        shake.values   = [deg(0), deg(12), deg(-12), deg(12), deg(0)]
        shake.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        shake.duration = AnimTok.confusedShake
        shake.timingFunction = AnimTok.easeInOut
        layer.add(shake, forKey: confusedShakeKey)
    }
}
