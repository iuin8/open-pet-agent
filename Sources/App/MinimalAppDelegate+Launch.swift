import AppKit
import Context
import Foundation
import Orchestrator
import PetBehavior
import Rendering
import RuntimeBridge
import Shell
import Shimeji
import AgentMode
import Weather
import simd
#if canImport(Live2D)
import Live2D
#endif

// MARK: - 启动流程拆分(applicationDidFinishLaunching 调用顺序)

extension MinimalAppDelegate {
    /// M.1 — Create the multi-monitor overlay registry and sync all
    /// currently connected displays. The registry is also kept in sync
    /// by the screen-parameter and wake notifications registered below.
    ///
    /// Returns the captured screen frame so the caller can re-use it without
    /// invoking `currentScreenFrame()` twice (preserves the test contract:
    /// exactly one call per launch).
    func setupOverlayRegistry() -> NSRect {
        let capturedFrame = currentScreenFrame()
        // M.2 architecture caveat: the registry creates its own NSWindow per
        // display, but each per-screen GPUSnowCoordinator owns separate
        // particle / pile / collision buffers — and we attach the *legacy*
        // single `gpuSnowCoordinator.driver` to the visible overlay. That
        // means the M.2 path uploaded collision rects to a coordinator
        // whose buffers were never dispatched, leaving the rendered overlay
        // with an empty collision buffer (snow falls through every window).
        // Until the registry → overlay-driver wiring is refactored, force
        // `coordinators` to stay empty by returning nil from the factory.
        // `advanceRuntimeFrame` then falls back to `tickSingleCoordinator`,
        // which uses the full-screen-height y-flip via `displays.first?.height`
        // — i.e. the path that actually piles snow on window tops.
        let registry = OverlayWindowRegistry(
            makeOverlay: { frame in
                let window = NSWindow(
                    contentRect: frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.title = "OpenPetAgent Secondary Overlay"
                window.isReleasedWhenClosed = false
                window.isOpaque = false
                window.backgroundColor = .clear
                window.ignoresMouseEvents = true
                window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                window.orderFrontRegardless()
                return window
            }
        )
        self.overlayRegistry = registry
        registry.sync(
            displayIDs: currentDisplayIDs(),
            screenFrameProvider: { _ in capturedFrame }
        )
        Self.populateFullScreenFrames(registry: registry)

        // Observe screen-parameter changes (display plug/unplug, resolution change).
        // Both observers are delivered on the main queue; `assumeIsolated` is safe.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenConfigurationChange() }
        }
        // Sleep/wake insurance: macOS may not always fire didChangeScreen... on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenConfigurationChange() }
        }

        return capturedFrame
    }

    /// N2.3 / N2.4 — 工具层路由器装配。UserDefaults `tool.mode.enabled`
    /// 默认 false (实验特性); 开关打开 → 按 `tool.engine.kind` 注册对应
    /// engine (ClaudeCodeEngine / CodexEngine), 关闭 → router 存在但
    /// `currentEngine == nil` (此时 Orchestrator 的 `replyStream` 走
    /// 灵魂层)。注入到共享 holder, Orchestrator 就能通过 `AgentModeBox`
    /// 看到当前 engine 状态。
    func setupAgentModeRouter() {
        let agentModeEnabled = userDefaults.bool(forKey: Self.agentModeEnabledKey)
        let router = AgentModeRouter()
        if agentModeEnabled {
            Self.applySelectedAgentEngine(to: router, defaults: userDefaults)
        }
        self.agentModeRouter = router
        agentModeRouterHolder?.set(router)
        if agentModeEnabled { wireACPPermissionHandler() }   // ACP-2:engine 是 ACP 时注入 onPermissionRequest
    }

    /// Task B / P2 — OpenClaw 本地 gateway 探测 + 自动启动,作为**一等灵魂层
    /// 后端**接入(不再「伪装混进 OpenAI 槽」)。装了 `openclaw` 的用户**零配置**
    /// 就能用 OpenPetAgent: probe → 拉 daemon → 读 token/port → 写 **openclaw
    /// 专属槽** + 设 `UserDefaults["LLMProvider"] = "openclaw"` → 触发
    /// `reloadLLMProvider`,`SoulBackendRegistry` 选中 openclaw entry →
    /// `resolveOpenClawProvider` 从专属槽构造 provider 走 localhost。
    ///
    /// `UserDefaults[autoStartKey] == false` → 整段 no-op。
    /// 用户已自配云 provider(OpenAI 槽 baseURL/key 任一非空,或 Anthropic key
    /// 非空)→ 尊重用户选择,不抢占。
    /// 失败(没装 / 配置缺失 / endpoint 改写失败)→ 静默回退,设置 UI 仍可
    /// 让用户手填 OpenAI / Anthropic key。
    func setupOpenClawBootstrap() {
        let openClawAutoStart = (userDefaults.object(forKey: OpenClawGatewayManager.autoStartKey) as? Bool) ?? true
        guard openClawAutoStart else { return }
        Task { [userDefaults = self.userDefaults, box = self.llmProviderBox] in
            let status = await OpenClawGatewayManager.shared.bootstrapIfPossible()
            guard case .ready(let baseURL, let token) = status else { return }

            // 仅在用户没自配任何云 provider 时自动选 openclaw:OpenAI 槽
            // (baseURL + key)空 **且** Anthropic key 空。任一非空 → 用户已有
            // 选择,不覆盖。
            let userOpenAIBaseURL = (userDefaults.string(forKey: LLMSettingsKeys.openAIBaseURL) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let userOpenAIKey = (userDefaults.string(forKey: LLMSettingsKeys.openAIApiKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let userAnthropicKey = (userDefaults.string(forKey: LLMSettingsKeys.anthropicApiKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard userOpenAIBaseURL.isEmpty, userOpenAIKey.isEmpty, userAnthropicKey.isEmpty else { return }

            // 🔑 写 openclaw **专属槽** + 把灵魂层选中后端设为 `openclaw`,让
            // `SoulBackendRegistry.resolve` 选中 openclaw entry →
            // `resolveOpenClawProvider` 从专属槽构造 provider。model 固定
            // `openclaw`(在 resolveOpenClawProvider 内写死),这里不存 model。
            userDefaults.set(baseURL, forKey: LLMSettingsKeys.openClawBaseURL)
            if let token, !token.isEmpty {
                userDefaults.set(token, forKey: LLMSettingsKeys.openClawToken)
            }
            userDefaults.set("openclaw", forKey: LLMProviderKind.userDefaultsKey)

            // Hot-reload: 让 registry 立刻选中 openclaw entry,用户不用重启 App
            // 就能开始聊(带 SOUL.md / MEMORY 灵魂)。
            await AppBootstrap.reloadLLMProvider(into: box, userDefaults: userDefaults)
        }
    }

    /// A.3.2 — Instantiate chat behavior state machine + shell controller +
    /// pet plugin selection. Returns the live `DesktopShellController` plus
    /// the wrapped reply handler so downstream setup steps can wire bonded
    /// session / chat window to the same stream envelope.
    func setupShellAndStateMachine(
        screenFrame: NSRect
    ) -> (controller: DesktopShellController, replyHandler: ChatShellView.ReplyHandler) {
        // A.3.2 — Instantiate chat behavior state machine and wire to shell.
        let sm = ChatBehaviorStateMachine()
        chatBehaviorStateMachine = sm

        let initialState = ShellInitialState(
            petPositionX: rootSystem.companionBootstrap.initialRenderState.petPositionX,
            petPositionY: rootSystem.companionBootstrap.initialRenderState.petPositionY
        )

        // Wrap the conversationResponder.reply to emit state machine events
        // around the await so the pet shows .thinking while the AI processes.
        let capturedRootSystem = rootSystem
        let wrappedReplyHandler: ChatShellView.ReplyHandler = { [weak self] message in
            guard let self else {
                return await capturedRootSystem.conversationResponder.reply(to: message)
            }
            let seq = self.lastChatSequenceID
            sm.handle(.chatReplyBegan, sequenceID: seq)
            let reply = await capturedRootSystem.conversationResponder.reply(to: message)
            sm.handle(.chatReplyReceived, sequenceID: seq)
            return reply
        }

        let controller = makeShellController(
            rootSystem.windowGraph,
            screenFrame,
            initialState,
            { [weak self] event in
                self?.recordShellInteraction(event)
            },
            wrappedReplyHandler
        )
        shellController = controller

        // 菜单批 A + B: 注入 pet 右键菜单的"设置..."/"截图分享"/"天气→"/"清雪" callback。
        // pet 菜单的天气模式单选统一走 `selectWeatherMode`,跟菜单栏 / 设置面板同一执行路径
        // (内部已 syncWeatherModeAcrossSurfaces 把两个入口 check state 同步)。
        // 温度模式覆盖档（设置 → 天气，迁移自旧状态栏菜单「温度模式」）。启动即读，
        // 让首次天气 onUpdate 就按覆盖档决定 ambient（非 auto → 雪不被真实气温融）。
        thermalOverride = .from(raw: userDefaults.string(forKey: Self.thermalOverrideKey) ?? "auto")
        if let overrideAmbient = thermalOverride.ambientTemperature {
            fallingSandAmbientTemperature = overrideAmbient
        }
        controller.setMenuCallbacks(
            onSettings: { [weak self] in self?.showSettingsWindow() },
            onShareScreenshot: { [weak self] in self?.shareOverlayScreenshot() },
            onForceConditionSelected: { [weak self] raw in self?.selectWeatherMode(raw) },
            onClearWeather: { [weak self] in self?.shellController?.clearFallingSand() },
            initialForcedConditionRaw: currentWeatherModeRaw,
            onToggleFollowing: { [weak self] enabled in
                guard let self else { return }
                self.isFollowingEnabled = enabled
                self.userDefaults.set(enabled, forKey: Self.followingEnabledKey)
                self.syncSpatialBehaviorAcrossSurfaces()
            },
            onToggleRoaming: { [weak self] enabled in
                guard let self else { return }
                self.isRoamingEnabled = enabled
                self.userDefaults.set(enabled, forKey: Self.roamingEnabledKey)
                self.syncSpatialBehaviorAcrossSurfaces()
            },
            initialFollowingEnabled: isFollowingEnabled,
            initialRoamingEnabled: isRoamingEnabled
        )

        // N3.1 + N3.2 + N3.4 + N3.5: 注册所有内置 pet plugin → 按 UserDefaults
        // 选 plugin → 运行时替换。默认 "orb" (DesktopShellController.init 已
        // 装好 OrbMetalRenderer, 无需再 replace 避免抖一下)。
        // 设置 "pet.plugin.id" = "slime" 切到自创史莱姆 (N3.5)。
        PetPluginRegistry.shared.register(OrbPetPlugin.self)
        PetPluginRegistry.shared.register(SlimePetPlugin.self)
        // 工作块 D D-2.2b:注入真 Live2DPetRenderer 工厂(仅有 Cubism SDK 编进时)。Rendering 不能
        // 依赖 Live2D(成环)→ 工厂在此上层 wire。须在 discover 之前设,使 makeRenderer 闭包生效。
        #if canImport(Live2D)
        Live2DModelPackLoader.rendererFactory = { model3URL in Live2DPetRenderer(model3URL: model3URL) }
        // 缩略图生成钩子(离屏渲一帧 → 缓存 .petagent-thumb.png),给设置 picker 预览图。
        Live2DModelPackLoader.thumbnailGenerator = { model3URL in
            Live2DThumbnailGenerator.generateAndCache(model3URL: model3URL)
        }
        #endif
        // P4-B-5:注入 Shimeji 原始帧 renderer 工厂。含 conf/+img/ 全保真数据的 Shimeji 导入包优先用
        // ShimejiMascotEngine 驱动(走/跌/坐/爬墙真行为图);缺数据的旧包工厂返回 nil → 回退 sprite 切帧。
        // Rendering 不能依赖 PetBehavior/Shimeji(成环+JSC)→ 工厂在此上层 wire,须在 discover 之前。
        CodexSpritePackLoader.shimejiRendererFactory = { [weak self] packDir in
            guard let self else { return nil }
            // 出生:屏顶中央(top-origin y=0)→ 引擎首拍 Fall 入场。初始环境用 provider 翻空快照
            // (复用翻转逻辑);首帧 advance 即用真实桌面快照覆盖。
            let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let visible = NSScreen.main?.visibleFrame ?? screen
            let env = self.shimejiEnvironmentProvider.environment(
                snapshot: .empty,
                workAreaBottomOrigin: Rect(
                    origin: Point(x: Double(visible.minX), y: Double(visible.minY)),
                    width: Double(visible.width), height: Double(visible.height)),
                screenWidth: Double(screen.width), screenHeight: Double(screen.height))
            // 出生屏顶之上(top-origin y<0)→ 半空 → 引擎首拍 Fall 入场(从天而降)。
            let anchor = BehaviorPoint(x: Double(screen.width / 2), y: -100)
            return ShimejiPetRenderer(packDir: packDir, anchor: anchor, environment: env)
        }
        // 扫自有库 + 兼容目录自动注册社区 sprite 宠（兼容 Codex/petdex 格式）+
        // Live2D 模型包（工作块 D D-1，扫 ~/.petagent/pets/live2d/；D-2.2b 起 renderer 真渲染）。
        for entry in CodexSpritePackLoader.discover() + Live2DModelPackLoader.discover() {
            PetPluginRegistry.shared.register(entry)
        }
        #if canImport(Live2D)
        // 启动后为缺缩略图的 Live2D 模型后台逐个补生成(离屏渲染),不阻塞启动:延迟让 app 先就绪,
        // 每个之间 yield 让出主线程(生成是 @MainActor,与活跃 renderer 共用桥锁串行)。设置 picker
        // 下次打开时 discover 读到缓存即显示。
        let missingThumbs = Live2DModelPackLoader.model3sNeedingThumbnail()
        if missingThumbs.isEmpty == false {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                for model3 in missingThumbs {
                    Live2DModelPackLoader.thumbnailGenerator?(model3)
                    await Task.yield()
                }
            }
        }
        #endif
        let selectedPluginID = userDefaults.string(forKey: Self.petPluginUserDefaultsKey) ?? "orb"
        if selectedPluginID != "orb",
           let plugin = PetPluginRegistry.shared.plugin(for: selectedPluginID) {
            controller.replacePetRenderer(with: plugin.makeRenderer(),
                                          recommendedSize: plugin.identity.recommendedSize)
        }
        // PF6:应用保存的桌宠大小(默认 1 时 no-op)。在 renderer 装好后调,缩放当前形象。
        if petScaleSetting != 1 {
            controller.setPetScale(CGFloat(petScaleSetting))
        }
        // Phase 2 多宠同屏:起持久化的装饰物理伙伴(空集 no-op)。
        syncDecorativePets()

        // S1: 启动 mouse area + idle state 两个 tracker, callback 触发 orb
        // 微反应。tracker 是 final class, 持有 controller weak ref 防循环 retain。
        mouseAreaTracker.onAreaChanged = { [weak self] area in
            self?.handleMouseAreaChange(area)
        }
        mouseAreaTracker.start()
        // idle 翻转扇出：现有省电逻辑 + 主动引擎并联（单 var callback 不可链式 → fanout）。
        let fanout = IdleSleepingFanout()
        fanout.subscribe { [weak self] isSleeping in
            self?.handleIdleSleepingChange(isSleeping)
        }
        self.idleSleepingFanout = fanout
        idleStateTracker.onSleepingChanged = { [weak fanout] isSleeping in
            fanout?.emit(isSleeping)
        }
        idleStateTracker.start()

        // Wire state machine → pet visual feedback.
        sm.onStateChanged = { [weak controller] state in
            controller?.applyPetChatBehavior(state)
        }

        return (controller, wrappedReplyHandler)
    }

    /// A.5.3 phase 2 — Bonded session wire. Same `wrappedReplyHandler`
    /// as the legacy chatWindow for the atomic path, and a state-machine
    /// envelope around the streaming path (chatSendBegan + chatReplyBegan
    /// → tokens → chatReplyReceived). Task C 之后 BondedSession 收敛为
    /// **pet 主动智能输出** 通道(idle 短语 / 任务完成反馈 / emotion bubble);
    /// 用户主动 ask 走对话卡片 `ChatCardWindowController`,不经 BondedSession。
    func setupBondedSession(
        controller: DesktopShellController,
        replyHandler: @escaping ChatShellView.ReplyHandler
    ) {
        let capturedRootSystem = rootSystem
        guard let sm = chatBehaviorStateMachine else { return }
        let bondedSession = BondedSession(
            attachedToPet: controller.windowSet.petWindow,
            replyHandler: replyHandler,
            streamingReplyHandler: { [weak self] message in
                guard let self else {
                    return capturedRootSystem.conversationResponder.replyStream(for: message)
                }
                let seq = sm.nextSequenceID()
                self.lastChatSequenceID = seq
                sm.handle(.chatSendBegan, sequenceID: seq)
                sm.handle(.chatReplyBegan, sequenceID: seq)
                let baseStream = capturedRootSystem.conversationResponder.replyStream(for: message)
                return AsyncThrowingStream { continuation in
                    Task { [weak self] in
                        do {
                            for try await delta in baseStream {
                                continuation.yield(delta)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                        sm.handle(.chatReplyReceived, sequenceID: seq)
                        _ = self
                    }
                }
            },
            // M3.4: ChoiceCard 点击 = 召唤对话卡片并预填选项内容到 composer,
            // 不直接发送 (HermesPet 决策 #17 防误触) — 入口语义统一。
            onChoiceSelected: { [weak self] text in
                Task { @MainActor in
                    self?.chatCardWindowController?.toggleWithText(text)
                }
            },
            // N3.3: streaming 错误 → pet 形象 .refuse 反应 (Orb 默认 no-op,
            // 角色化形象在各自 plugin 里实现"摇头流汗"之类)。chain 错误气泡
            // 仍由 BondedSession.catch 内部 surface, 这里只是额外加 signal。
            onErrorSignal: { [weak self] _ in
                self?.shellController?.dispatchSignature(.refuse)
            },
            onProactiveBubbleShown: { [weak self] in
                // 反应路由 B#2:pet 主动建议/碎碎念气泡冒出 → .greet perk-up(Orb scale-pop;
                // 不支持的形象 no-op)。让 pet 对自己主动开口有反应。
                self?.shellController?.dispatchSignature(.greet)
            }
        )
        self.bondedSession = bondedSession

        // Wire ChatShellView.onSendBegan → state machine .chatSendBegan.
        // Wire ChatShellView.streamingReplyHandler → ConversationResponder.streamReply
        // so the chat window shows tokens as they arrive (A.1.3).
        if let chatView = controller.windowSet.chatWindow.contentView as? ChatShellView {
            chatView.onSendBegan = { [weak self] in
                guard let self else { return }
                let seq = sm.nextSequenceID()
                self.lastChatSequenceID = seq
                sm.handle(.chatSendBegan, sequenceID: seq)
            }

            // A.1.3: streaming wire — returns a live delta stream from the orchestrator.
            // ChatShellView iterates the stream and updates transcript after each token.
            chatView.streamingReplyHandler = { [weak self] message in
                guard let self else {
                    return capturedRootSystem.conversationResponder.replyStream(for: message)
                }
                let seq = self.lastChatSequenceID
                sm.handle(.chatReplyBegan, sequenceID: seq)
                // Wrap the stream to fire chatReplyReceived after the last token.
                let baseStream = capturedRootSystem.conversationResponder.replyStream(for: message)
                return AsyncThrowingStream { continuation in
                    Task { [weak self] in
                        do {
                            for try await delta in baseStream {
                                continuation.yield(delta)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                        sm.handle(.chatReplyReceived, sequenceID: seq)
                        _ = self  // keep self alive through the stream
                    }
                }
            }
        }
    }

    /// S3 — Pin 卡片协调器 + ⌘⇧P 全局热键。先 start controller(从磁盘
    /// 还原已有 pins),再注册热键回调拿当前 assistant 回复内容钉到桌面。
    func setupPinCard() {
        let pinController = PinCardController(pinStore: PinStore())
        self.pinCardController = pinController
        Task { @MainActor in
            await pinController.start()
        }
        let pinKey = PinCurrentReplyHotkey { [weak self] in
            self?.pinCurrentAssistantReply()
        }
        pinKey.start()
        self.pinHotkey = pinKey
    }

    /// 对话卡片控制器 + 召唤热键。四条召唤路径(⌘⇧Space / ⌥Space / pet 双击 /
    /// 灵动岛点击)统一通过 `ChatCardWindowController`：锚定 pet 旁弹出、多轮可滚动、
    /// spring 进场。每轮走 `replyStream`(写 ConversationStore + 拼历史上下文)。
    func setupChatCardAndHotkeys(controller: DesktopShellController) {
        let capturedRootSystem = rootSystem
        let cardCtrl = ChatCardWindowController(
            streamProvider: { message in
                // 多轮：replyStream 写 ConversationStore + 拼历史上下文（不同于旧 QuickAsk
                // 的 replyStreamOneShot 隔离路径 —— 对话卡片要"记住"前文）。
                capturedRootSystem.conversationResponder.replyStream(for: message)
            }
        )
        // 锚定到 pet 旁：注入 pet 锚矩形 + 屏幕可见区。App 持窗口引用注入闭包，
        // Shell 不反向 import App（依赖方向 App → Shell）。
        cardCtrl.anchorRectProvider = { [weak self] in
            self?.shellController?.windowSet.petWindow.frame ?? .zero
        }
        cardCtrl.screenFrameProvider = { [weak self] in
            self?.currentScreenFrame() ?? NSScreen.main?.visibleFrame ?? .zero
        }
        // 「清空对话」：卡片 trash 按钮 → app 确认弹窗 → 清 ConversationStore + 重置卡片。
        cardCtrl.onClearConversation = { [weak self] in self?.confirmAndClearConversation() }
        // 回复来源 segmented（直觉可用性）：Composer 上方一眼可切灵魂层/Agent engine，
        // 不必去设置深处找开关。provider 从 UD 派生当前 target + 可选项；onCommit 写 UD +
        // router.setEngine 即时生效（同设置面板 onSaveAgentModeEnabled/EngineKind 机制）。
        cardCtrl.replyConfigurationProvider = { [weak self] in
            Self.replyConfiguration(for: self?.userDefaults ?? .standard)
        }
        cardCtrl.onCommitReplyTarget = { [weak self] target in
            guard let self else { return }
            switch target {
            case .soul:
                self.userDefaults.set(false, forKey: Self.agentModeEnabledKey)
                self.agentModeRouter?.setEngine(nil)
            case .agent(let engineId):
                self.userDefaults.set(true, forKey: Self.agentModeEnabledKey)
                self.userDefaults.set(engineId, forKey: AgentEngineKind.userDefaultsKey)
                Self.applySelectedAgentEngine(to: self.agentModeRouter, defaults: self.userDefaults)
                self.wireACPPermissionHandler()   // ACP-2:engine 是 ACP 时注入 onPermissionRequest
            }
        }
        // 项目选择器 Menu(P1b 多项目):current/list 从 ProjectStore 派生;切项目重 apply engine;新建走 NSAlert。
        wireProjectConfiguration(to: cardCtrl)
        // ACP 会话管理(P2):会话选择器回调 + 开卡恢复 hook + 指针 store 读盘。
        wireACPSessionUI(to: cardCtrl)
        // 开卡片从 ConversationStore 恢复多轮历史（system 消息不展示）。
        cardCtrl.historyProvider = { [weak self] in
            guard let self else { return [] }
            // ACP(openCode)agent 模式:时间线权威在 agent 侧 —— 由 acpSessionRestoreHook
            // 按持久指针回放重建(+ 在途 exchange 乐观追加);不从 ConversationStore 恢复,
            // 避免与回放双显(ConversationStore 仍作灵魂层记忆,不展示)。
            if self.userDefaults.bool(forKey: Self.agentModeEnabledKey),
               AgentEngineRegistry.resolve(from: self.userDefaults).id == AgentEngineKind.openCode.rawValue {
                return []
            }
            guard let store = self.rootSystem.conversationStore else { return [] }
            let msgs = await store.messages()
            return msgs.compactMap { m -> ChatCardRow? in
                switch m.role {
                case .user:      return ChatCardRow(role: .user, text: m.content, timestamp: m.timestamp)
                case .assistant: return ChatCardRow(role: .assistant, text: m.content, timestamp: m.timestamp)
                case .system:    return nil
                }
            }
        }
        self.chatCardWindowController = cardCtrl

        // 卡片跟随 pet：监听 pet 窗口移动（拖动 + 物理 setFrameOrigin 都会发 didMove，
        // 即便 syncWindowsForPetPosition 临时 nil 了 delegate，通知仍照发）→ 重定位 + 尖角跟随。
        // queue:.main 闭包是 Sendable，访问 @MainActor self 用 assumeIsolated hop（决策 #5）。
        chatCardPetMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: controller.windowSet.petWindow,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.chatCardWindowController?.repositionIfVisible()
                self?.syncPermissionCard()   // 权限卡(若显示)随 pet/陪伴卡片移动跟随 + 尖角重对准
                // 贴主卡侧的窗口统一随主卡重定位(逻辑统一,同走 BesideMainLayout):列容器 + 浏览历史 sheet。
                self?.columnContainerWindowController.repositionBesideMain(
                    self?.chatCardWindowController?.window?.frame ?? .zero, screen: self?.currentScreenFrame() ?? .zero)
                self?.repositionBrowseSheetIfVisible()   // 浏览历史 sheet 跟主卡走(侧卡跟随逻辑统一)
            }
        }

        // ⌥Space 全局召唤(空唤起 / 切换)。
        let hotkey = GlobalChatHotkey { [weak self] in
            self?.toggleChatCard()
        }
        hotkey.start()
        self.chatHotkey = hotkey

        // Pet 双击 / 右键 "显示聊天" 统一路由到对话卡片。
        controller.onChatToggleRequest = { [weak self] in
            self?.toggleChatCard()
        }

        // C2 — ⌘⇧Space 快问:读选中文本 + 召唤卡片 + 预填(若有)。
        // 与 ⌥Space(空召唤)同时存在;用户可按场景选择。
        let quickAsk = QuickAskHotkey { [weak self] in
            self?.handleChatCardTriggered()
        }
        quickAsk.start()
        self.quickAskHotkey = quickAsk
    }

    /// N1 — 灵动岛胶囊: 仅在有刘海的屏 + 用户未关闭开关时创建。
    /// 点击胶囊路由到对话卡片,与 ⌥Space / 右键菜单"显示聊天" 三条召唤
    /// 路径并存(全部走 ChatCardWindowController)。
    ///
    /// 屏幕选择: 外接显示器场景 `NSScreen.main` 不一定是 MBP 自带的刘海屏,
    /// 用户可能把焦点放在外接屏上。先扫所有屏找带刘海的, 找不到再 fallback
    /// 到 main(此分支配合下面 `userEnabledIsland && mainScreenHasNotch` 守门
    /// 通常不会进入, 但保留 fallback 防 mainScreenHasNotch 报 true 而当前
    /// main 又恰好不是 notched 的边角 case)。
    func setupDynamicIsland() {
        let userEnabledIsland =
            userDefaults.object(forKey: Self.dynamicIslandEnabledKey) as? Bool ?? true
        let mainScreenHasNotch = DynamicIslandController.mainScreenHasNotch()
        let notchedScreen = NSScreen.screens.first(where: {
            DynamicIslandController.hasNotch($0)
        }) ?? NSScreen.main
        if userEnabledIsland, mainScreenHasNotch, let screen = notchedScreen {
            let island = DynamicIslandController(screen: screen, isEnabled: true)
            island.onTapped = { [weak self] in
                self?.toggleChatCard()
            }
            self.dynamicIslandController = island
        }
        // 方案 E (2026-05-26): 删除 activeSpaceObserver — activeSpaceDidChange
        // 是事后通知, 期间 panel 已跟物理刘海错位, 这套逻辑反而制造"切完闪
        // 一下"视觉 bug。HermesPet 同款决策:接受 panel 一直可见 +
        // .stationary 让 macOS 渲染层把 panel 视觉锚定在物理屏顶。
    }

    /// falling-sand 启用 + 帧循环安装 + 状态栏挂载 + companion live-context wire-up。
    func setupRuntimeAndStatusBar(controller: DesktopShellController) {
        // 菜单栏图标默认隐藏(用户可在 设置→系统→启动 开启)。pet 右键菜单是常驻入口。
        // 状态项生命周期由 MenuBarController 自管(setStatusItemVisible),App 不再单独持 statusItem。
        menuBarController.setStatusItemVisible(menuBarIconVisibleSetting())
        // falling-sand 是唯一雪路径，启动即启用（按 cellSize 建 engine）。
        controller.setFallingSandEnabled(true, cellSize: Self.fallingSandCellSize)
        SnowDiagnostics.log("fallingSandEnabledAtLaunch")
        // 应用持久化的调试调参（设置 → 调试）。
        fallingSandTuning = Self.loadFallingSandTuning(from: userDefaults)
        controller.setFallingSandTuning(fallingSandTuning)
        petMotionController.tuning = Self.loadBallisticTuning(from: userDefaults)   // 弹力球抛射调参(设置→调试)
        // 启动打招呼:延迟 0.6s 让 pet 窗口先现身,再做一次 .greet(Orb scale-pop / sprite wave / Live2D 招手);
        // 不支持 .greet 的形象经 dispatchSignature 自动 no-op。
        Task { @MainActor [weak controller] in
            try? await Task.sleep(for: .milliseconds(600))
            controller?.dispatchSignature(.greet)
        }
        SnowDiagnostics.log("didFinishLaunching shellShown windows=\(controller.windowSet.allWindows.count)")
        frameLoopHandle = startFrameLoop { [weak self] in
            SnowDiagnostics.log("timerTick")
            await self?.advanceRuntimeFrame()
        }
        SnowDiagnostics.log("frameLoopInstalled hasHandle=\(frameLoopHandle != nil)")
        PerfDiagnostic.startIfEnabled()   // PETAGENT_DEBUG_PERF=1 → 每 5s 性能心跳(未设则零成本)
        // 防 App Nap 把 main-queue 帧循环 timer 合并成卡顿突发(后台/失焦时尤甚 —— 这是「移动变卡」的帮凶)。
        // `userInitiatedAllowingIdleSystemSleep`:既免 App Nap,又允许系统在用户离开时正常息屏睡眠。
        // token 在 applicationWillTerminate 释放。
        if frameRateActivityToken == nil {
            frameRateActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "桌宠连续动画需稳定帧率,避免 App Nap timer 合并")
        }
        // 帧率随「宠物窗口是否可见」自适应:可见 → 满 30Hz 顺滑;被完全遮挡 → 降 6Hz 省电(看不到时无感)。
        // 取代旧的「按键鼠空闲降频」(空闲≠没在看,会让用户盯着看时也卡)。事件驱动,非每帧轮询。
        if petOcclusionObserver == nil {
            petOcclusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handlePetVisibilityChange() }
            }
        }
        handlePetVisibilityChange()   // 按当前可见性设初始帧率

        // A.2.2: wire petContextProvider now that currentRenderState and
        // isSnowEnabled are live. The [weak self] guard falls back to idle
        // defaults when the delegate has been deallocated.
        if let box = liveContextBox {
            Task { [weak self, box] in
                await box.setPetContextProvider { [weak self] in
                    guard let self else {
                        return PetContext(behavior: .idle, isSnowEnabled: false)
                    }
                    let behavior = await MainActor.run { self.currentRenderState.companionBehavior }
                    let snow = await MainActor.run { self.isSnowEnabled }
                    return PetContext(behavior: behavior, isSnowEnabled: snow)
                }
            }
        }
    }

    // MARK: - Screen configuration changes (M.1)

    func handleScreenConfigurationChange() {
        guard let registry = overlayRegistry else { return }
        let frame = currentScreenFrame()
        registry.sync(
            displayIDs: currentDisplayIDs(),
            screenFrameProvider: { _ in frame }
        )
        Self.populateFullScreenFrames(registry: registry)
    }

    /// Fill `registry.fullScreenFrames` from the live `NSScreen.screens` list.
    ///
    /// Required because the production wiring above uses
    /// `sync(displayIDs:screenFrameProvider:)` (test-friendly, NSScreen-free)
    /// rather than `sync(screens:)`. That path leaves `fullScreenFrames` empty,
    /// which makes `tickRegistryCoordinators` silently fall back to
    /// `visibleFrame` for its y-flip math — and that is exactly the
    /// "snow falls through window tops by ~24px" bug. By populating the full
    /// frames here right after sync, the tick always has the real
    /// `NSScreen.frame` height available.
    ///
    /// In headless test environments `NSScreen.screens` is empty, so this is
    /// a no-op there (the test path keeps relying on the visibleFrame
    /// fallback, which is fine because tests don't care about menu-bar
    /// alignment).
    static func populateFullScreenFrames(registry: OverlayWindowRegistry) {
        var fullMap: [CGDirectDisplayID: NSRect] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            fullMap[id] = screen.frame
        }
        registry.fullScreenFrames = fullMap
    }

    // MARK: - Phase 0: 天气数据层 wire

    /// 用 lastWeatherSnapshot + 当前 Date() 重 format weather description,
    /// 推到 settings + 菜单栏。让"距今 N 分钟"字段每分钟自动更新 (weather 真
    /// 刷新 15min 一次, timestamp 不变, 但相对时间每分钟变一次, 用户能看到
    /// 时间在动)。60s timer 重复调用 — 数据不变只是文案更新, 零网络开销。
    func refreshWeatherDescription() {
        guard let snapshot = lastWeatherSnapshot else { return }
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(snapshot.timestamp))
        let relativeTime: String
        if elapsed < 60 {
            relativeTime = "刚刚更新"
        } else if elapsed < 3600 {
            relativeTime = "\(Int(elapsed / 60)) 分钟前更新"
        } else {
            relativeTime = "\(Int(elapsed / 3600)) 小时前更新"
        }
        let desc = String(format: "🌡 %.1f°C   💨 %.1f m/s   ☁ %@   ⏰ %@",
                          snapshot.temperature,
                          snapshot.windSpeed,
                          snapshot.condition.rawValue,
                          relativeTime)
        currentWeatherDescription = desc
        settingsWindowController?.updateCurrentWeatherDescription(desc)
        menuBarController.updateWeatherCurrent(desc)
        shellController?.updateMenuWeatherCurrent(desc)   // pet 右键菜单天气行同步(两菜单一致)
    }

    /// 启动 `WeatherStateManager` 并把 onUpdate 闭包 wire 进物理沙盒。
    /// 每次刷新成功 → 温度(°C → 0..1 归一化)写 `fallingSandAmbientTemperature`
    /// （温度模式覆盖档非 auto 时用覆盖值无视天气）；风速写 rain coordinator。
    /// 注：天气风速 → falling-sand 雪的动态 wind 联动是 follow-up（当前 FS 用恒定
    /// 轻风）；记录在 post-physics-roadmap。
    func setupWeatherStateManager() {
        // 生产用 Open-Meteo 真实天气 (免费 / 无需 entitlement)。网络失败时
        // WeatherStateManager.refresh() 的失败降级路径会自动 fallback 到
        // SimulatedWeatherService, 避免雪 simulation 卡在初始值。
        // 城市从 UserDefaults 读 (Settings 城市 picker 持久化), 默认北京。
        let cityID = userDefaults.string(forKey: CityCatalog.userDefaultsKey) ?? CityCatalog.default.id
        let location = CityCatalog.city(forID: cityID).coordinate
        let manager = WeatherStateManager(
            provider: OpenMeteoService(),
            location: location
        )
        manager.onUpdate = { [weak self] snapshot in
            // snapshot.temperature 是 °C (-20..40) → 归一化 0..1
            // (FallingSandRules.meltThreshold=0.50≈10°C)。
            // 映射: -20°C → 0 (冰雪不融), 10°C → 0.5 (临界融化), 40°C → 1 (全融)。
            let tCelsius = Float(snapshot.temperature)
            let normalizedTemp = max(0, min(1, (tCelsius + 20) / 60))
            // 记下天气驱动温度（切回 auto 时用它恢复）。温度模式覆盖档非 auto 时，
            // 用覆盖值无视天气；auto 时天气驱动 ambient（设置 → 天气 温度模式）。
            self?.lastWeatherNormalizedTemp = normalizedTemp
            let effectiveTemp = (self?.thermalOverride.ambientTemperature) ?? normalizedTemp
            self?.fallingSandAmbientTemperature = effectiveTemp
            SnowDiagnostics.log(
                "weatherUpdated temp=\(snapshot.temperature) wind=\(snapshot.windSpeed) cond=\(snapshot.condition.rawValue)"
            )
            // 同步推 Settings"当前天气"卡片(若窗口开着)+ 缓存到 delegate
            // 让下次打开 Settings 立刻能显示最新值。
            guard let self else { return }
            self.lastWeatherSnapshot = snapshot
            self.refreshWeatherDescription()
            self.dynamicIslandController?.updateWeather(snapshot.condition)

            // Phase B 雨/雪 condition 联动 (#53 部分): weather 是 authoritative
            // source of truth — snowy → 雪开 + 雨关;rainy → 雨开 + 雪关;
            // 其他 condition (sunny/cloudy/windy) → 都关。
            //
            // 用户的"持续覆盖" 通过 Settings → 强制天气 / 菜单「天气」submenu 单选实现
            //(forcedCondition 持久覆盖 snapshot.condition, 任何 weather refresh 都尊重)。
            // 降水联动 — 受天气总开关 gate（weatherEffectsEnabled off → 雪/雨全关）。
            self.applyPrecipitation(condition: snapshot.condition)
        }
        // 启动时应用持久化的 forcedCondition (Settings save 后写 UD)。
        if let forced = userDefaults.string(forKey: Self.forcedWeatherConditionKey),
           forced != "auto",
           let kind = WeatherConditionKind(rawValue: forced) {
            manager.updateForcedCondition(kind)
        }
        self.weatherStateManager = manager
        // start() async — Task wrap, 不阻塞 didFinishLaunching。首次 fetch
        // (~ms 级 SimulatedWeatherService) 完成后 onUpdate 写 coordinator。
        Task { await manager.start() }

        // 自动跟随位置:启动初始仍用城市坐标建 manager(同步、不阻塞启动、不触发 TCC dialog)。
        // 若 autoFollowLocation UD 已开 且 CoreLocation 已授权 → 启动后**异步**取一次真实坐标
        // 调 updateLocation(不等 start(),避免 TCC dialog 拦截启动序列)。
        let autoFollow = userDefaults.bool(forKey: Self.autoFollowLocationKey)
        if autoFollow, locationAdapter?.permissionStatus == .granted {
            locationAdapter?.requestOneShotLocation { [weak self] coord in
                guard let self, let coord else { return }
                Task { await self.weatherStateManager?.updateLocation(coord) }
            }
        }

        // 60s timer 重 format weather description, 让"距今 N 分钟"字段动起
        // 来。零网络开销 — 只在 lastWeatherSnapshot 基础上 reformat 文案。
        weatherDescriptionRefreshTimer?.invalidate()
        let descTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWeatherDescription()
            }
        }
        RunLoop.main.add(descTimer, forMode: .common)
        weatherDescriptionRefreshTimer = descTimer
    }

    /// 应用降水联动（雪/雨开关），受 `weatherEffectsEnabled` 总开关 gate（off →
    /// 雪/雨全关，桌面干净）。天气 onUpdate 与「天气效果」总开关 toggle 共用，
    /// 避免重复 RenderState rebuild 逻辑。
    func applyPrecipitation(condition: WeatherConditionKind?) {
        let showSnow = (condition == .snowy) && weatherEffectsEnabled
        let showRain = (condition == .rainy) && weatherEffectsEnabled
        if isRainEnabled != showRain {
            isRainEnabled = showRain   // 驱动 FS 雨（tickFallingSand spawnRain，雨 = water 粒子）
        }
        if isSnowEnabled != showSnow {
            isSnowEnabled = showSnow
            // 必须同步 rebuild currentRenderState，否则 RuntimeFrame 读
            // currentRenderState.isSnowEnabled 永远 false → GPU 不 spawn。
            currentRenderState = RenderState(
                petPositionX: currentRenderState.petPositionX,
                petPositionY: currentRenderState.petPositionY,
                petRotation: currentRenderState.petRotation,
                particleCount: currentRenderState.particleCount,
                particles: currentRenderState.particles,
                contactCount: currentRenderState.contactCount,
                isSnowEnabled: showSnow
            )
            shellController?.syncSnowPlaceholder(isEnabled: showSnow)
        }
    }
}
