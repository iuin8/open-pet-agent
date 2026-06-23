import Context

/// Hot-injection box for runtime context providers.
///
/// Mirrors the `LLMProviderBox` pattern: an actor that owns mutable closures
/// so they can be set (or replaced) after app launch without rebuilding the
/// orchestrator.  `CompanionOrchestrator` reads both providers on every
/// `reply(to:)` call, so:
///
/// - `snapshotProvider` is wired in `AppBootstrap.makeRootSystem()` where the
///   `DesktopSnapshotSampler` is available.
/// - `petContextProvider` is wired in `MinimalAppDelegate.applicationDidFinishLaunching`
///   once `currentRenderState` / `isSnowEnabled` are live.
public actor LiveContextBox {
    public private(set) var snapshotProvider: (@Sendable () async -> DesktopSnapshot)?
    public private(set) var petContextProvider: (@Sendable () async -> PetContext)?

    /// Most recent non-self frontmost application name. Updated by `observe(snapshot:selfName:)`
    /// whenever a reply pulls a snapshot where the frontmost app isn't OpenPetAgent itself.
    /// Lets the chat continue to mention what the user was doing right before they
    /// clicked into the chat window (e.g. "you were writing Swift in Xcode a moment ago").
    public private(set) var lastNonSelfApplicationName: String?

    public init() {}

    public func setSnapshotProvider(
        _ provider: @escaping @Sendable () async -> DesktopSnapshot
    ) {
        snapshotProvider = provider
    }

    public func setPetContextProvider(
        _ provider: @escaping @Sendable () async -> PetContext
    ) {
        petContextProvider = provider
    }

    /// Inspect a freshly sampled snapshot and remember the frontmost app unless it
    /// is OpenPetAgent itself. Called by `CompanionOrchestrator.reply` right after
    /// pulling the snapshot, before building the system prompt.
    public func observe(
        snapshot: DesktopSnapshot?,
        selfApplicationName: String?
    ) {
        guard
            let appName = snapshot?.visibleApplicationName,
            !appName.isEmpty,
            appName != selfApplicationName
        else { return }
        lastNonSelfApplicationName = appName
    }
}
