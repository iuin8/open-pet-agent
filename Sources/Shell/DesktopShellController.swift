import AppKit
import Context
import Orchestrator
import QuartzCore
import Rendering
import RuntimeBridge

@MainActor
public final class DesktopShellController {
    public typealias InteractionEventSink = @MainActor (ShellInteractionEvent) -> Void

    public let diagnostics: ShellGraphDiagnostics
    public let windowSet: ShellWindowSet
    public private(set) var interactionEvents: [ShellInteractionEvent] = []

    private let screenFrame: NSRect
    private let interactionEventSink: InteractionEventSink
    private let petWindowDragAdapter = PetWindowDragAdapter()

    /// Pet 形象速度耦合驱动器（P2 抽出）：持有当前 `PetRenderer` + drag/runtime 两条
    /// 速度链路 → renderer squash。控制器经 `petRenderer` 转发属性暴露它，并在拖拽/
    /// runtime 帧把速度委托给它。
    private let petVisualDriver = PetVisualDriver()

    /// Floats above the pet, mirrors `ChatBehaviorState` as a one-line
    /// emotional cue ("嗯？" / "想想…" / "好啦" / "嗯？？"). Hidden when
    /// state is `.idle`. The bubble follows the pet via `addChildWindow`
    /// so manual position sync isn't normally needed; we still
    /// re-anchor on programmatic pet moves to be safe.
    public private(set) var petEmotionBubble: PetEmotionBubble?

    /// Pet visual renderer (A.5.1). Replaces the orange-rectangle
    /// placeholder with an Orb (Metal SDF + Fresnel + flow). `nil` when
    /// Metal is unavailable (headless CI, certain VM configs) — the
    /// pet window then keeps the placeholder content view as a
    /// graceful fallback so tests that don't need GPU still run.
    ///
    /// `internal(set)` so tests can inject a test double and verify that
    /// `applyPetChatBehavior` fans state out to both pet and Stage mini-orb
    /// renderers in lockstep. 实际存储下沉到 `petVisualDriver`（P2）——此处是转发
    /// 计算属性，公开 API 与原 stored 属性逐字等价。
    public internal(set) var petRenderer: PetRenderer? {
        get { petVisualDriver.petRenderer }
        set { petVisualDriver.petRenderer = newValue }
    }

    /// PF6 全局桌宠大小因子(0.5–2.0,1=原始)。自管窗口形象(Shimeji)经 `applyScale` 注入、
    /// 每帧自行缩放;host 仲裁形象由 `resizePetWindow(基准尺寸×scale)` 缩放窗口。
    private var petScale: CGFloat = 1
    /// 当前形象的**未缩放**推荐窗口尺寸(`replacePetRenderer` 时记下),缩放时 ×petScale。
    private var basePetWindowSize = NSSize(width: 72, height: 72)

    /// MinimalAppDelegate sets this once at launch to route pet-click /
    /// "显示聊天" intents through the Bonded chat surface. When `nil` the
    /// controller falls back to the legacy `chatWindow.makeKeyAndOrderFront`
    /// path so unit tests that only poke `showChatWindow` directly still work.
    public var onChatToggleRequest: (@MainActor () -> Void)?

    /// 单击 pet 的「轻反应」延迟确认 task（用 `NSEvent.doubleClickInterval` 去抖）：
    /// 双击第一拍 mouseUp 先排这个 task，第二拍到达时 cancel → 双击只开卡片、不先抖一下、
    /// 也不重复 `.acknowledge`；单击则等过双击窗口才真正做轻反应。
    private var pendingClickReaction: Task<Void, Never>?

    /// 上一次 `applyPetChatBehavior` 收到的状态。供 LifeSigns 完成跳跃判定
    /// (`talking → idle` 视为一轮 reply 流式结束)、`roamLiveliness` 推漫步活跃度、
    /// `replacePetRenderer` 换装后重发情绪态。
    private var previousChatBehaviorState: ChatBehaviorState?

    public init(
        windowGraph: WindowGraph = .bootstrap,
        screenFrame: NSRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
        initialState: ShellInitialState = .default,
        interactionEventSink: @escaping InteractionEventSink = { _ in },
        chatReplyHandler: @escaping ChatShellView.ReplyHandler = { message in
            "我听到“\(message)”了。"
        },
        quitHandler: @escaping @MainActor () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        let resolution = ShellWindowFactory.resolveDescriptors(from: windowGraph)
        self.diagnostics = resolution.diagnostics
        self.screenFrame = screenFrame
        self.interactionEventSink = interactionEventSink
        self.windowSet = ShellWindowFactory.makeWindowSet(
            descriptors: resolution.descriptors,
            screenFrame: screenFrame,
            initialState: initialState,
            chatReplyHandler: chatReplyHandler
        )
        // 右键菜单的跟随/漫游项仅对程序化形象(Orb/Slime)生效;pull 式闭包读当前 petRenderer 的
        // driveModel,换形象后右键菜单打开时自动灰掉、不会 stale(petRenderer 此刻可能尚未注入,闭包延迟求值)。
        (windowSet.petWindow as? PetShellWindow)?.isMotionApplicable = { [weak self] in
            self?.petRenderer?.driveModel.supportsHostDrivenMotion ?? true
        }
        petWindowDragAdapter.install(
            onWindowDidMove: { [weak self] position in
                self?.handlePetDragDidMove(to: position)
            },
            onDragDidEnd: { [weak self] position in
                self?.handlePetDragDidEnd(at: position)
            },
            onDragDidStart: { [weak self] in
                // item1:抓起惊跳。layer 级,全形象通用(Orb/sprite/Live2D 都看得到)。
                if let layer = self?.windowSet.petWindow.contentView?.layer {
                    PetChatAnimator.triggerJump(on: layer)
                }
            }
        )
        (self.windowSet.petWindow as? PetShellWindow)?.install(
            onMouseDown: { [weak self] in
                guard let self else { return }
                // P4-B-5:Shimeji 引擎形象自管位置 → 按下转引擎(抓起 → Dragged),不走 drag adapter。
                if self.petRenderer?.drivesOwnWindowPosition == true {
                    self.petRenderer?.handlePointerDown()
                    return
                }
                self.petWindowDragAdapter.windowMouseDown()
            },
            onMouseUp: { [weak self] position, clickCount in
                guard let self else {
                    return
                }
                // Shimeji 引擎形象:释放转引擎(甩出 → Thrown,初速=光标速度),不走点击/拖拽链。
                if self.petRenderer?.drivesOwnWindowPosition == true {
                    self.petRenderer?.handlePointerUp()
                    return
                }

                let endedDrag = petWindowDragAdapter.windowMouseUp(afterDraggingAt: position)
                guard endedDrag == false else { return }   // 拖动结束不算点击
                // 双击第二拍到达 → 取消挂起的单击轻反应（双击只开卡片，不先抖一下 + 不重复 .acknowledge）。
                pendingClickReaction?.cancel()
                pendingClickReaction = nil
                if clickCount >= 2 {
                    showChatWindow()   // 双击 → 弹对话卡片（route 到 toggleChatCard）
                    return
                }
                // 单击 → 等过 doubleClickInterval 确认不是双击首拍，再做轻反应：layer 级轻跳
                // （跟 pet 形象正交、Orb 上也可见，不像 .acknowledge 在 Orb 上是 no-op）+
                // acknowledge 信号（角色化形象可特化）。
                pendingClickReaction = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                    guard !Task.isCancelled, let self else { return }
                    if let layer = self.windowSet.petWindow.contentView?.layer {
                        PetChatAnimator.triggerJump(on: layer)
                    }
                    self.dispatchSignature(.acknowledge)
                    self.pendingClickReaction = nil
                }
            },
            onMouseDragged: { [weak self] newOrigin in
                guard let self else { return }
                // Shimeji 引擎形象:拖拽期间位置由引擎 Dragged 行为(anchor=cursor+offset)每帧产出,
                // 不路由窗口移动(否则与引擎 advance 抢窗抖动)。
                if self.petRenderer?.drivesOwnWindowPosition == true { return }
                // 改2:显式拖拽(isMovableByWindowBackground=false)→ 驱动 adapter 拖拽链
                // (置 hasPendingDragRelease=true → handlePetDragDidMove 移窗 + recordPetDrag),
                // 让 isPetBeingDragged 整段拖拽稳定为 true(漫游 gate 据此让位)。
                self.petWindowDragAdapter.windowDragDidMove(to: newOrigin)
            },
            onShowChat: { [weak self] in
                self?.showChatWindow()
            },
            onQuit: quitHandler
        )
        self.windowSet.petWindow.delegate = petWindowDragAdapter

        // The emotion bubble attaches as a child of the pet window so it
        // follows the pet through every drag + programmatic move. Starts
        // hidden (alphaValue=0); the first non-`.idle` state change fades
        // it in.
        // Perf-debug: PETAGENT_NO_EMOTION_BUBBLE=1 skips creating the pet
        // emotion bubble. It's an NSPanel `addChildWindow`-attached to the pet
        // window and a suspect for WindowServer compositor overhead during pet
        // drags. If disabling this restores smoothness, the bubble (or its
        // visual-effect layer) is the culprit.
        if ProcessInfo.processInfo.environment["PETAGENT_NO_EMOTION_BUBBLE"] != "1" {
            self.petEmotionBubble = PetEmotionBubble(attachedTo: self.windowSet.petWindow)
        }

        // A.5.1 — install Orb renderer as the pet's content view, replacing
        // the orange placeholder rectangle. Failable: on Metal-less
        // systems we keep the placeholder so the rest of the shell still
        // works (drag / click / emotion bubble all run on the NSView, not
        // its renderer).
        // Perf-debug: PETAGENT_NO_ORB=1 skips Pet Orb (keep placeholder
        // orange view). Tests whether the Orb CAMetalLayer is the
        // compositor-bottleneck source.
        let petOrbDisabled = ProcessInfo.processInfo.environment["PETAGENT_NO_ORB"] == "1"
        if !petOrbDisabled, let orb = OrbMetalRenderer() {
            // Carry over the right-click menu from the placeholder (installed
            // by `PetShellWindow.installContextMenu` a few lines above) so
            // 显示聊天 / 设置 / 天气 / 退出 still fire on the new view.
            let inheritedMenu = self.windowSet.petWindow.contentView?.menu
            let host = PetLayerHostView(content: orb.contentLayer)
            host.menu = inheritedMenu
            self.windowSet.petWindow.contentView = host
            self.petRenderer = orb
        }
    }

    public func showInitialWindows() {
        windowSet.overlayWindow.orderFrontRegardless()
        windowSet.petWindow.makeKeyAndOrderFront(nil)
        // Legacy `chatWindow` (`ChatBubblePanel` + `ChatShellView`) is no
        // longer the primary chat surface — Bonded 模式 (A.5.3 phase 2) 是
        // 默认且唯一对话路径。The legacy panel stays alive as a fallback
        // surface (pet 右键 "显示聊天" can still summon it via
        // `showChatWindow()`), but it must not be visible by default.
        // Physical removal of `ChatBubblePanel.swift` / `ChatShellView.swift`
        // is deferred to a refactor-cleaner pass.
    }

    public func recordPetDrag(to position: NSPoint) {
        recordInteractionEvent(.petDrag(positionX: position.x, positionY: position.y))
    }

    public func recordPetRelease(at position: NSPoint) {
        recordInteractionEvent(.petRelease(positionX: position.x, positionY: position.y))
    }

    public func handlePetDragDidMove(to position: NSPoint) {
        syncWindowsForPetPosition(position)
        recordPetDrag(to: position)
        petVisualDriver.feedDragVelocity(to: position)
    }

    public func handlePetDragDidEnd(at position: NSPoint) {
        syncWindowsForPetPosition(position)
        recordPetRelease(at: position)
        // Release: clear velocity so the orb eases back to its chat-state
        // base + reset tracking so a new drag starts from a clean origin.
        petVisualDriver.dragDidEnd()
        // item1:松手反应 —— 形象专属 reactToDragEnd(sprite 晕帧/slime 抖)+ layer 级回弹(全形象通用)。
        dispatchSignature(.reactToDragEnd)
        if let layer = windowSet.petWindow.contentView?.layer {
            PetChatAnimator.triggerJump(on: layer)
        }
    }

    public func syncPetPosition(x: Double, y: Double) {
        syncWindowsForPetPosition(NSPoint(x: x, y: y))
    }

    /// P4-B-5:Shimeji 原始帧引擎自管位置 —— 直接按引擎产出的 frame(bottom-origin)摆 pet 窗
    /// (含尺寸,Shimeji 帧尺寸随姿势变)。绕开 `syncWindowsForPetPosition` 的 chat 窗联动 + clamp
    /// (引擎已自管边界)。delegate 摘挂避免程序化移动被当用户拖拽。情绪气泡随窗重锚。
    public func moveShimejiPetWindow(toFrame frame: NSRect) {
        let window = windowSet.petWindow
        let originalDelegate = window.delegate
        window.delegate = nil
        window.setFrame(frame, display: true)
        window.delegate = originalDelegate
        petEmotionBubble?.repositionAbovePet()
    }

    /// item2 mood:由当前 chat 情绪态推自主漫步「活跃度」(0..1)。talking/watching 活泼(暂停短/走得快),
    /// thinking/confused 慵懒(暂停长/走得慢),idle 中性。供 `advanceRuntimeFrame` 喂 `PetMotionInput.liveliness`
    /// (参考 GodotDesktopPet mood-weighted 动作,只借思路)。
    public var roamLiveliness: Double {
        guard let state = previousChatBehaviorState else { return 0.5 }
        switch PetEmotionState.from(state) {
        case .talking, .watching: return 0.85
        case .thinking, .confused: return 0.35
        case .idle: return 0.5
        }
    }

    /// 用户当前是否正在拖拽 pet。供 `advanceRuntimeFrame` 的漫游块 gate ——
    /// 拖拽时漫游必须让位(grab 优先,对齐 HermesPet `if isBeingDragged { return }`),
    /// 否则 60fps 漫游的 setFrameOrigin 会每帧把用户拖到的位置盖回去(表现为"拖不动")。
    public var isPetBeingDragged: Bool { petWindowDragAdapter.isCurrentlyDragging }

    /// Per-frame hook from `MinimalAppDelegate.advanceRuntimeFrame`: after the
    /// runtime hands back a new `pet_pose`, the delegate calls this with the
    /// new world position and the same `now` it used for `deltaTime`. 速度估算
    /// 与 gating（首帧/拖拽中/idle 阈值）的内核在 `PetVisualDriver.applyRuntimeVelocity`；
    /// 此处只把「是否正在拖拽」从 drag adapter 读出后转发。
    public func applyRuntimePetVelocity(
        position: NSPoint,
        now: TimeInterval
    ) {
        petVisualDriver.applyRuntimeVelocity(
            position: position,
            now: now,
            isDragging: petWindowDragAdapter.isCurrentlyDragging
        )
    }

    /// 工作块 A —— 把 `PetMotionController` 每帧产出的形象无关运动态转发给
    /// 当前 pet 形象。Orb 默认忽略(no-op),sprite 形象按 walking 朝向切走帧。
    /// 由 `MinimalAppDelegate.advanceRuntimeFrame` 在 `syncPetPosition` 同帧调。
    public func applyPetMotion(_ phase: PetMotionPhase) {
        petRenderer?.updateForMotion(phase)
    }

    /// Task 5 —— 把 agent 活动视觉态推给当前形象的 `updateForActivity` 通道。
    ///
    /// 仅 `.activityStateIndicator` 形象（petdex sprite）真正消费；其余形象的
    /// `updateForActivity` 是协议默认 no-op，调用安全、无副作用。
    /// 调用方（AgentSensingWiring）已经过 `ActivityCoalescer` 防抖，此处无需再判重复。
    @MainActor public func applyPetActivity(_ visual: PetActivityVisual) {
        petRenderer?.updateForActivity(visual)
    }

    /// 工作块 B3 —— 把淋湿程度(0..1)转发给当前 pet 形象(sprite 叠水渍,Orb no-op)。
    /// 由 `MinimalAppDelegate.advanceRuntimeFrame` 每帧按 isRainEnabled lerp 后调。
    public func applyPetWetness(_ level: Float) {
        petRenderer?.updateForWetness(level)
    }

    public func syncSnowPlaceholder(isEnabled: Bool, particles: [CGPoint] = []) {
        (windowSet.overlayWindow.contentView as? DesktopOverlayView)?.setSnowPlaceholderVisible(
            isEnabled,
            particles: particles
        )
        // 雪开关已统一进「天气」submenu 单选(强制下雪 / 关闭天气效果),不再有独立「下雪」菜单项。
    }

    public func advanceSnowPlaceholderFrame() {
        (windowSet.overlayWindow.contentView as? DesktopOverlayView)?.advanceSnowPlaceholderFrame()
    }

    /// 菜单批 A + B: 让 caller (MinimalAppDelegate) 在 shellController 创建
    /// 后注入"设置..." / "📷 截图分享" / "天气 →" 三个高层 callback。pet 右
    /// 键菜单走这些 closure, 跟菜单栏入口共享同一执行路径。
    public func setMenuCallbacks(
        onSettings: @escaping @MainActor () -> Void,
        onShareScreenshot: @escaping @MainActor () -> Void,
        onForceConditionSelected: @escaping @MainActor (String) -> Void = { _ in },
        onClearWeather: @escaping @MainActor () -> Void = {},
        onClearConversation: @escaping @MainActor () -> Void = {},
        initialForcedConditionRaw: String = "auto",
        onToggleFollowing: @escaping @MainActor (Bool) -> Void = { _ in },
        onToggleRoaming: @escaping @MainActor (Bool) -> Void = { _ in },
        initialFollowingEnabled: Bool = false,
        initialRoamingEnabled: Bool = true
    ) {
        guard let petWindow = windowSet.petWindow as? PetShellWindow else { return }
        petWindow.updateMenuCallbacks(
            onSettings: onSettings,
            onShareScreenshot: onShareScreenshot,
            onForceConditionSelected: onForceConditionSelected,
            onClearWeather: onClearWeather,
            onClearConversation: onClearConversation,
            onToggleFollowing: onToggleFollowing,
            onToggleRoaming: onToggleRoaming
        )
        petWindow.syncForcedConditionState(initialForcedConditionRaw)
        petWindow.syncSpatialBehavior(following: initialFollowingEnabled, roaming: initialRoamingEnabled)
    }

    /// 把当前天气模式 raw(含 "off")同步到 pet 右键菜单 submenu check state。
    public func syncForcedConditionState(_ raw: String) {
        (windowSet.petWindow as? PetShellWindow)?.syncForcedConditionState(raw)
    }

    /// 把「当前天气」展示行同步到 pet 右键菜单(与状态栏一致,weather 更新时调)。
    public func updateMenuWeatherCurrent(_ description: String) {
        (windowSet.petWindow as? PetShellWindow)?.updateWeatherCurrent(description)
    }

    /// 把跟随 / 漫游开关状态同步到 pet 右键菜单 check state(跨入口一致)。
    public func syncSpatialBehavior(following: Bool, roaming: Bool) {
        (windowSet.petWindow as? PetShellWindow)?.syncSpatialBehavior(following: following, roaming: roaming)
    }

    // MARK: - Falling-sand CA path（唯一雪路径）

    public func setFallingSandEnabled(_ enabled: Bool, cellSize: Float) {
        (windowSet.overlayWindow.contentView as? DesktopOverlayView)?
            .setFallingSandEnabled(enabled, cellSize: cellSize)
    }

    public var fallingSandGridSize: (width: Int, height: Int)? {
        (windowSet.overlayWindow.contentView as? DesktopOverlayView)?.fallingSandGridSize
    }

    public func tickFallingSand(spawnSnow: Bool, spawnRain: Bool, ambient: Float, rects: [SIMD4<Float>]) {
        (windowSet.overlayWindow.contentView as? DesktopOverlayView)?
            .tickFallingSand(spawnSnow: spawnSnow, spawnRain: spawnRain, ambient: ambient, rects: rects)
    }

    public func clearFallingSand() {
        (windowSet.overlayWindow.contentView as? DesktopOverlayView)?.clearFallingSand()
    }

    /// 设置可调物理参数（设置 → 调试 面板，实时生效）。
    public func setFallingSandTuning(_ tuning: FallingSandTuning) {
        (windowSet.overlayWindow.contentView as? DesktopOverlayView)?.setFallingSandTuning(tuning)
    }

    /// 工作块 B1 —— 雪堆 pet。`enabled` 时取当前 pet 形象的帧 alpha 轮廓（Orb 等返回
    /// nil → 自动关），按 pet 世界位置算占位 cell 原点，转发给 falling-sand engine 作
    /// 第二 occluder。由 `MinimalAppDelegate.advanceRuntimeFrame` 在 tickFallingSand 同帧调
    /// （pet 移动/换帧 → 每帧重栅格化，雪随之响应）。maxDim 用引擎 buffer 容量上限。
    public func applyPetOccluder(enabled: Bool, cellSize: Float, originCellX: Int, originCellY: Int) {
        let overlay = windowSet.overlayWindow.contentView as? DesktopOverlayView
        guard enabled,
              let mask = petRenderer?.currentFrameAlphaMask(
                  cellSize: cellSize, maxDim: FallingSandGPUEngine.maxPetMaskDim)
        else {
            overlay?.uploadPetOccluder(nil, originCellX: 0, originCellY: 0)
            return
        }
        overlay?.uploadPetOccluder(mask, originCellX: originCellX, originCellY: originCellY)
    }

    /// 工作块 B2 —— pet 扬雪。pet 走动时把身边飞行雪粒子沿运动方向横扫上扬（踩雪喷散）。
    /// AABB = pet 占位（origin + pet 窗口尺寸 / cellSize）；velX 由 app 算的帧间 Δx/dt。
    /// `enabled` 否（无雪 / pet 静止）→ 关。由 `advanceRuntimeFrame` 在 tickFallingSand 同帧调。
    public func applyPetSnowSweep(enabled: Bool, cellSize: Float, originCellX: Int, originCellY: Int, velX: Float) {
        let overlay = windowSet.overlayWindow.contentView as? DesktopOverlayView
        guard enabled, cellSize > 0 else { overlay?.uploadPetSweep(nil); return }
        let petSize = windowSet.petWindow.frame.size
        let wCells = Float(Double(petSize.width) / Double(cellSize))
        let hCells = Float(Double(petSize.height) / Double(cellSize))
        overlay?.uploadPetSweep(FallingSandDriver.PetSweepFrame(
            minX: Float(originCellX), minY: Float(originCellY),
            maxX: Float(originCellX) + wCells, maxY: Float(originCellY) + hCells,
            velX: velX))
    }

    /// Returns the overlay NSWindow for use by the screenshot service.
    /// Callers (e.g. MinimalAppDelegate) pass this window to
    /// `OverlayScreenshotService.captureAndShare` so the screenshot always
    /// targets the correct surface regardless of which screen the overlay is on.
    public var overlayWindowForScreenshot: NSWindow {
        windowSet.overlayWindow
    }

    public var overlayBoundsForSnow: CGSize {
        (windowSet.overlayWindow.contentView as? DesktopOverlayView)?.bounds.size ?? screenFrame.size
    }

    public func syncCompanionBehavior(_ behavior: CompanionBehavior) {
        (windowSet.chatWindow.contentView as? ChatShellView)?.updateCompanionBehavior(behavior)
    }

    public func showChatWindow() {
        // Route through MinimalAppDelegate's Bonded toggle when wired.
        // Legacy chatWindow stays hidden under normal user flow; the direct
        // fallback is only for unit tests that don't set the callback.
        if let handler = onChatToggleRequest {
            handler()
            return
        }
        windowSet.chatWindow.makeKeyAndOrderFront(nil)
    }

    /// Translates a `ChatBehaviorState` into CALayer animations on the pet
    /// content view. Delegates all animation logic to `PetChatAnimator`.
    @MainActor
    public func applyPetChatBehavior(_ state: ChatBehaviorState) {
        if let layer = windowSet.petWindow.contentView?.layer {
            PetChatAnimator.apply(state, to: layer)
            // LifeSigns 完成跳跃 (M2.3 + N3.3): talking → idle 视为一轮 reply
            // 流式结束。layer 层 ambient jump 仍走 PetChatAnimator (跟所有 pet
            // 形象正交, 即使 Orb 换成史莱姆这条 ambient 反馈也保留); 同时
            // dispatchSignature(.celebrate) 让 renderer 自己加形象特化反应
            // (Orb 默认 supportedSignatures 空集 → no-op, 史莱姆 / Ferris 等
            // 角色化形象在各自插件里实现)。
            if previousChatBehaviorState == .talking, state == .idle {
                PetChatAnimator.triggerJump(on: layer)
                dispatchSignature(.celebrate)
            }
        }
        previousChatBehaviorState = state
        // Emotion bubble: show / hide the matching short copy.
        petEmotionBubble?.updateForState(state)
        // Orb renderer: drive shader uniforms (color hue / flow speed /
        // vortex / squash) to match the chat state. The bridge keeps
        // Rendering free of any Orchestrator import.
        let orbState = PetEmotionState.from(state)
        petRenderer?.updateForState(orbState)
    }

    private func syncWindowsForPetPosition(_ position: NSPoint) {
        let petFrame = windowSet.petWindow.frame

        let originalDelegate = windowSet.petWindow.delegate
        windowSet.petWindow.delegate = nil
        windowSet.petWindow.setFrameOrigin(position)
        windowSet.petWindow.delegate = originalDelegate

        let chatSize = windowSet.chatWindow.frame.size
        let preferredChatOrigin = NSPoint(
            x: position.x + petFrame.width + 40,
            y: position.y + (petFrame.height - chatSize.height) / 2
        )
        let syncedChatOrigin = NSPoint(
            x: min(max(preferredChatOrigin.x, screenFrame.minX), screenFrame.maxX - chatSize.width),
            y: min(max(preferredChatOrigin.y, screenFrame.minY), screenFrame.maxY - chatSize.height)
        )
        windowSet.chatWindow.setFrameOrigin(syncedChatOrigin)

        // `addChildWindow` *should* keep the emotion bubble glued to the
        // pet, but `setFrameOrigin` with a detached delegate can race in
        // edge cases. Re-anchoring is cheap and guarantees the bubble
        // stays centred above the pet.
        petEmotionBubble?.repositionAbovePet()
    }

    /// N3.3 — Pet 形象 SignatureAction 路由。Shell 层在事件源 (reply 完成 /
    /// LLM 错误 / 召唤 / 等) 触发后调用此方法,内部:
    /// 1. 先用 `renderer.supportedSignatures.contains(action)` 校验过滤
    /// 2. 通过 → 调 `renderer.trigger(action)` 让 renderer 自己决定动画
    /// 3. 不通过(default 空集) → 静默忽略,不报错
    ///
    /// Orb 当前不响应任何 SignatureAction(`supportedSignatures` 默认空),
    /// 这条通道留给 N3.5 史莱姆 / 后续角色化形象用。Shell 层 ambient 反馈
    /// (例如 `PetChatAnimator.triggerJump` layer 跳跃) 跟 SignatureAction
    /// 正交,即使 Orb 不响应仍会触发 (跟 pet 形象无关的统一动画语言)。
    @MainActor
    public func dispatchSignature(_ action: SignatureAction) {
        guard let renderer = petRenderer else { return }
        guard renderer.supportedSignatures.contains(action) else { return }
        renderer.trigger(action)
    }

    /// N3.4 — 运行时替换 pet 形象 renderer (不重启 app)。
    ///
    /// 流程:
    /// 1. 暂停旧 renderer display link (避免后台继续 GPU work)
    /// 2. 把新 renderer.contentLayer 经 PetLayerHostView 装到 petWindow.contentView, 复用右键菜单 (drag
    ///    handlers 装在 NSWindow level, 不受 contentView 替换影响)
    /// 3. 启动新 renderer display link
    /// 4. 把当前 chat 情绪态 (`previousChatBehaviorState`) 重发给新 renderer,
    ///    让它进入正确情绪 (避免切换后停在默认 .idle)
    /// 5. 老 renderer 引用释放后由 ARC 自动 deinit + 停止 display link
    ///
    /// 传 nil 时回 placeholder (Metal-less 系统也能切到这条 fallback 路径)。
    /// `recommendedSize` 非空时按形象推荐尺寸调 pet 窗(D-2.2c:Live2D 180×240 比 orb 64
    /// 大,不调窗模型渲染偏小);保持底部中心锚定(桌宠常坐在物体上)。
    public func replacePetRenderer(with newRenderer: PetRenderer?, recommendedSize: NSSize? = nil) {
        petRenderer?.pauseDisplayLink()

        // PF6:记下新形象未缩放基准尺寸,按当前 petScale 缩放窗口(自管窗口形象除外,它自管尺寸)。
        basePetWindowSize = recommendedSize ?? NSSize(width: 72, height: 72)
        if newRenderer?.drivesOwnWindowPosition != true {
            resizePetWindow(to: scaledPetWindowSize)
        }

        let inheritedMenu = windowSet.petWindow.contentView?.menu
        if let newRenderer {
            newRenderer.applyScale(petScale)   // 自管窗口形象(Shimeji)据此每帧缩放
            let host = PetLayerHostView(content: newRenderer.contentLayer)
            host.menu = inheritedMenu
            windowSet.petWindow.contentView = host
            newRenderer.resumeDisplayLink()
            // 重发当前情绪态让新 renderer 进入正确状态(切换前 talking → 切完仍 talking)
            if let lastChatState = previousChatBehaviorState {
                newRenderer.updateForState(PetEmotionState.from(lastChatState))
            }
        } else {
            // fallback: 一个空 NSView 占位, drag handlers 仍走 NSWindow 路径
            let placeholder = NSView()
            placeholder.menu = inheritedMenu
            windowSet.petWindow.contentView = placeholder
        }

        petRenderer = newRenderer
    }

    /// PF6:设全局桌宠大小因子(0.5–2.0)。自管窗口形象(Shimeji)经 `applyScale` 下帧自缩放;
    /// host 仲裁形象立即 resize 窗口(基准尺寸×scale,保底部中心锚定)。preview/save 都调此。
    public func setPetScale(_ scale: CGFloat) {
        petScale = scale
        petRenderer?.applyScale(scale)
        if petRenderer?.drivesOwnWindowPosition != true {
            resizePetWindow(to: scaledPetWindowSize)
        }
    }

    /// 当前形象基准尺寸 × petScale。
    private var scaledPetWindowSize: NSSize {
        NSSize(width: basePetWindowSize.width * petScale, height: basePetWindowSize.height * petScale)
    }

    /// 调 pet 窗到目标 content size,保持底部中心不动(锚定地面/物体表面)。
    private func resizePetWindow(to size: NSSize) {
        let win = windowSet.petWindow
        let old = win.frame
        guard size.width > 0, size.height > 0,
              abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        let origin = NSPoint(x: old.midX - size.width / 2, y: old.minY)
        win.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func recordInteractionEvent(_ event: ShellInteractionEvent) {
        interactionEvents.append(event)
        interactionEventSink(event)
    }
}
