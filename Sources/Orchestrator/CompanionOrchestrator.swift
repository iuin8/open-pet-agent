import Context
import Foundation
import RuntimeBridge
import AgentMode

public struct CompanionBootstrap: Sendable, Equatable {
    public let capabilities: RuntimeCapabilities
    public let initialRenderState: RenderState

    public init(capabilities: RuntimeCapabilities, initialRenderState: RenderState) {
        self.capabilities = capabilities
        self.initialRenderState = initialRenderState
    }
}

public struct CompanionOrchestrator: Sendable {
    private let runtimeBridge: RuntimeBridgeService
    private let presentationMapper: PresentationMapper
    private let behaviorEngine: BehaviorEngine
    public let llmProviderBox: LLMProviderBox
    /// N2.3 — Tool Mode 路由器桥。默认空 box (`isAgentModeEnabled = false`)
    /// 完全不影响现有 LLM 灵魂层路径; `MinimalAppDelegate` 启动期把真实
    /// box 注入进来后, `replyStream` 优先走工具层子进程。
    public let agentModeBox: AgentModeBox
    /// Conversation history store. Nil → stateless (echo) path; backward-compat.
    private let conversationStore: ConversationStore?
    /// Hot-injection box for desktop snapshot and pet context providers.
    /// Nil → no context injected into system prompt (backward-compat).
    private let liveContextBox: LiveContextBox?
    /// Active model name used to determine the context window size for rolling-window
    /// token budget. Nil → conservative default of 4096 tokens. Set by AppBootstrap
    /// via `resolveLLMConfig` (scheme C — orchestrator holds the resolved name).
    public let modelName: String?
    /// P2a:persona 注入器(返回 SOUL.md 内容;nil → 用 base 硬编码)。App 注入:
    /// 云后端读 SOUL.md;`nativePersona` 后端(openclaw)返回 nil(自管 SOUL,不注入 —— 能力闸自动)。
    private let personaResolver: (@Sendable () -> String?)?
    /// P4 跨引擎/项目交接背景供给(AppBootstrap 注入;agent 模式下返回非 nil 时,
    /// 经 `wrapAgentHandoff` 包进首个 prompt —— 一次性,由注入方的 tracker 保证)。
    private let agentHandoffContext: (@Sendable () async -> String?)?

    public init(
        runtimeBridge: RuntimeBridgeService = RuntimeBridgeService(),
        presentationMapper: PresentationMapper = PresentationMapper(),
        behaviorEngine: BehaviorEngine = BehaviorEngine(),
        llmProvider: (any LLMProvider)? = nil,
        agentModeBox: AgentModeBox = AgentModeBox(),
        conversationStore: ConversationStore? = nil,
        liveContextBox: LiveContextBox? = nil,
        modelName: String? = nil,
        personaResolver: (@Sendable () -> String?)? = nil,
        agentHandoffContext: (@Sendable () async -> String?)? = nil
    ) {
        self.init(
            runtimeBridge: runtimeBridge,
            presentationMapper: presentationMapper,
            behaviorEngine: behaviorEngine,
            llmProviderBox: LLMProviderBox(llmProvider),
            agentModeBox: agentModeBox,
            conversationStore: conversationStore,
            liveContextBox: liveContextBox,
            modelName: modelName,
            personaResolver: personaResolver,
            agentHandoffContext: agentHandoffContext
        )
    }

    public init(
        runtimeBridge: RuntimeBridgeService = RuntimeBridgeService(),
        presentationMapper: PresentationMapper = PresentationMapper(),
        behaviorEngine: BehaviorEngine = BehaviorEngine(),
        llmProviderBox: LLMProviderBox,
        agentModeBox: AgentModeBox = AgentModeBox(),
        conversationStore: ConversationStore? = nil,
        liveContextBox: LiveContextBox? = nil,
        modelName: String? = nil,
        personaResolver: (@Sendable () -> String?)? = nil,
        agentHandoffContext: (@Sendable () async -> String?)? = nil
    ) {
        self.runtimeBridge = runtimeBridge
        self.presentationMapper = presentationMapper
        self.behaviorEngine = behaviorEngine
        self.llmProviderBox = llmProviderBox
        self.agentModeBox = agentModeBox
        self.conversationStore = conversationStore
        self.liveContextBox = liveContextBox
        self.modelName = modelName
        self.personaResolver = personaResolver
        self.agentHandoffContext = agentHandoffContext
    }

    /// P4 交接包装:背景块(最近对话摘要)+ 用户新消息。
    /// 背景明确「只参考不复述」+「以仓库实际状态为准」(防 agent 把交接内容当本轮任务回复,
    /// 模板措辞借鉴 codux session fork 的 Handoff Instructions,见 docs/reference-library.md)。
    nonisolated static func wrapAgentHandoff(_ message: String, handoff: String) -> String {
        """
        [背景交接]以下是我与另一个 AI 助手的最近对话,仅供你了解上下文,不要复述、不要逐条回复这段内容;涉及代码事实请以直接查看仓库文件为准,不要尽信交接文本:
        <handoff>
        \(handoff)
        </handoff>
        [背景结束]下面是我的新消息:
        \(message)
        """
    }

    public func bootstrap(snapshot: DesktopSnapshot = .empty) async throws -> CompanionBootstrap {
        let capabilities = try await runtimeBridge.fetchCapabilities()
        let runtimeOutput = try await runtimeBridge.step(snapshot: snapshot)
        let initialRenderState = applyBehavior(to: presentationMapper.map(runtimeOutput))
        return CompanionBootstrap(
            capabilities: capabilities,
            initialRenderState: initialRenderState
        )
    }

    private func applyBehavior(to state: RenderState) -> RenderState {
        RenderState(
            petPositionX: state.petPositionX,
            petPositionY: state.petPositionY,
            petRotation: state.petRotation,
            particleCount: state.particleCount,
            particles: state.particles,
            contactCount: state.contactCount,
            isSnowEnabled: state.isSnowEnabled,
            companionBehavior: behaviorEngine.behavior(for: state)
        )
    }

    public func reply(
        to message: String,
        onThinkingBegan: (@Sendable () async -> Void)? = nil,
        onThinkingEnded: (@Sendable (Result<String, Error>) async -> Void)? = nil,
        onPartialReply: (@Sendable (String) async -> Void)? = nil
    ) async -> String {
        if let provider = await llmProviderBox.current {
            await onThinkingBegan?()
            do {
                let messages = try await buildMessages(for: message)
                // Record user turn before calling provider
                let userMessage = ConversationMessage(role: .user, content: message)
                await conversationStore?.append(userMessage)

                let reply: String
                if let onPartialReply {
                    reply = try await streamReply(
                        provider: provider,
                        messages: messages,
                        onPartialReply: onPartialReply
                    )
                } else {
                    reply = try await provider.chat(messages)
                }

                // Record assistant turn only on success (full reply, not partials)
                let assistantMessage = ConversationMessage(role: .assistant, content: reply)
                await conversationStore?.append(assistantMessage)
                await onThinkingEnded?(.success(reply))
                return reply
            } catch {
                await onThinkingEnded?(.failure(error))
                // fall through to echo
            }
        } else {
            // No provider — record user message if store is present (consistent)
            let userMessage = ConversationMessage(role: .user, content: message)
            await conversationStore?.append(userMessage)
        }
        return "\u{6211}\u{542C}\u{5230}\u{201C}\(message)\u{201D}\u{4E86}\u{3002}"
    }

    /// A.1.3: Returns a live stream of incremental delta tokens for the given message.
    ///
    /// The stream yields cumulative-or-delta strings from the provider's SSE stream,
    /// records the final accumulated reply in the ConversationStore once streaming
    /// completes (success), and records the user turn up front.
    ///
    /// Called by `AppBootstrap.ConversationResponder.streamProvider` so the shell
    /// can iterate the stream and update the chat transcript incrementally.
    ///
    /// C1 — 内部带空闲超时 watchdog: 若上次收到 delta token 距今超过
    /// `streamIdleTimeoutSeconds`(默认 90s) 主动 finish(throwing: URLError(.timedOut))。
    /// 常见场景: 国内云厂商 SSE 建连成功但服务端 chunk 卡死, URLSession
    /// 默认 60s 单 chunk timeout 偶有不可靠。Shell 层 LLMErrorMessages.friendly
    /// 会把 URLError(.timedOut) surface 成"请求超时"友好文案。
    public func replyStream(for message: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // N2.3 + C1 修复:把"走工具层 vs 灵魂层"的判断放在最外层 Task,
            // **再决定是否启动 watchdog**。之前 watchdog 跟 streamTask 并发
            // 启动 + 用 actor 协调 isAgentModePath 旗标的方式有 race —
            // watchdog 醒来时(1s 后)streamTask 可能还卡在 MainActor hop 没
            // 来得及 markAgentMode → idleSeconds > timeout(测试用 1s)→
            // 误抛 URLError(.timedOut)。重构为线性 if/else 两条路径各自独立
            // 启停 watchdog,彻底消除 race。
            let timeout = Self.streamIdleTimeoutSeconds

            let work = Task {
                // 工具层启用 + engine 注册 → 整条 prompt 走子进程, 跳过 LLM,
                // **完全不启动 watchdog**(子进程时长无关 SSE idle 语义)。
                if await agentModeBox.isAgentModeEnabled {
                    let userMessage = ConversationMessage(role: .user, content: message)
                    await conversationStore?.append(userMessage)
                    // P4 跨引擎/项目交接:会话桶(engineKind|cwd)变化后的首个 agent run,
                    // 把此前会话摘要包进 prompt(一次性;store 只记用户原文,不记交接包装)。
                    let prompt: String
                    if let handoff = await agentHandoffContext?() {
                        prompt = Self.wrapAgentHandoff(message, handoff: handoff)
                    } else {
                        prompt = message
                    }
                    var accumulated = ""
                    do {
                        for try await delta in agentModeBox.runAgent(prompt: prompt) {
                            accumulated += delta
                            continuation.yield(delta)
                        }
                        if !accumulated.isEmpty {
                            let assistantMessage = ConversationMessage(
                                role: .assistant,
                                content: accumulated
                            )
                            await conversationStore?.append(assistantMessage)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                // 灵魂层 (LLM) 路径 — 启动 watchdog 监控 SSE idle。
                guard let provider = await llmProviderBox.current else {
                    // 用户没配 provider:yield 友好提示, finish, 不启 watchdog。
                    continuation.yield(Self.providerNotConfiguredMessage)
                    continuation.finish()
                    return
                }

                let idleClock = StreamIdleClock()
                let watchdogTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { return }
                        let idle = await idleClock.idleSeconds()
                        if idle > timeout {
                            continuation.finish(throwing: URLError(.timedOut))
                            return
                        }
                    }
                }

                do {
                    let messages = try await buildMessages(for: message)
                    let userMessage = ConversationMessage(role: .user, content: message)
                    await conversationStore?.append(userMessage)

                    var accumulated = ""
                    for try await delta in provider.streamChat(messages) {
                        // 收到任何 chunk(包括空 delta)都重置 idle 计时,
                        // 避免心跳/keep-alive 帧被误判为卡死。
                        await idleClock.touch()
                        guard !delta.isEmpty else { continue }
                        accumulated += delta
                        continuation.yield(delta)
                    }

                    if !accumulated.isEmpty {
                        let assistantMessage = ConversationMessage(role: .assistant, content: accumulated)
                        await conversationStore?.append(assistantMessage)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                watchdogTask.cancel()
            }

            // 消费者提前断流时把 work task 收掉, sub-task (watchdog / 工具层
            // 子进程) 会沿 cancellation 链路传播下去。
            continuation.onTermination = { _ in
                work.cancel()
            }
        }
    }

    /// Task C — Spotlight QuickAsk 浮窗专用一次性流式 provider。
    ///
    /// 与 `replyStream(for:)` 的差异:
    ///   - **不写 ConversationStore** — QuickAsk 是"一次性问答",不污染
    ///     pet 头顶 bonded session 历史
    ///   - **不发 ChatBehaviorStateMachine 事件** — pet 在用户阅读浮窗时
    ///     不应触发 thinking / talking 动画
    ///   - **不走 agentMode 路径** — QuickAsk 定位是"快速问 LLM",不为工具
    ///     调用场景设计
    ///   - 仍带 idle watchdog,SSE 卡死时及时 surface 错误
    ///   - 仍带 desktop context system prompt(让 AI 知道前台 app / 时间)
    ///
    /// `LLMProviderBox.current == nil` 时 yield 友好提示后 finish,行为与
    /// `replyStream` 一致。
    public func replyStreamOneShot(for message: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let timeout = Self.streamIdleTimeoutSeconds
            let work = Task {
                guard let provider = await llmProviderBox.current else {
                    continuation.yield(Self.providerNotConfiguredMessage)
                    continuation.finish()
                    return
                }

                let idleClock = StreamIdleClock()
                let watchdogTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { return }
                        let idle = await idleClock.idleSeconds()
                        if idle > timeout {
                            continuation.finish(throwing: URLError(.timedOut))
                            return
                        }
                    }
                }

                do {
                    // 复用 buildMessages 拿 system prompt + desktop context,
                    // 但 **不调** conversationStore.append(buildMessages 内部
                    // 只读 history,不写)。
                    let messages = try await buildMessages(for: message)
                    for try await delta in provider.streamChat(messages) {
                        await idleClock.touch()
                        guard !delta.isEmpty else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                watchdogTask.cancel()
            }

            continuation.onTermination = { _ in
                work.cancel()
            }
        }
    }

    /// Build the message array (system prompt + history + user message).
    private func buildMessages(for message: String) async throws -> [LLMMessage] {
        let snapshot = await liveContextBox?.snapshotProvider?()
        let petContext = await liveContextBox?.petContextProvider?()
        // Remember the user's actual workspace so chat-focused replies still
        // know what app they were using right before clicking into chat.
        await liveContextBox?.observe(
            snapshot: snapshot,
            selfApplicationName: Self.ownApplicationName
        )
        let lastNonSelf = await liveContextBox?.lastNonSelfApplicationName
        let soulContent = personaResolver?()  // P2a:云后端读 SOUL.md;nativePersona 后端 nil
        let systemPrompt = Self.buildSystemPrompt(
            snapshot: snapshot,
            petContext: petContext,
            selfApplicationName: Self.ownApplicationName,
            lastNonSelfApplicationName: lastNonSelf,
            soulContent: soulContent
        )
        let contextWindow = Self.contextWindow(for: modelName)
        let history = await conversationStore?.truncatedMessages(
            reservedReplyTokens: 2048,
            reservedSystemTokens: 1024,
            modelContextWindow: contextWindow
        ) ?? []
        let historyMessages = history.map { LLMMessage(role: $0.role, content: $0.content) }
        return [LLMMessage(role: .system, content: systemPrompt)]
            + historyMessages
            + [LLMMessage(role: .user, content: message)]
    }

    /// Consume the provider's streaming response, accumulating deltas and
    /// calling `onPartialReply` with the **cumulative** string after each chunk.
    /// Returns the fully accumulated reply.
    ///
    /// C1 — 同 `replyStream` 同款 idle watchdog: 上次收 delta 距今超过
    /// `streamIdleTimeoutSeconds` 即 throw `URLError(.timedOut)`,
    /// 由 `reply(to:)` 的 catch 走 onThinkingEnded?(.failure(error))。
    private func streamReply(
        provider: any LLMProvider,
        messages: [LLMMessage],
        onPartialReply: @Sendable @escaping (String) async -> Void
    ) async throws -> String {
        let idleClock = StreamIdleClock()
        let timeout = Self.streamIdleTimeoutSeconds

        return try await withThrowingTaskGroup(of: String?.self) { group in
            // Task A — 读 stream;返回累计 reply。
            group.addTask {
                var accumulated = ""
                for try await delta in provider.streamChat(messages) {
                    await idleClock.touch()
                    guard !delta.isEmpty else { continue }
                    accumulated += delta
                    await onPartialReply(accumulated)
                }
                return accumulated
            }
            // Task B — watchdog;超时即 throw,让 group 抛出给调用方。
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return nil }
                    let idle = await idleClock.idleSeconds()
                    if idle > timeout {
                        throw URLError(.timedOut)
                    }
                }
                return nil
            }

            // 第一个完成的 task 决定结果:
            // - Task A 先完成 → 返回累计 reply,cancel watchdog
            // - Task B 先 throw → group 自动 cancel Task A 并向上抛
            // group.next() 返回 String?? (外层"还有 task 吗" + 内层我们的可空值)
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first ?? ""
        }
    }

    // MARK: - Context window heuristic

    /// Returns the conservative context window size (in tokens) for the given model name.
    ///
    /// Prefix matching is applied longest-first to prevent `gpt-4o-mini` from being
    /// matched by the shorter `gpt-4` prefix.
    ///
    /// | Model prefix    | Window   | Rationale                                        |
    /// |-----------------|----------|--------------------------------------------------|
    /// | `gpt-4o`        | 16 000   | gpt-4o/gpt-4o-mini; 128k real but capped for cost |
    /// | `gpt-4`         | 8 000    | older gpt-4; conservative subset of 32k window   |
    /// | `gpt-3.5`       | 4 000    | gpt-3.5-turbo; 4k effective window               |
    /// | `deepseek`      | 32 000   | DeepSeek models; 64k real, use half              |
    /// | `claude`        | 32 000   | Claude models; 200k real, use conservative slice |
    /// | `llama`/`qwen`/`mistral` | 4 096 | Local Ollama models; conservative estimate  |
    /// | nil/unknown     | 4 096    | Safe default                                     |
    public static func contextWindow(for model: String?) -> Int {
        guard let model else { return 4_096 }
        // Check longest (most specific) prefixes first to avoid false matches.
        if model.hasPrefix("gpt-4o")   { return 16_000 }
        if model.hasPrefix("gpt-4")    { return 8_000  }
        if model.hasPrefix("gpt-3.5")  { return 4_000  }
        if model.hasPrefix("deepseek") { return 32_000 }
        if model.hasPrefix("claude")   { return 32_000 }
        if model.hasPrefix("llama")    { return 4_096  }
        if model.hasPrefix("qwen")     { return 4_096  }
        if model.hasPrefix("mistral")  { return 4_096  }
        return 4_096
    }

    // MARK: - System prompt construction

    /// The localized application name AppKit reports for OpenPetAgent when it
    /// is frontmost. Used to filter ourselves out of the [Desktop Context]
    /// block — otherwise every reply (chat window is focused) would tell the
    /// AI "前台应用：OpenPetAgent", which is noise.
    internal static let ownApplicationName = "OpenPetAgent"

    /// `replyStream` 在 `LLMProviderBox.current == nil` 时 yield 的友好提示。
    /// 用户没在设置里配 baseURL / API key 时之前直接 `continuation.finish()`,
    /// UI 完全没回应("发完消息没反应"),改为 yield 这条 Markdown 提示让用户
    /// 知道去哪里配。`Shell.LLMErrorMessages.providerNotConfigured` 保持一致
    /// (两个模块各定义,Shell 不 deps Orchestrator)。
    public static let providerNotConfiguredMessage: String =
        "⚠️ **未配置 AI 模型** —— 请打开菜单栏 → ⚙️ 设置,填写 baseURL / API key / 模型名后重试。"

    /// C1 — SSE 流空闲超时上限(秒)。`replyStream` / `streamReply` 循环中,
    /// 上次收到 delta token 距今超过此值则 throw `URLError(.timedOut)`,
    /// Shell 层 `LLMErrorMessages.friendly` 会 surface "请求超时" 给用户。
    ///
    /// 常见场景:国内云厂商 SSE 建连成功但服务端 chunk 卡死,URLSession 默认
    /// 60s 单 chunk timeout 偶有不可靠,90s 给慢模型一些喘息空间又不至于让
    /// 用户傻等。
    ///
    /// 测试可在 setup 阶段临时修改此值(配合 defer 还原),避免实测跑 90s。
    /// 由于改动只发生在测试代码中,生产路径仍是常量语义。
    public static var streamIdleTimeoutSeconds: TimeInterval = 90

    /// Builds the system prompt, optionally appending a [Desktop Context] block.
    ///
    /// - Parameters:
    ///   - snapshot: Current desktop snapshot; nil → no context block.
    ///   - petContext: Current pet runtime state; nil → pet/snow lines omitted.
    ///   - now: Injection point for deterministic time in tests.
    ///   - calendar: Injection point for deterministic calendar in tests.
    ///   - selfApplicationName: When non-nil and equal to the snapshot's
    ///     frontmost app, the "前台应用" line is omitted. Defaults to nil
    ///     so existing tests are unaffected; the reply path passes the real
    ///     bundle name to filter out the chat window itself.
    ///   - lastNonSelfApplicationName: Fallback shown as "最近活跃应用" when the
    ///     current frontmost app is OpenPetAgent itself (chat focused). Lets the
    ///     AI keep talking about what the user was doing before clicking chat.
    ///     Nil → no fallback line.
    internal static func buildSystemPrompt(
        snapshot: DesktopSnapshot?,
        petContext: PetContext?,
        now: Date = Date(),
        calendar: Calendar = .current,
        selfApplicationName: String? = nil,
        lastNonSelfApplicationName: String? = nil,
        soulContent: String? = nil
    ) -> String {
        // P2a:soulContent(SOUL.md)非 nil → 替代 base(云后端注入);nil → base 硬编码(向后兼容)。
        let base = soulContent ?? "You are OpenPetAgent, a friendly desktop AI companion living on the user's macOS desktop alongside a real-time snow simulation. Reply concisely in the user's language (default Chinese). Output ONLY the final answer — never show your reasoning, planning, or meta-narration (e.g. \"User asks…\", \"The assistant should…\", \"According to system…\"), never wrap thinking in <think> tags, and never restate the task in English."
        guard let snapshot else { return base }

        var lines: [String] = ["[Desktop Context]"]

        // Frontmost app. When OpenPetAgent is itself frontmost (chat window focused),
        // fall back to the last remembered non-self app so the AI doesn't lose
        // context every time the user clicks into the chat.
        let frontmost = snapshot.visibleApplicationName
        if let appName = frontmost, appName != selfApplicationName {
            lines.append("- 当前前台应用：\(appName)")
        } else if let recent = lastNonSelfApplicationName {
            lines.append("- 最近活跃应用：\(recent)")
        }

        // Visible windows with titles (感知加深·标题层) — 让 AI 知道用户在改哪个文件/看哪个页。
        lines.append(contentsOf: DesktopContextFormatter.windowContextLines(
            snapshot: snapshot,
            selfApplicationName: selfApplicationName
        ))

        // Time of day
        lines.append("- 时段：\(timeLabel(for: now, calendar: calendar))")

        // Display count
        let displayCount = snapshot.displays.count
        lines.append("- 显示器：\(displayCount) 个")

        // Cursor zone
        lines.append("- 光标位置：\(cursorZoneLabel(cursor: snapshot.cursorPosition, display: snapshot.displays.first))")

        // Pet state (optional)
        if let petContext {
            lines.append("- 桌宠状态：\(behaviorLabel(petContext.behavior))")
            let snowStatus = petContext.isSnowEnabled ? "开启" : "关闭"
            lines.append("- 雪景模式：\(snowStatus)")
        }

        return base + "\n\n" + lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private static func timeLabel(for date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5...11:  return "上午"
        case 12...17: return "下午"
        case 18...22: return "晚上"
        default:      return "深夜"
        }
    }

    /// Maps cursor position to a 3×3 grid zone label.
    /// macOS y-axis: 0 = bottom, display.height = top.
    private static func cursorZoneLabel(cursor: Point, display: DisplaySnapshot?) -> String {
        guard let display, display.width > 0, display.height > 0 else {
            return "屏幕中央"
        }
        let col: Int  // 0 = left, 1 = center, 2 = right
        let row: Int  // 0 = bottom, 1 = middle, 2 = top

        let xRatio = cursor.x / display.width
        if xRatio < 1.0 / 3.0 {
            col = 0
        } else if xRatio < 2.0 / 3.0 {
            col = 1
        } else {
            col = 2
        }

        let yRatio = cursor.y / display.height
        if yRatio < 1.0 / 3.0 {
            row = 0
        } else if yRatio < 2.0 / 3.0 {
            row = 1
        } else {
            row = 2
        }

        let zoneNames: [[String]] = [
            ["屏幕左下", "屏幕中下", "屏幕右下"],
            ["屏幕左中", "屏幕中央", "屏幕右中"],
            ["屏幕左上", "屏幕中上", "屏幕右上"],
        ]
        return zoneNames[row][col]
    }

    private static func behaviorLabel(_ behavior: CompanionBehavior) -> String {
        switch behavior {
        case .idle:     return "闲庭信步"
        case .tracking: return "追踪光标中"
        case .snowing:  return "下雪中"
        }
    }

    public func tick(
        snapshot: DesktopSnapshot,
        deltaTime: Double,
        previousRenderState: RenderState,
        wantsParticles: Bool = true
    ) async throws -> RenderState {
        let runtimeOutput = try await runtimeBridge.step(
            snapshot: snapshot,
            deltaTime: deltaTime,
            currentPetPose: PetPose(
                position: Point(
                    x: previousRenderState.petPositionX,
                    y: previousRenderState.petPositionY
                ),
                rotation: previousRenderState.petRotation
            ),
            isSnowEnabled: previousRenderState.isSnowEnabled,
            previousParticleCount: previousRenderState.particleCount,
            previousParticles: previousRenderState.particles,
            wantsParticles: wantsParticles
        )
        return applyBehavior(to: presentationMapper.map(runtimeOutput))
    }
}

/// C1 — SSE 流空闲计时器,actor 保证 `touch()` / `idleSeconds()` 并发安全。
///
/// 用 `ProcessInfo.systemUptime` 而非 `Date()` 计时,避免系统时钟跳变(NTP 调
/// 整 / 用户改时区)导致 watchdog 误触发。systemUptime 是 boot 后单调递增的
/// 秒数,跟 wall clock 解耦,正是 idle 检测想要的语义。
private actor StreamIdleClock {
    private var lastTouchAt: TimeInterval = ProcessInfo.processInfo.systemUptime

    /// 收到任何 SSE chunk(包括空 delta、keep-alive)都调用,重置 idle 计时。
    func touch() {
        lastTouchAt = ProcessInfo.processInfo.systemUptime
    }

    /// 返回上次 touch 距今的秒数。
    func idleSeconds() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime - lastTouchAt
    }
}
