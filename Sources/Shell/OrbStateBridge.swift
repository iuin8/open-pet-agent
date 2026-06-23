import Orchestrator
import Rendering

// MARK: - ChatBehaviorState → PetEmotionState
//
// `PetEmotionState` is a 5-case mirror of `ChatBehaviorState` defined in the
// Rendering module so that Rendering does not have to import Orchestrator
// (the dependency runs the other way: Orchestrator → Rendering). This file
// lives in Shell — which already depends on both — and bridges the two.

extension PetEmotionState {
    /// 1-to-1 bridge from the orchestrator's chat state to the renderer's
    /// orb state. Stays in Shell so neither Rendering nor Orchestrator has
    /// to know about the other.
    public static func from(_ chatState: ChatBehaviorState) -> PetEmotionState {
        switch chatState {
        case .idle:     return .idle
        case .watching: return .watching
        case .thinking: return .thinking
        case .talking:  return .talking
        case .confused: return .confused
        }
    }
}
