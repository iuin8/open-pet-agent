import Foundation

/// Actor that owns the current `LLMProvider` so it can be swapped at runtime
/// without rebuilding the orchestrator. `CompanionOrchestrator` reads
/// `current` on every reply, so the Settings UI can call `set(_:)` after
/// the user saves new credentials and the next chat message routes through
/// the freshly resolved provider — no app restart required.
public actor LLMProviderBox {
    public private(set) var current: (any LLMProvider)?

    public init(_ initial: (any LLMProvider)? = nil) {
        self.current = initial
    }

    public func set(_ provider: (any LLMProvider)?) {
        self.current = provider
    }
}
