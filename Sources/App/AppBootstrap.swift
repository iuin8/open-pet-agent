import AppKit
import Context
import Orchestrator
import Rendering
import RuntimeBridge
import Shell
import ToolMode

public struct AppRootSystem: Sendable, Equatable {
    public let snapshot: DesktopSnapshot
    public let windowGraph: WindowGraph
    public let companionBootstrap: CompanionBootstrap
    public let runtimeTicker: RuntimeTicker
    public let conversationResponder: ConversationResponder
    /// 对话历史存储引用。对话卡片（`ChatCardWindowController`）的
    /// `historyProvider` 读它恢复多轮历史;orchestrator `replyStream` 写它（每轮
    /// user/assistant 落盘 + 拼上下文）。nil 时不持久化(测试 / 老调用方兼容)。
    public let conversationStore: ConversationStore?
    /// 阶段 4 — 主动建议生成器（no-history 入口）。`makeRootSystem` 把内部
    /// `CompanionOrchestrator` 以 `ProactiveSuggestionGenerating` 暴露出来,让
    /// `MinimalAppDelegate.setupProactiveEngine` 复用同一 orchestrator 拼
    /// system prompt(共享 buildSystemPrompt)。nil 时主动引擎不构造(测试 /
    /// 老调用方兼容)。
    public let proactiveGenerator: (any ProactiveSuggestionGenerating)?

    public init(
        snapshot: DesktopSnapshot,
        windowGraph: WindowGraph,
        companionBootstrap: CompanionBootstrap,
        runtimeTicker: RuntimeTicker,
        conversationResponder: ConversationResponder,
        conversationStore: ConversationStore? = nil,
        proactiveGenerator: (any ProactiveSuggestionGenerating)? = nil
    ) {
        self.snapshot = snapshot
        self.windowGraph = windowGraph
        self.companionBootstrap = companionBootstrap
        self.runtimeTicker = runtimeTicker
        self.conversationResponder = conversationResponder
        self.conversationStore = conversationStore
        self.proactiveGenerator = proactiveGenerator
    }

    /// 自定义 == : `ConversationStore` 是 actor,没有 Equatable 合成。其余字段
    /// 仍按值比较;store 字段按引用身份比对(同一 actor 实例视为相等,nil ↔ nil
    /// 视为相等),避免破坏现有 Equatable 合成。这里只在测试断言里被使用。
    public static func == (lhs: AppRootSystem, rhs: AppRootSystem) -> Bool {
        guard lhs.snapshot == rhs.snapshot,
              lhs.windowGraph == rhs.windowGraph,
              lhs.companionBootstrap == rhs.companionBootstrap,
              lhs.runtimeTicker == rhs.runtimeTicker,
              lhs.conversationResponder == rhs.conversationResponder
        else { return false }
        switch (lhs.conversationStore, rhs.conversationStore) {
        case (nil, nil): return true
        case let (l?, r?): return l === r
        default: return false
        }
    }
}

public struct ConversationResponder: Sendable, Equatable {
    private let replyHandler: @Sendable (String) async -> String
    /// A.1.3: streaming variant — returns a live stream of delta tokens.
    /// Each yielded value is an incremental token string. The caller accumulates.
    private let streamProvider: @Sendable (String) -> AsyncThrowingStream<String, Error>
    /// Task C — Spotlight QuickAsk 一次性流式 provider。
    /// 与 `streamProvider` 行为差异:**不写 ConversationStore + 不通知状态机**,
    /// 用于 QuickAsk 浮窗这类不应污染 pet 头顶 bonded session 历史的场景。
    /// 默认实现回退到 `streamProvider`(向后兼容老调用方)。
    private let oneShotStreamProvider: @Sendable (String) -> AsyncThrowingStream<String, Error>

    /// Backward-compatible init for existing callers that only need atomic reply.
    /// The streaming provider defaults to wrapping the atomic reply as a single-chunk stream.
    public init(replyHandler: @escaping @Sendable (String) async -> String) {
        self.replyHandler = replyHandler
        let capturedReply = replyHandler
        let stream: @Sendable (String) -> AsyncThrowingStream<String, Error> = { message in
            AsyncThrowingStream { continuation in
                Task {
                    let reply = await capturedReply(message)
                    continuation.yield(reply)
                    continuation.finish()
                }
            }
        }
        self.streamProvider = stream
        self.oneShotStreamProvider = stream
    }

    /// Full init with explicit streaming provider. Used by `AppBootstrap.makeRootSystem`.
    /// `oneShotStreamProvider` 默认 fallback 到 `streamProvider`(向后兼容);
    /// QuickAsk 路径调用方应显式注入独立的 oneShot 实现。
    public init(
        replyHandler: @escaping @Sendable (String) async -> String,
        streamProvider: @escaping @Sendable (String) -> AsyncThrowingStream<String, Error>,
        oneShotStreamProvider: (@Sendable (String) -> AsyncThrowingStream<String, Error>)? = nil
    ) {
        self.replyHandler = replyHandler
        self.streamProvider = streamProvider
        self.oneShotStreamProvider = oneShotStreamProvider ?? streamProvider
    }

    public func reply(to message: String) async -> String {
        await replyHandler(message)
    }

    /// A.1.3: returns a live stream of incremental delta strings.
    /// The caller is responsible for accumulating deltas and updating UI.
    public func replyStream(for message: String) -> AsyncThrowingStream<String, Error> {
        streamProvider(message)
    }

    /// Task C — QuickAsk 一次性流式问答(不写历史 / 不触发状态机)。
    public func replyStreamOneShot(for message: String) -> AsyncThrowingStream<String, Error> {
        oneShotStreamProvider(message)
    }

    public static func == (_: ConversationResponder, _: ConversationResponder) -> Bool {
        true
    }
}

public struct RuntimeTickResult: Sendable, Equatable {
    public let renderState: RenderState
    public let snapshot: DesktopSnapshot

    public init(renderState: RenderState, snapshot: DesktopSnapshot) {
        self.renderState = renderState
        self.snapshot = snapshot
    }
}

public struct RuntimeTicker: Sendable, Equatable {
    private let tickHandler: @Sendable (RenderState, Double, Bool) async throws -> RuntimeTickResult

    public init(tickHandler: @escaping @Sendable (RenderState, Double, Bool) async throws -> RuntimeTickResult) {
        self.tickHandler = tickHandler
    }

    public func tick(
        previousRenderState: RenderState,
        deltaTime: Double,
        wantsParticles: Bool = true
    ) async throws -> RuntimeTickResult {
        try await tickHandler(previousRenderState, deltaTime, wantsParticles)
    }

    public static func == (_: RuntimeTicker, _: RuntimeTicker) -> Bool {
        true
    }
}

/// The LLM provider backend the user has selected.
///
/// Stored in `UserDefaults` under the key `"LLMProvider"` as the raw string value.
/// Defaults to `.openAICompatible` when the key is absent or holds an unrecognised value.
public enum LLMProviderKind: String, Sendable, CaseIterable {
    /// OpenAI Chat Completions-compatible endpoint (also supports DeepSeek, Groq,
    /// Ollama via a custom base URL, etc.).
    case openAICompatible
    /// Anthropic Messages API — uses `x-api-key` auth, `system` top-level field,
    /// and its own SSE event format.
    case anthropic

    /// UserDefaults key used to persist the selection.
    public static let userDefaultsKey = "LLMProvider"

    /// Resolve from UserDefaults, falling back to `.openAICompatible`.
    public static func resolve(from userDefaults: UserDefaults) -> LLMProviderKind {
        guard let raw = userDefaults.string(forKey: userDefaultsKey),
              let kind = LLMProviderKind(rawValue: raw)
        else {
            return .openAICompatible
        }
        return kind
    }
}

/// Resolved LLM configuration: API key, base URL, model, and the derived
/// endpoint URL. Created by `AppBootstrap.resolveLLMConfig(userDefaults:)`.
public struct LLMConfig: Sendable, Equatable {
    /// The raw base URL (e.g. `https://api.deepseek.com/v1`). Trailing
    /// slashes are already stripped.
    public let baseURL: URL

    /// The model name to pass in the request body (e.g. `gpt-4o-mini`).
    public let model: String

    /// The resolved API key, or nil when no key is configured.
    public let apiKey: String?

    /// The fully-formed chat completions endpoint: `{baseURL}/chat/completions`.
    public var endpoint: URL {
        baseURL.appendingPathComponent("chat/completions")
    }
}

public struct AppBootstrap: Sendable {
    private let orchestrator: CompanionOrchestrator
    private let windowGraph: WindowGraph
    private let snapshot: DesktopSnapshot?
    private let snapshotSampler: DesktopSnapshotSampler

    /// Exposed so the Settings UI can hot-swap the LLM provider after the
    /// user saves new credentials. Shared by reference with the orchestrator
    /// inside `conversationResponder`, so a `set(_:)` call here propagates
    /// to all in-flight and future `reply(to:)` calls without an app restart.
    public var llmProviderBox: LLMProviderBox { orchestrator.llmProviderBox }

    /// Exposed so tests can verify the store is wired and loaded.
    /// Mirrors the same pattern as `llmProviderBox`.
    public let conversationStore: ConversationStore

    /// Shared hot-injection box for desktop snapshot and pet context providers.
    ///
    /// - `snapshotProvider` is set in `makeRootSystem()` once the sampler is ready.
    /// - `petContextProvider` is set by `MinimalAppDelegate.applicationDidFinishLaunching`
    ///   after the render state machine is running.
    public let liveContextBox: LiveContextBox

    // MARK: - LLM configuration resolution

    /// Resolve all LLM configuration using the priority chain:
    ///
    /// **Base URL:**
    ///   1. `userDefaults[LLMSettingsKeys.openAIBaseURL]` (non-empty after trimming)
    ///   2. Environment variable `OPENAI_BASE_URL`
    ///   3. `https://api.openai.com/v1`
    ///
    /// **Model:**
    ///   1. `userDefaults[LLMSettingsKeys.openAIModel]` (non-empty after trimming)
    ///   2. Environment variable `OPENAI_MODEL`
    ///   3. `gpt-4o-mini`
    ///
    /// **API key:**
    ///   1. `userDefaults[LLMSettingsKeys.openAIApiKey]` (非空 trimmed)
    ///   2. Environment variable `OPENAI_API_KEY`
    ///   3. nil(provider 仍会为 Ollama 类自建端点实例化)
    ///
    /// 如果 base URL 字符串无法构造合法 `URL`,会回退到默认
    /// `https://api.openai.com/v1`,而不是 crash。
    ///
    /// - Parameters:
    ///   - userDefaults: 读取 apiKey / baseURL / model 的 `UserDefaults` suite。
    ///     默认 `.standard`;测试可注入隔离 suite。
    public static func resolveLLMConfig(
        userDefaults: UserDefaults = .standard
    ) -> LLMConfig {
        let env = ProcessInfo.processInfo.environment

        // --- Base URL ---
        let defaultBaseURLString = "https://api.openai.com/v1"
        let rawBaseURLString: String
        let udBaseURL = (userDefaults.string(forKey: LLMSettingsKeys.openAIBaseURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if udBaseURL.isEmpty == false {
            rawBaseURLString = udBaseURL
        } else if let envURL = env["OPENAI_BASE_URL"], envURL.isEmpty == false {
            rawBaseURLString = envURL
        } else {
            rawBaseURLString = defaultBaseURLString
        }
        // Strip trailing slash before building the endpoint.
        let normalizedBaseURLString = rawBaseURLString.hasSuffix("/")
            ? String(rawBaseURLString.dropLast())
            : rawBaseURLString
        let baseURL = URL(string: normalizedBaseURLString)
            ?? URL(string: defaultBaseURLString)!

        // --- Model ---
        let defaultModel = "gpt-4o-mini"
        let udModel = (userDefaults.string(forKey: LLMSettingsKeys.openAIModel) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model: String
        if udModel.isEmpty == false {
            model = udModel
        } else if let envModel = env["OPENAI_MODEL"], envModel.isEmpty == false {
            model = envModel
        } else {
            model = defaultModel
        }

        // --- API key ---
        let apiKey: String?
        let udKey = (userDefaults.string(forKey: LLMSettingsKeys.openAIApiKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if udKey.isEmpty == false {
            apiKey = udKey
        } else if let envKey = env["OPENAI_API_KEY"], envKey.isEmpty == false {
            apiKey = envKey
        } else {
            apiKey = nil
        }

        return LLMConfig(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    /// Resolve the LLM provider using the full priority chain for
    /// base URL, model, and API key. Returns nil only when no API
    /// key is configured **and** the resolved endpoint requires one.
    ///
    /// Routes to `AnthropicProvider` when `UserDefaults["LLMProvider"] == "anthropic"`;
    /// otherwise falls through to `OpenAIProvider` (default, backward-compatible).
    ///
    /// Resolution order mirrors `resolveLLMConfig(userDefaults:)`.
    public static func resolveLLMProvider(
        userDefaults: UserDefaults = .standard
    ) -> (any LLMProvider)? {
        let kind = LLMProviderKind.resolve(from: userDefaults)

        switch kind {
        case .anthropic:
            return resolveAnthropicProvider(userDefaults: userDefaults)
        case .openAICompatible:
            return resolveOpenAICompatibleProvider(userDefaults: userDefaults)
        }
    }

    // MARK: - Provider-specific resolution helpers

    private static func resolveAnthropicProvider(
        userDefaults: UserDefaults
    ) -> (any LLMProvider)? {
        let env = ProcessInfo.processInfo.environment

        // API key: UserDefaults AnthropicAPIKey → env ANTHROPIC_API_KEY → nil
        let apiKey: String?
        let udKey = (userDefaults.string(forKey: LLMSettingsKeys.anthropicApiKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if udKey.isEmpty == false {
            apiKey = udKey
        } else if let envKey = env["ANTHROPIC_API_KEY"], envKey.isEmpty == false {
            apiKey = envKey
        } else {
            apiKey = nil
        }

        guard let effectiveKey = apiKey, effectiveKey.isEmpty == false else {
            return nil
        }

        // Model: UserDefaults AnthropicModel → env ANTHROPIC_MODEL → claude-sonnet-4-5
        let defaultModel = "claude-sonnet-4-5"
        let udModel = (userDefaults.string(forKey: LLMSettingsKeys.anthropicModel) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model: String
        if udModel.isEmpty == false {
            model = udModel
        } else if let envModel = env["ANTHROPIC_MODEL"], envModel.isEmpty == false {
            model = envModel
        } else {
            model = defaultModel
        }

        // Base URL: UserDefaults AnthropicBaseURL → env ANTHROPIC_BASE_URL →
        // default https://api.anthropic.com. Endpoint always appends
        // "/v1/messages" (Anthropic's Messages API path). Empty / invalid
        // values fall back to the official endpoint.
        let defaultBaseURLString = "https://api.anthropic.com"
        let udBaseURL = (userDefaults.string(forKey: LLMSettingsKeys.anthropicBaseURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBaseURL: String
        if udBaseURL.isEmpty == false {
            rawBaseURL = udBaseURL
        } else if let envURL = env["ANTHROPIC_BASE_URL"], envURL.isEmpty == false {
            rawBaseURL = envURL
        } else {
            rawBaseURL = defaultBaseURLString
        }
        let normalizedBase = rawBaseURL.hasSuffix("/")
            ? String(rawBaseURL.dropLast())
            : rawBaseURL
        let baseURL = URL(string: normalizedBase)
            ?? URL(string: defaultBaseURLString)!
        let endpoint = baseURL.appendingPathComponent("v1/messages")

        return AnthropicProvider(apiKey: effectiveKey, model: model, endpoint: endpoint)
    }

    private static func resolveOpenAICompatibleProvider(
        userDefaults: UserDefaults
    ) -> (any LLMProvider)? {
        let config = resolveLLMConfig(userDefaults: userDefaults)
        let isDefaultEndpoint = config.baseURL == URL(string: "https://api.openai.com/v1")!
        let effectiveKey = config.apiKey ?? ""

        // When there is no key and we are hitting the default OpenAI
        // endpoint, skip instantiation to preserve the echo fallback.
        if effectiveKey.isEmpty && isDefaultEndpoint {
            return nil
        }

        return OpenAIProvider(
            apiKey: effectiveKey,
            model: config.model,
            endpoint: config.endpoint
        )
    }

    public init(
        orchestrator: CompanionOrchestrator = CompanionOrchestrator(),
        conversationStore: ConversationStore = ConversationStore(),
        windowGraph: WindowGraph = .bootstrap,
        snapshot: DesktopSnapshot? = nil,
        snapshotSampler: DesktopSnapshotSampler? = nil,
        toolModeBox: ToolModeBox = ToolModeBox()
    ) {
        let box = LiveContextBox()
        // Re-create orchestrator with the box wired in so it can read
        // snapshotProvider / petContextProvider on every reply.
        // Propagate modelName so the rolling-window budget uses the same model heuristic.
        let wiredOrchestrator = CompanionOrchestrator(
            llmProviderBox: orchestrator.llmProviderBox,
            toolModeBox: toolModeBox,
            conversationStore: conversationStore,
            liveContextBox: box,
            modelName: orchestrator.modelName
        )
        self.orchestrator = wiredOrchestrator
        self.conversationStore = conversationStore
        self.liveContextBox = box
        self.windowGraph = windowGraph
        self.snapshot = snapshot
        self.snapshotSampler = snapshotSampler ?? Self.makeLiveSnapshotSampler()
    }

    /// Convenience init that resolves the LLM provider from `UserDefaults`
    /// / env and wires it into the orchestrator. 测试可注入隔离 suite。
    public init(
        userDefaults: UserDefaults,
        windowGraph: WindowGraph = .bootstrap,
        snapshot: DesktopSnapshot? = nil,
        snapshotSampler: DesktopSnapshotSampler? = nil,
        toolModeBox: ToolModeBox = ToolModeBox()
    ) {
        let store = ConversationStore(storeURL: ConversationStore.defaultStoreURL())
        // Resolve config once so both provider and model name use the same values.
        let config = Self.resolveLLMConfig(userDefaults: userDefaults)
        let provider = Self.resolveLLMProvider(userDefaults: userDefaults)
        let box = LiveContextBox()
        self.orchestrator = CompanionOrchestrator(
            llmProvider: provider,
            toolModeBox: toolModeBox,
            conversationStore: store,
            liveContextBox: box,
            modelName: config.model
        )
        self.conversationStore = store
        self.liveContextBox = box
        self.windowGraph = windowGraph
        self.snapshot = snapshot
        self.snapshotSampler = snapshotSampler ?? Self.makeLiveSnapshotSampler()
    }

    /// Re-resolve the LLM provider from current `UserDefaults` state and swap
    /// it into the shared `LLMProviderBox`。设置面板保存后立即调用,实现热重载,
    /// 用户无需重启 app。
    public static func reloadLLMProvider(
        into box: LLMProviderBox,
        userDefaults: UserDefaults = .standard
    ) async {
        let newProvider = resolveLLMProvider(userDefaults: userDefaults)
        await box.set(newProvider)
    }

    public func makeRootSystem() async throws -> AppRootSystem {
        // Load persisted conversation history before first reply.
        // load() internally recovers from corruption without throwing.
        try await conversationStore.load()

        let snapshot = if let snapshot {
            snapshot
        } else {
            await MainActor.run {
                snapshotSampler.sample()
            }
        }

        // A.2.2: wire snapshotProvider into liveContextBox so every reply
        // captures the real-time desktop state. The sampler's sample() is
        // @MainActor, so we dispatch via MainActor.run inside the closure.
        let capturedSampler = snapshotSampler
        let capturedBox = liveContextBox
        await capturedBox.setSnapshotProvider {
            await MainActor.run { capturedSampler.sample() }
        }

        let companionBootstrap = try await orchestrator.bootstrap(snapshot: snapshot)
        let runtimeTicker = RuntimeTicker { previousRenderState, deltaTime, wantsParticles in
            let snapshot = await MainActor.run {
                capturedSampler.sample()
            }
            let renderState = try await orchestrator.tick(
                snapshot: snapshot,
                deltaTime: deltaTime,
                previousRenderState: previousRenderState,
                wantsParticles: wantsParticles
            )
            return RuntimeTickResult(renderState: renderState, snapshot: snapshot)
        }
        // A.1.3: wire both atomic and streaming paths into ConversationResponder.
        // streamProvider returns an AsyncThrowingStream of incremental deltas
        // that CompanionOrchestrator.streamReply drives via the provider's SSE stream.
        let conversationResponder = ConversationResponder(
            replyHandler: { message in
                await orchestrator.reply(to: message)
            },
            streamProvider: { message in
                orchestrator.replyStream(for: message)
            },
            // Task C — QuickAsk 浮窗一次性问答路径(不写历史 / 不通知状态机)。
            oneShotStreamProvider: { message in
                orchestrator.replyStreamOneShot(for: message)
            }
        )
        return AppRootSystem(
            snapshot: snapshot,
            windowGraph: windowGraph,
            companionBootstrap: companionBootstrap,
            runtimeTicker: runtimeTicker,
            conversationResponder: conversationResponder,
            // Task F — 把 store 透传给 MinimalAppDelegate,让 BondedSession
            // 能在 QuickAsk 转聊天时写入历史。
            conversationStore: conversationStore,
            // 阶段 4 — 暴露 orchestrator 作主动建议生成器(no-history 入口),
            // 让 setupProactiveEngine 复用同一实例拼 system prompt。
            proactiveGenerator: orchestrator
        )
    }
}

private final class LiveWindowInfoSnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private let windowInfoSource: @Sendable () -> [[String: Any]]
    private var cachedWindowInfo: [[String: Any]]?

    init(windowInfoSource: @escaping @Sendable () -> [[String: Any]]) {
        self.windowInfoSource = windowInfoSource
    }

    func beginSample() {
        lock.lock()
        cachedWindowInfo = nil
        lock.unlock()
    }

    func current() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }

        if let cachedWindowInfo {
            return cachedWindowInfo
        }

        let windowInfo = windowInfoSource()
        cachedWindowInfo = windowInfo
        return windowInfo
    }
}

extension AppBootstrap {
    static func makeLiveSnapshotSampler(
        currentDisplays: @escaping DesktopSnapshotSampler.CurrentDisplays = {
            NSScreen.screens.enumerated().map { index, screen in
                let frame = screen.frame
                let displayID = screen.displayID ?? CGDirectDisplayID(index)
                return DisplaySnapshot(
                    id: displayID,
                    width: frame.width,
                    height: frame.height
                )
            }
        },
        observeDisplayChanges: @escaping DisplayTracker.ObserveChanges = { handler in
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { _ in
                handler()
            }
        },
        windowInfoSource: @escaping @Sendable () -> [[String: Any]] = {
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
        },
        currentProcessIdentifier: @escaping @Sendable () -> Int32 = {
            ProcessInfo.processInfo.processIdentifier
        },
        frontmostApplicationProcessIdentifier: @escaping @Sendable () -> Int32? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        currentCursorPosition: @escaping DesktopSnapshotSampler.CurrentCursorPosition = {
            let mouseLocation = NSEvent.mouseLocation
            return Point(x: mouseLocation.x, y: mouseLocation.y)
        },
        frontmostApplicationName: @escaping DesktopSnapshotSampler.FrontmostApplicationName = {
            NSWorkspace.shared.frontmostApplication?.localizedName
        },
        accessibilityIsTrusted: @escaping DesktopSnapshotSampler.AccessibilityIsTrusted = AccessibilityBridge.defaultIsProcessTrustedCheck,
        observeSpaceChanges: @escaping SpaceTracker.ObserveChanges = { handler in
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                handler()
            }
        },
        observeWindowChanges: @escaping WindowTracker.ObserveChanges = { handler in
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWorkspace.didActivateApplicationNotification,
                NSWorkspace.didDeactivateApplicationNotification,
                NSWorkspace.didTerminateApplicationNotification,
                NSWorkspace.activeSpaceDidChangeNotification,
            ]
            for name in names {
                center.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { _ in
                    handler()
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = AXFrontmostWindowObserver.attachWithRetainer(handler: handler)
                }
            }
        }
    ) -> DesktopSnapshotSampler {
        let displayTracker = DisplayTracker(
            readDisplays: currentDisplays,
            observeChanges: observeDisplayChanges
        )
        let windowInfoSnapshotCache = LiveWindowInfoSnapshotCache(windowInfoSource: windowInfoSource)
        let activeSpaceIdentifierProvider = ActiveSpaceIdentifierProvider(
            windowInfoSource: {
                windowInfoSnapshotCache.current()
            },
            currentProcessIdentifier: currentProcessIdentifier,
            frontmostApplicationProcessIdentifier: frontmostApplicationProcessIdentifier
        )
        let visibleWindowsProvider = VisibleWindowsProvider(
            windowInfoSource: {
                windowInfoSnapshotCache.current()
            },
            currentProcessIdentifier: currentProcessIdentifier
        )
        let windowTracker = WindowTracker(
            readVisibleWindows: {
                visibleWindowsProvider.current()
            },
            observeChanges: observeWindowChanges
        )
        let spaceTracker = SpaceTracker(
            readActiveSpaceIdentifier: {
                activeSpaceIdentifierProvider.current()
            },
            observeChanges: observeSpaceChanges
        )

        return DesktopSnapshotSampler(
            currentDisplays: {
                windowInfoSnapshotCache.beginSample()
                return displayTracker.currentDisplays
            },
            activeSpaceIdentifier: {
                spaceTracker.currentActiveSpaceIdentifier
            },
            currentCursorPosition: currentCursorPosition,
            frontmostApplicationName: frontmostApplicationName,
            currentVisibleWindows: {
                windowTracker.currentVisibleWindows
            },
            accessibilityIsTrusted: accessibilityIsTrusted
        )
    }
}
