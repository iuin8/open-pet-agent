import RuntimeBridge

public struct BehaviorEngine: Sendable {
    public init() {}

    public func behavior(for state: RenderState) -> CompanionBehavior {
        if state.isSnowEnabled {
            return .snowing
        }
        if state.contactCount > 0 {
            return .tracking
        }
        return .idle
    }
}
