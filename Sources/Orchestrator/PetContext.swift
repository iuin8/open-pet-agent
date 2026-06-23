import RuntimeBridge

/// Lightweight snapshot of the pet's runtime state at the moment a reply
/// is generated. Injected into the system prompt's [Desktop Context] block
/// so the AI knows what the companion is doing on the user's desktop.
public struct PetContext: Sendable, Equatable {
    public let behavior: CompanionBehavior
    public let isSnowEnabled: Bool

    public init(behavior: CompanionBehavior, isSnowEnabled: Bool) {
        self.behavior = behavior
        self.isSnowEnabled = isSnowEnabled
    }
}
