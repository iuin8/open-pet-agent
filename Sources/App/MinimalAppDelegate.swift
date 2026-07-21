import AgentSensing
import AppKit
import Context
import Foundation
import Orchestrator
import QuartzCore
import Rendering
import RuntimeBridge
import Shell
import Shimeji
import AgentMode
import Weather

final class FrameLoopHandle {
    private let cancelHandler: () -> Void
    /// 运行时切 tick 频率(Hz)。idle 省电时降到 6 Hz,active 时 30 Hz。
    /// nil = 不支持动态切(测试 stub 用)。
    let setRateHandler: ((Double) -> Void)?

    init(
        cancelHandler: @escaping () -> Void,
        setRateHandler: ((Double) -> Void)? = nil
    ) {
        self.cancelHandler = cancelHandler
        self.setRateHandler = setRateHandler
    }

    func cancel() {
        cancelHandler()
    }

    /// 动态切 tick 频率。idle = true → 6 Hz 省电; idle = false → 30 Hz 正常。
    /// 借鉴 HermesPet v1.2.10 walkTimer 30→6fps 模式。
    func setRate(_ hz: Double) {
        setRateHandler?(hz)
    }
}

@MainActor
final class MinimalAppDelegate: NSObject, NSApplicationDelegate {
    typealias MakeShellController = @MainActor (WindowGraph, NSRect, ShellInitialState, @escaping DesktopShellController.InteractionEventSink, @escaping ChatShellView.ReplyHandler) -> DesktopShellController
    typealias ShowShellWindows = @MainActor (DesktopShellController) -> Void
    typealias StartFrameLoop = @MainActor (@escaping @MainActor () async -> Void) -> FrameLoopHandle?
    typealias WaitForRuntimeFrame = @MainActor () async -> Void
    typealias CurrentTime = @MainActor () -> TimeInterval
    let rootSystem: AppRootSystem
    let currentScreenFrame: @MainActor () -> NSRect
    /// Injectable display-ID provider for testability. On the live path this
    /// returns the CGDirectDisplayID for each connected NSScreen.
    let currentDisplayIDs: @MainActor () -> [CGDirectDisplayID]
    let currentTime: CurrentTime
    let maxDeltaTime: Double
    let makeShellController: MakeShellController
    let showShellWindows: ShowShellWindows
    let startFrameLoop: StartFrameLoop
    let waitForRuntimeFrame: WaitForRuntimeFrame
    var lastFrameTime: TimeInterval?
    // NOTE: 拆 extension 后 setter 需要跨文件可写, 故去掉 `private(set)`。
    // 类本身是 internal, 跨 module 不可访问, 测试仅 read 这里没有泄漏面。
    var currentRenderState: RenderState
    /// 工作块 A —— 形象无关运动仲裁层。pet 位置的唯一决策出口:每帧消费
    /// orchestrator 的 cursor-follow 候选,按模式(physics/roaming/perched)
    /// 仲裁出最终位置 + 运动态。见 docs/pet-spatial-and-forms-design.md 决策 D2。
    var petMotionController: PetMotionController
    /// 用户最后一次键鼠输入距今秒数源(漫步/爬墙触发阈值)。可注入,测试用
    /// fixture 控制空闲时长。默认走 `CGEventSource`(同 `IdleStateTracker`)。
    let idleSecondsProvider: @MainActor () -> Double

    // MARK: - 生命感 signature 派发(.greet / .signatureIdle,反应路由未来项 B 第 3 刀)
    /// 久闲 ≥ 此秒数 → 派 `.signatureIdle`(招牌闲置:sprite 伸懒腰 / Live2D 动作;Orb no-op 由呼吸兜底)。
    static let signatureIdleThreshold = 45.0
    /// 空闲降回此秒数内视为「回来了」→ 久闲后回归派 `.greet`(打招呼)。
    static let greetReturnThreshold = 2.0
    /// 上一帧用户是否「活跃」(供久闲→回归 边沿派 `.greet`)。
    var petWasActiveForGreet = true
    /// 本次久闲会话是否已派过 `.signatureIdle`(每次久闲只派一次,免逐帧刷屏)。
    var petSignatureIdleFired = false
    /// 工作块 B3 —— pet 淋湿程度(0..1)。每帧按 isRainEnabled 朝目标 lerp,
    /// 转发给 sprite 形象叠蓝色水渍。停雨平滑回落,不硬切。
    var petWetness: Float = 0
    /// P4-B-5:Shimeji 形象激活时,把桌面态翻成 top-origin `BehaviorEnvironment` 喂引擎。
    /// 持 cursor 半衰速度跨帧状态。非 Shimeji 形象时空转(不被调用)。
    let shimejiEnvironmentProvider = DesktopEnvironmentProvider()
    /// Phase 2 多宠同屏:主宠之外的装饰物理伙伴(每只 = DecorativePet 窗口 + 配对 ShimejiPetRenderer)。
    /// 帧循环主宠驱动后顺带 `renderer.advance(env) → pet.setFrame`。见 MinimalAppDelegate+DecorativePets。
    var decorativePets: [(pet: DecorativePet, renderer: ShimejiPetRenderer)] = []
    /// 装饰伙伴 id 集持久化 key(JSON `[String]`,= picker plugin id)。
    static let decorativePetIDsKey = "pet.decorative.ids"
    /// 「自动跟随当前位置」天气开关持久化 key(默认 false → 老用户维持手选城市,零回归)。
    static let autoFollowLocationKey = "weather.autoFollowLocation"
    var runtimeFrameError: Error?
    var frameLoopHandle: FrameLoopHandle?
    // 帧率自适应 + App Nap 抑制(修「盯着看也卡 / 像休眠」):宠物**可见**时锁满 30Hz 顺滑,仅当宠物窗口
    // 被**完全遮挡 / 不可见**时才降到 idle 频率省电(看不到时降频无感)。另持一个活动令牌防 App Nap 把
    // main-queue 帧 timer 合并成卡顿突发。详见 MinimalAppDelegate+PetBehavior.handlePetVisibilityChange。
    var frameRateActivityToken: NSObjectProtocol?
    var petOcclusionObserver: NSObjectProtocol?
    var currentFrameLoopHz = MinimalAppDelegate.frameLoopHz
    var shellInteractionVersion = 0
    var snowFrameSampleCounter: UInt64 = 0
    var isSnowEnabled = false
    /// 雨开关。WeatherStateManager onUpdate 按 condition 路由,跟 isSnowEnabled
    /// 平行 —— 雨可独立于雪存在。RuntimeFrame 用它驱动 FallingSand 的 spawnRain
    /// (雨 = water 粒子,落地成水洼,与雪同一套 FallingSand 引擎)。
    var isRainEnabled = false
    var isRuntimeFrameInFlight = false
    var isLaunchingShell = false
    var shellController: DesktopShellController?
    /// The multi-monitor overlay window registry. Populated in
    /// `applicationDidFinishLaunching` and kept in sync by
    /// `handleScreenConfigurationChange`.
    var overlayRegistry: OverlayWindowRegistry?
    /// Token for the `didChangeScreenParametersNotification` observer so we
    /// can tear it down if needed.
    var screenParametersObserver: NSObjectProtocol?
    /// Token for the `didWakeNotification` observer (sleep/wake insurance).
    var wakeObserver: NSObjectProtocol?
    /// 主动协助 NSWorkspace app 切换 observer token（teardown 时移除，防泄漏）。
    var proactiveAppActivationObserver: NSObjectProtocol?
    /// pet 窗口移动 observer token —— 驱动对话卡片跟随 pet（teardown 时移除）。
    var chatCardPetMoveObserver: NSObjectProtocol?
    var chatBehaviorStateMachine: ChatBehaviorStateMachine?
    var lastChatSequenceID: UInt64 = 0
    /// Task 5 —— agent 活动态防抖器。每次 `handleAgentSensingOutput` 收到稳态跃迁时
    /// 通过此防抖器过滤，防止 transcript-tail 高频轮询引发的弹球现象。
    /// 纯值类型，存在主类（extension 无法持有存储属性）。
    var activityCoalescer = ActivityCoalescer()
    /// Global ⌥Space summon hotkey. Toggles chat bubble visibility from
    /// any focused app (provided Accessibility permission is granted) and
    /// from inside OpenPetAgent itself. Lifetime tied to the delegate.
    var chatHotkey: GlobalChatHotkey?

    /// Task 6 — CoreLocation 包装。懒建:首次访问(设置面板查状态 / 自动定位开启)
    /// 才建 CLLocationManager,避免启动时触发 TCC 拦截。
    lazy var locationAdapter: (any LocationAuthorizing)? = CoreLocationCoordinateAdapter()

    /// A.5.3 phase 2 — Bonded session driver. Owns a `BondedBubbleChain`
    /// anchored to the pet window and translates orchestrator reply / stream
    /// callbacks into "user bubble + assistant bubble" appends. Currently
    /// wired but **not** exposed via UI / hotkey — phase 3 will add a
    /// settings flag to switch the user between Stage (default) and Bonded.
    /// Keeping the session retained means the chain is ready to display the
    /// instant the toggle ships; until then it stays empty.
    var bondedSession: BondedSession?

    /// Task C — Spotlight 风快问浮窗控制器。**替代** 之前的
    /// `BondedActiveInputBubble` 头顶气泡输入路径,把"用户主动 ask AI"的
    /// 入口收敛到屏幕中央上 30% 处 680pt 毛玻璃浮窗。
    ///
    /// 三条召唤路径(⌘⇧Space / ⌥Space / 点击 pet / 灵动岛点击)统一通过此
    /// controller。Lazily 创建,生命周期跟 delegate 绑定。
    ///
    /// 注意 BondedSession 不受影响 — 继续服务 pet 主动智能输出
    /// (idle 短语 / 任务完成反馈 / emotion bubble / 主动建议气泡)。对话卡片走
    /// `replyStream` 通路(**写 ConversationStore + 拼历史上下文**),多轮对话进永久历史。
    var chatCardWindowController: ChatCardWindowController?

    /// 列容器(取代多窗口侧卡:SideCardStack + 3 卡控制器 + beak)。**一个**窗口贴主卡侧,横向平铺 drill-in 列
    /// (访达列视图):点主卡行 → openRoot 根列;列内行 → drillIn 追加列;超屏横向滚动。见 docs/sidecard-column-redesign-design.md。
    let columnContainerWindowController = Shell.ColumnContainerWindowController()

    /// 钉住会话持久化(UserDefaults)—— 会话列表纳入钉住(非活跃也留)。
    let pinnedSessionStore = Shell.PinnedSessionStore()
    /// 「浏览历史」会话 sheet 面板(NSOpenPanel 选目录后弹)。
    var sessionBrowsePanel: NSPanel?
    /// 浏览 sheet 窗口**置顶**态(default off)→ 置顶则点主卡不 dismiss + 窗口层级常驻。
    var browseSheetPinned = false

    /// 开箱 onboarding 推荐卡面板（首启动空库弹一次）。
    var starterOnboardingPanel: NSPanel?
    /// 由 onboarding 推荐卡点击进入的社区桌宠弹窗面板。
    var onboardingCommunityPanel: NSPanel?

    /// S3 Pin 卡片协调器 —— 启动时加载持久化的 pin → 创建 windows,⌘⇧P 触发
    /// 时调用 `add` 钉当前回复。生命周期跟 delegate 绑定。
    var pinCardController: PinCardController?

    /// S3 — ⌘⇧P 全局热键监听。按下时把当前 chain 的 assistant 气泡内容 pin
    /// 到桌面。lazily 在 didFinishLaunching 启动。
    var pinHotkey: PinCurrentReplyHotkey?

    /// C2 — ⌘⇧Space 全局热键监听。按下时读系统选中文本 → 召唤 QuickAsk 浮窗
    /// → 预填文本 (无选中则空召唤, 等同 ⌥Space)。lazily 在 didFinishLaunching
    /// 启动, 跟其他 hotkey 共用同套 NSEvent monitor 路径。
    var quickAskHotkey: QuickAskHotkey?

    /// N1: 灵动岛胶囊控制器。点击胶囊触发 `toggleChatCard`,作为全局 hotkey
    /// 之外的第二条召唤路径。**只在有刘海的主屏 + 用户未关闭灵动岛开关时**
    /// 创建;其他情况 `nil`,避免在无 notch 屏上凭空多一条黑色横条。
    /// didFinishLaunching 时按需 lazy 装配。
    var dynamicIslandController: DynamicIslandController?

    /// S1: 全局光标 X 区域追踪。鼠标左/中/右 → orb 沿 X 方向短暂 squash,
    /// 视觉上像桌宠"扭头看光标方向"。didFinishLaunching 时启动。
    let mouseAreaTracker = MouseAreaTracker()

    /// S1: 系统空闲检测。3 分钟无键鼠输入 → orb panel 微调暗(alphaValue 0.7),
    /// 用户回来恢复 1.0。didFinishLaunching 时启动。
    let idleStateTracker = IdleStateTracker()

    /// S1: pet window 的"清醒态" alpha,sleeping 时降到 sleepingAlpha。
    static let awakeAlpha: CGFloat = 1.0
    static let sleepingAlpha: CGFloat = 0.7

    /// N3.2: UserDefaults 持久化选中的 pet plugin ID(默认 "orb")。
    /// 后续 N3.5 + settings UI 完整 ship 时,SettingsWindowController 加
    /// NSPopUpButton 切换写入此 key。当前阶段只有 Orb 一个 plugin, 此 key
    /// 不变即可。
    public static let petPluginUserDefaultsKey: String = "pet.plugin.id"

    /// N1: UserDefaults 控制灵动岛胶囊开关。默认 `true`,但 effective 状态
    /// 还要叠加"主屏是否有刘海"——无刘海机型即使 key=true 也不创建胶囊
    /// (`DynamicIslandController.mainScreenHasNotch()` 守门)。
    public static let dynamicIslandEnabledKey: String = "dynamic.island.enabled"

    /// N2.3: UserDefaults 控制 Claude Code 工具层开关。默认 `false` (实验
    /// 特性, 用户需显式打开)。开关 = true + CLI 已安装 时, prompt 走
    /// `ClaudeCodeEngine` 子进程而非 LLM HTTP。
    /// **值保留 legacy `tool.mode.enabled`**(符号已改名 agentModeEnabledKey,key 串不改 → 零迁移)。
    /// `nonisolated`:纯 String 常量,任何 actor/线程读 key 均安全(默认会继承 class 的
    /// @MainActor 隔离,但常量无数据竞争,显式放宽供 `replyConfiguration` 等 nonisolated 纯函数复用)。
    nonisolated public static let agentModeEnabledKey: String = "tool.mode.enabled"

    /// Task E: 灵动岛切桌面 / overlay 显隐时是否要 fade 桌宠避免遮挡感
    /// 的闪烁。默认 true(开启)。当前由 settings 写入,实际"切桌面 fade"
    /// 行为由 DesktopShellController 自行查询本 key 实现(follow-up wire 点)。
    public static let islandHidePetOnSwitchKey: String = "island.hidePetOnSwitch"

    /// N2.3: 工具层路由器。`applicationDidFinishLaunching` 按 UserDefaults
    /// 注册 / 不注册 engine —— UI 切换开关后调 `setEngine` 即时生效, 无需
    /// 重启。Orchestrator 通过共享的 `AgentModeRouterHolder` 拿到引用,
    /// `replyStream` 优先路由到这里。
    var agentModeRouter: AgentModeRouter?
    /// P3:前台 project 检测器(前台 app 切换 → cwd → 匹配 project → 自动切)。
    var frontmostProjectDetector: FrontmostProjectDetector?

    /// N2.3: 由 `OpenPetAgentApp.launchReadyApp` 注入的 router holder。延迟到
    /// `applicationDidFinishLaunching` 才真正 `set(router)`, 因为那时才
    /// 知道 UserDefaults 里 toggle 的当前值 / engine kind。
    let agentModeRouterHolder: AgentModeRouterHolder?

    /// Phase 0: 天气数据层。`applicationDidFinishLaunching` 末段创建 +
    /// start Timer (15min refresh), onUpdate 闭包把 wind/temp 写进
    /// `GPUSnowCoordinator` 的 external 字段 + `pileAmbientTemperature`。
    /// `applicationWillTerminate` 调 stop()。
    var weatherStateManager: WeatherStateManager?

    /// 最近一次 weather snapshot 的人类可读描述,Settings 面板"当前天气"卡片
    /// 显示。WeatherStateManager onUpdate 时更新此值 + 推送到 settings
    /// controller(若存在)。
    var currentWeatherDescription: String = "⏳ 等待首次刷新…"

    /// 最近一次 weather snapshot. 60s timer 在它基础上 reformat description 让
    /// "距今 N 分钟" 字段动起来 (weather 真刷新是 15min 一次, timestamp 不变
    /// 用户感觉静止)。
    var lastWeatherSnapshot: WeatherSnapshot?

    /// 60s 重 format weather description 的定时器 (不调网络, 只更新文案).
    var weatherDescriptionRefreshTimer: Timer?

    /// Settings 强制天气 UserDefaults key("auto" / "sunny" / "cloudy" /
    /// "rainy" / "snowy" / "windy")。auto = 不强制(跟随真实天气)。
    static let forcedWeatherConditionKey = "weatherForcedCondition"

    /// 设置 → 天气 温度模式覆盖档 UserDefaults key（"auto" / "winter" / "spring"
    /// / "sauna"，迁移自旧状态栏菜单「温度模式」）。auto = 跟随天气温度。
    static let thermalOverrideKey = "weatherThermalOverride"

    /// 设置 → 调试 falling-sand 可调参数（JSON 编码的 FallingSandTuning）持久化 key。
    static let fallingSandTuningKey = "fallingSandTuning"
    /// 弹力球抛射调参 UD key（JSON 编码 `BallisticTuning`）。
    static let ballisticTuningKey = "ballisticTuning"

    /// 设置 → 主动协助 设置（JSON 编码的 ProactiveSettings）持久化 key。
    static let proactiveSettingsKey = "proactiveSettings"

    /// PF6 全局桌宠大小因子(0.5–2.0,缺省 1)持久化 key。
    static let petScaleKey = "pet.scale"

    /// 桌宠大小读取(缺省 1,夹进 [0.5, 2.0])。
    var petScaleSetting: Double {
        let raw = userDefaults.object(forKey: Self.petScaleKey) as? Double ?? 1
        return min(max(raw, 0.5), 2.0)
    }

    /// 「防休眠」模式持久化 key(raw = ScreenAwakeMode,缺省 "off")。
    static let screenAwakeModeKey = "screenAwakeMode"

    /// 「防休眠」定时自动关 key(raw = ScreenAwakeAutoOff,缺省 "never")。
    static let screenAwakeAutoOffKey = "screenAwakeAutoOff"

    /// 「低电量模式时自动关闭防休眠」key(Bool,缺省 true)。
    static let screenAwakeDisableOnLowPowerKey = "screenAwakeDisableOnLowPower"

    /// 「上次会话是否处于 lidClosedAwake 且未干净复位」标志(Bool)。启动自愈据此**只复位我们自己设的**
    /// `disablesleep` 残留(崩溃/强退留下),绝不误清用户自己用终端设的 disablesleep。
    static let screenAwakeLidWasActiveKey = "screenAwakeLidWasActive"

    /// 旧布尔 key(单一「保持屏幕常亮」开关),保留用于一次性迁移到 mode。
    static let legacyKeepScreenAwakeKey = "keepScreenAwake"

    /// 「防休眠」编排器 —— 四态模式 + 定时自动关 + 电源安全闸。
    let screenAwakeController = ScreenAwakeController()

    /// 开机自启管理(SMAppService.mainApp)。`status` 是权威源,不另存 UD。
    let launchAtLoginManager: LaunchAtLoginManaging = SMAppServiceLaunchAtLogin()

    /// 「在菜单栏显示图标」开关持久化 key(默认 false → 启动不挂状态项)。
    static let menuBarIconVisibleKey = "menuBarIconVisible"

    /// 当前是否应显示菜单栏图标(缺省 false)。
    func menuBarIconVisibleSetting() -> Bool {
        (userDefaults.object(forKey: Self.menuBarIconVisibleKey) as? Bool) ?? false
    }

    /// 从 UD 读当前防休眠模式 raw,缺失时迁移旧布尔 key(true→displayAwake),否则 off。
    func currentScreenAwakeModeRaw() -> String {
        if let raw = userDefaults.string(forKey: Self.screenAwakeModeKey) {
            return raw
        }
        // 迁移:老版本只有布尔「保持屏幕常亮」→ 映射成 displayAwake 并写入新 key。
        if userDefaults.object(forKey: Self.legacyKeepScreenAwakeKey) != nil {
            let migrated = ScreenAwakeMode.migrating(
                legacyKeepScreenAwake: userDefaults.bool(forKey: Self.legacyKeepScreenAwakeKey)
            )
            userDefaults.set(migrated.rawValue, forKey: Self.screenAwakeModeKey)
            userDefaults.removeObject(forKey: Self.legacyKeepScreenAwakeKey)
            return migrated.rawValue
        }
        return ScreenAwakeMode.off.rawValue
    }

    /// 当前「定时自动关」raw(缺省 never)。
    func currentScreenAwakeAutoOffRaw() -> String {
        userDefaults.string(forKey: Self.screenAwakeAutoOffKey) ?? ScreenAwakeAutoOff.never.rawValue
    }

    /// 当前「低电量自动关」开关(缺省 true)。
    func currentScreenAwakeDisableOnLowPower() -> Bool {
        (userDefaults.object(forKey: Self.screenAwakeDisableOnLowPowerKey) as? Bool) ?? true
    }

    /// 启动应用防休眠:接电源监听 + 自动变更回调 + 自愈残留 + 按 UD 应用模式。
    /// **lidClosedAwake 是会话级特权全局改动 —— 不在启动时静默重新提权**(避免登录弹密码),
    /// 持久化值若是它则降级为 off + 自愈任何残留;用户需要时再手动开。
    func applyScreenAwakeMode() {
        var mode = ScreenAwakeMode(rawValue: currentScreenAwakeModeRaw()) ?? .off
        if mode == .lidClosedAwake {
            mode = .off
            userDefaults.set(ScreenAwakeMode.off.rawValue, forKey: Self.screenAwakeModeKey)
        }
        let autoOff = ScreenAwakeAutoOff(rawValue: currentScreenAwakeAutoOffRaw()) ?? .never
        screenAwakeController.disableOnLowPower = currentScreenAwakeDisableOnLowPower()
        screenAwakeController.onAutoChange = { [weak self] newMode, reason in
            guard let self else { return }
            self.persistScreenAwakeMode(newMode)
            self.settingsWindowController?.updateScreenAwakeMode(newMode.rawValue)
            self.notifyScreenAwakeAutoChange(reason)
        }
        screenAwakeController.startPowerMonitoring()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 启动自愈:仅当「上次是我们开的 lid 且未干净复位」(崩溃残留)才复位,且先解释再提权
            //(避免无故弹密码像钓鱼);绝不误清用户自己用终端设的 disablesleep。
            let weLeftLidOn = self.userDefaults.bool(forKey: Self.screenAwakeLidWasActiveKey)
            if weLeftLidOn, self.screenAwakeController.hasOrphanedSleepResidue() {
                if self.confirmRecoverSleepResidue() {
                    await self.screenAwakeController.selfHeal(intendedMode: .off)
                }
                self.userDefaults.set(false, forKey: Self.screenAwakeLidWasActiveKey)
                if self.screenAwakeController.hasOrphanedSleepResidue() {
                    self.notifyScreenAwakeAutoChange("「合盖防休眠」的系统设置仍未复位 —— 可在终端运行 `sudo pmset -a disablesleep 0`,或到设置→系统→防休眠 开一次再关。")
                }
            }
            _ = await self.screenAwakeController.apply(mode: mode, autoOff: autoOff)
        }
    }

    /// 持久化防休眠模式 + 同步「lid 是否激活」标志(供启动自愈精确判断残留来源)。
    func persistScreenAwakeMode(_ mode: ScreenAwakeMode) {
        userDefaults.set(mode.rawValue, forKey: Self.screenAwakeModeKey)
        userDefaults.set(mode == .lidClosedAwake, forKey: Self.screenAwakeLidWasActiveKey)
    }

    /// 防休眠被安全闸自动关闭时,用 pet 气泡告知用户原因(非侵入)。
    func notifyScreenAwakeAutoChange(_ reason: String) {
        bondedSession?.injectProactiveSuggestion(context: "防休眠", reply: reason) { _ in }
    }

    /// 实验 falling-sand CA 雪路径开关 UserDefaults key（重写中，默认 off）。
    static let fallingSandEnabledKey = "useFallingSandCA"

    /// falling-sand 网格 cell 边长（px）。1px → 最密网格 = 下落最顺（跳变最小），
    /// 代价是 cell 数巨大（全屏~210 万），靠批处理 step + fillTemperature 跳过
    /// 补偿性能（实测 step ~3-4ms，远低于 16ms）。
    static let fallingSandCellSize: Float = 1.0

    /// 天气效果总开关 UserDefaults key（默认 on）。off = 不渲染降水（雪/雨全关），
    /// 仍跟踪天气数据。
    static let weatherEffectsEnabledKey = "weatherEffectsEnabled"

    /// 「跟随光标」开关 UserDefaults key（默认 off —— 追光标有人嫌烦，需主动开）。
    static let followingEnabledKey = "petFollowingEnabled"
    /// 「桌面漫游」开关 UserDefaults key（默认 on —— 自由漫步 + 爬墙是「活的桌宠」基线）。
    static let roamingEnabledKey = "petRoamingEnabled"
    /// 「感知编码会话」开关 UserDefaults key（默认 on —— 只读 tail，零侵入，是头号卖点）。
    static let agentSensingEnabledKey = "agentSensingEnabled"
    /// 「在卡片上回答权限/问题」开关 key（默认 off —— 会改 settings.json + 开端口 + 与其它 hook 工具共存，用户主动开）。
    static let permissionAnsweringEnabledKey = "agentPermissionAnsweringEnabled"
    /// 「交互时冻结 pet」开关 key（默认 on —— 贴 pet 的对话卡片/右键菜单开着 或 鼠标悬停 pet 上时,
    /// pet 停在原地不漫步,免 pet 漫步把这些跟随它的卡片/菜单拖走;不跟随的大设置窗口不冻）。
    static let freezeWhenInteractingEnabledKey = "petFreezeWhenInteracting"

    let menuBarController: MenuBarController
    // 状态项生命周期由 MenuBarController 自管(显隐开关);App 不再单独持 statusItem。
    var isFollowingEnabled = false
    /// 桌面漫游（自主漫步 + 爬墙）开关。默认 on，启动从 UserDefaults 恢复。
    var isRoamingEnabled = true
    /// 「交互时冻结 pet」开关。默认 on，启动从 UserDefaults 恢复。on 时:贴 pet 的对话卡片/右键菜单
    /// 开着 或 鼠标悬停 pet 上 → 帧循环把自主运动(漫步+跟随)当本帧关闭,pet 停在原地。
    var isFreezeWhenInteractingEnabled = true
    /// 天气效果总开关（默认 on；off 时不渲染降水）。
    var weatherEffectsEnabled = true
    /// 最近一次归一化 ambient 温度（0..1），falling-sand 每帧用。
    var fallingSandAmbientTemperature: Float = 0.33
    /// 温度模式覆盖档（设置 → 天气）。`.auto` = 跟随天气；具体档 = 覆盖 ambient。
    var thermalOverride: ThermalOverrideMode = .auto
    /// falling-sand 可调物理参数（设置 → 调试）。启动从 UD 读，改动实时推给 driver。
    var fallingSandTuning = FallingSandTuning()
    /// 主动协助引擎（设置 → 主动协助）。applicationDidFinishLaunching 末段构造。
    var proactiveEngine: ProactiveSuggestionEngine?
    /// 主动协助设置。启动从 UD 读，改动实时推给 engine。
    var proactiveSettings = ProactiveSettings.default
    /// idle 翻转扇出器（并联现有省电逻辑 + 主动引擎）。
    var idleSleepingFanout: IdleSleepingFanout?
    /// 主动引擎 30s tick 计时器（dwell 累积 + 深夜）。
    var proactiveTickTimer: Timer?
    /// 当前是否有主动建议气泡可见（用于 engagement 判定：用户此时召唤 chat = engaged）。
    var proactiveBubbleVisible = false
    /// 感知层:只读 tail 外部 Claude Code / Codex 会话 transcript → 桌宠气泡 + 一次性反应。
    /// applicationDidFinishLaunching 末段(bondedSession 就绪后)构造。
    var agentSensingService: AgentSensingService?
    /// 感知层轮询计时器（~1.5s 扫一次活跃会话文件）。
    var agentSensingTickTimer: Timer?
    /// transcript 目录文件事件 wakeup（只触发现有 poll，timer 仍兜底）。
    var agentTranscriptWakeupWatcher: AgentTranscriptWakeupWatcher?
    /// 上次「在跑什么」气泡时间 —— tool 事件高频,节流到每 ~2.5s 一颗(等你/完成不节流)。
    var agentSensingLastBubbleAt: Date?
    /// P3.8 G3 会话元数据扫描器(标题/分支/消息数;按 mtime 缓存,轮询后 off-main 刷 picker)。
    let agentSessionMetadataScanner = SessionMetadataScanner()
    /// P3.8 G4 已加载过历史的会话 URL(agent→sid→URL)。「加载更早」据此读文件,**不依赖 `recentSessions()`**
    /// —— 会话静默 >120s 会掉出 recentSessions,但 transcript 文件还在 → 仍能往前加载(修上滑/点击卡死)。
    var loadedSessionURLs: [AgentKind: [String: URL]] = [:]
    /// 权限应答本地 hook server(P2:在桌宠卡片上答 Claude 的权限/问题)。toggle 开时起。
    var permissionHookServer: AgentSensing.PermissionHookServer?
    /// pet 旁权限侧卡控制器(待答队列堆叠展示,2026-06-16)。
    var permissionCardController: Shell.PermissionCardWindowController?
    /// pet 旁项目能力管理卡片控制器。独立窗口，不挤占聊天 composer。
    var projectCapabilityCardWindowController: Shell.ProjectCapabilityCardWindowController?
    /// requestId → responder(liveness 轮询用:连接死了把死请求移出队列 + 收起卡)。
    var permissionResponders: [String: any AgentSensing.HookResponder] = [:]
    /// liveness 轮询 timer:连接死(超时/Claude 退出)→ 自动移除死的待答(死卡不杵着可点但无效)。
    var permissionLivenessTimer: Timer?
    /// 最近一次天气驱动的归一化温度。切回 `.auto` 时用它恢复，不必等下次刷新。
    var lastWeatherNormalizedTemp: Float?
    let userDefaults: UserDefaults
    /// ACP 当前会话指针存储(P2;key = engineKind|cwd,transcript 权威在 agent 侧)。
    let acpSessionStore = ACPSessionStore()
    let llmProviderBox: LLMProviderBox
    /// Optional reference to the shared live-context box. When non-nil,
    /// `applicationDidFinishLaunching` wires the petContextProvider into
    /// the box so replies include the companion's current runtime state.
    let liveContextBox: LiveContextBox?
    var settingsWindowController: SettingsWindowController?
    let screenshotService = OverlayScreenshotService()

    /// Perf log for the frame loop tick. Same shape as OrbPerf — log avg
    /// wall-time of advanceRuntimeFrame every ~30 ticks. Off by default;
    /// enable with `PETAGENT_PERF_LOG=1 swift run OpenPetAgent`.
    static var logFramePerf: Bool = ProcessInfo.processInfo.environment["PETAGENT_PERF_LOG"] == "1"
    var framePerfCounter: UInt64 = 0
    var framePerfAccumulatedMs: Double = 0

    init(
        rootSystem: AppRootSystem,
        currentScreenFrame: @escaping @MainActor () -> NSRect = {
            NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        },
        currentDisplayIDs: @escaping @MainActor () -> [CGDirectDisplayID] = {
            NSScreen.screens.compactMap { $0.displayID }
        },
        currentTime: @escaping CurrentTime = { ProcessInfo.processInfo.systemUptime },
        maxDeltaTime: Double = 0.1,
        makeShellController: MakeShellController? = nil,
        menuBarController: MenuBarController? = nil,
        userDefaults: UserDefaults = .standard,
        llmProviderBox: LLMProviderBox = LLMProviderBox(),
        liveContextBox: LiveContextBox? = nil,
        agentModeRouterHolder: AgentModeRouterHolder? = nil,
        startFrameLoop: @escaping StartFrameLoop = { tick in
            MinimalAppDelegate.makeDefaultFrameLoop(tick)
        },
        showShellWindows: @escaping ShowShellWindows = { controller in
            controller.showInitialWindows()
        },
        waitForRuntimeFrame: @escaping WaitForRuntimeFrame = {},
        idleSecondsProvider: @escaping @MainActor () -> Double = {
            let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
            let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            return min(mouse, key)
        }
    ) {
        self.rootSystem = rootSystem
        self.currentScreenFrame = currentScreenFrame
        self.currentDisplayIDs = currentDisplayIDs
        self.currentTime = currentTime
        self.maxDeltaTime = maxDeltaTime
        self.makeShellController = makeShellController ?? { windowGraph, screenFrame, initialState, interactionEventSink, chatReplyHandler in
            DesktopShellController(
                windowGraph: windowGraph,
                screenFrame: screenFrame,
                initialState: initialState,
                interactionEventSink: interactionEventSink,
                chatReplyHandler: chatReplyHandler
            )
        }
        // 启动从 UserDefaults 恢复两个空间行为开关(跟随默认 off / 漫游默认 on)。
        let followingOn = (userDefaults.object(forKey: Self.followingEnabledKey) as? Bool) ?? false
        let roamingOn = (userDefaults.object(forKey: Self.roamingEnabledKey) as? Bool) ?? true
        // 感知/权限应答 启用态在各自 wiring(setupAgentSensing / setupPermissionAnswering)启动时直接读 UD,
        // 不再经 MenuBarController。交互冻结启动态读 UD 喂 App 镜像字段。
        let freezeOn = (userDefaults.object(forKey: Self.freezeWhenInteractingEnabledKey) as? Bool) ?? true
        self.menuBarController = menuBarController
            ?? MenuBarController(
                initialFollowingEnabled: followingOn,
                initialRoamingEnabled: roamingOn
            )
        self.userDefaults = userDefaults
        self.llmProviderBox = llmProviderBox
        self.liveContextBox = liveContextBox
        self.agentModeRouterHolder = agentModeRouterHolder
        self.showShellWindows = showShellWindows
        self.startFrameLoop = startFrameLoop
        self.waitForRuntimeFrame = waitForRuntimeFrame
        self.currentRenderState = rootSystem.companionBootstrap.initialRenderState
        self.idleSecondsProvider = idleSecondsProvider
        // 位置无状态 —— 每帧由 currentRenderState 传权威 previousPosition,免 staleness。
        self.petMotionController = PetMotionController()
        self.lastFrameTime = currentTime()
        self.isFollowingEnabled = self.menuBarController.isFollowingEnabled
        self.isRoamingEnabled = self.menuBarController.isRoamingEnabled
        self.isFreezeWhenInteractingEnabled = freezeOn
        super.init()
        // 「跟随」对程序化形象(Orb/Slime)生效;「漫游」更严:仅会走会爬的形象(Slime ✅ / Orb ❌ 纯物理)。
        // pull 式闭包,菜单每次打开读当前 renderer,换形象后自动反映、不会 stale。
        self.menuBarController.isMotionApplicable = { [weak self] in
            self?.shellController?.petRenderer?.driveModel.supportsHostDrivenMotion ?? true
        }
        self.menuBarController.isRoamingApplicable = { [weak self] in
            self?.shellController?.petRenderer?.supportsAutonomousRoaming ?? false
        }
        self.menuBarController.onToggleFollowing = { [weak self] enabled in
            guard let self else { return }
            self.isFollowingEnabled = enabled
            self.userDefaults.set(enabled, forKey: Self.followingEnabledKey)
            self.syncSpatialBehaviorAcrossSurfaces()
        }
        self.menuBarController.onToggleRoaming = { [weak self] enabled in
            guard let self else { return }
            self.isRoamingEnabled = enabled
            self.userDefaults.set(enabled, forKey: Self.roamingEnabledKey)
            self.syncSpatialBehaviorAcrossSurfaces()
        }
        // 感知/权限应答/交互冻结 已迁到 设置 → 系统 →「感知与交互」,onSave 回调见 buildSettingsController。
        // 「温度模式」已迁移到 设置 → 天气 tab（applyThermalOverride 即时生效），
        // 不再走状态栏菜单。
        self.menuBarController.onSettings = { [weak self] in
            self?.showSettingsWindow()
        }
        self.menuBarController.onShareScreenshot = { [weak self] in
            self?.shareOverlayScreenshot()
        }
        // 菜单批 A: 菜单栏"打开聊天浮窗 ⌘⇧Space"直达 QuickAsk, 跟 ⌘⇧Space
        // 全局热键 + pet 右键菜单 + 灵动岛 tap 是同一个 toggle 入口。
        self.menuBarController.onChat = { [weak self] in
            self?.chatCardWindowController?.toggle()
        }
        // 菜单批 B: 菜单栏「天气」submenu 天气模式单选 —— 统一走 `selectWeatherMode`
        // (off=关效果 / 其余=开效果+强制天气),跟 pet 右键 / 设置面板同一执行路径。
        self.menuBarController.onSelectForcedCondition = { [weak self] raw in
            self?.selectWeatherMode(raw)
        }

        // 天气效果总开关默认 on:UD 缺省 = on,仅当显式存过 false 才关。
        let weatherEffectsOn = (userDefaults.object(forKey: Self.weatherEffectsEnabledKey) as? Bool) ?? true
        self.weatherEffectsEnabled = weatherEffectsOn
        // 启动时把当前天气模式(off / 强制条件)同步到菜单栏 submenu check state。
        self.menuBarController.syncForcedConditionState(self.currentWeatherModeRaw)

        // 清场：立即清除积雪（falling-sand 网格清空，不改天气模式）。
        self.menuBarController.onClearWeather = { [weak self] in
            self?.shellController?.clearFallingSand()
        }
    }

    /// 统一天气模式选择(菜单栏 / pet 右键 / 设置面板共用)。
    /// `raw == "off"` → 关闭天气效果(清场 + 干净桌面);其余 → 开启效果 + 强制对应天气
    /// ("auto" = 跟随真实)。on/off 与「哪种天气」合一,不存在「关了又选下雪」的无效状态。
    /// `persist` = 是否写 UD(菜单即时持久;设置面板 preview 传 false,保存时再持久)。
    func selectWeatherMode(_ raw: String, persist: Bool = true) {
        if raw == "off" {
            weatherEffectsEnabled = false
            if persist { userDefaults.set(false, forKey: Self.weatherEffectsEnabledKey) }
            applyPrecipitation(condition: lastWeatherSnapshot?.condition)  // enabled=false → 降水全关
            shellController?.clearFallingSand()
        } else {
            weatherEffectsEnabled = true
            if persist {
                userDefaults.set(true, forKey: Self.weatherEffectsEnabledKey)
                userDefaults.set(raw, forKey: Self.forcedWeatherConditionKey)
            }
            // updateForcedCondition 同步 re-emit snapshot → onUpdate → applyPrecipitation
            // (此时 weatherEffectsEnabled 已置 true,降水按新条件起)。
            weatherStateManager?.updateForcedCondition(raw == "auto" ? nil : WeatherConditionKind(rawValue: raw))
        }
        syncWeatherModeAcrossSurfaces()
    }

    /// 当前天气模式 raw:关效果 → "off";否则 → 强制条件 raw(默认 "auto")。
    var currentWeatherModeRaw: String {
        weatherEffectsEnabled ? (userDefaults.string(forKey: Self.forcedWeatherConditionKey) ?? "auto") : "off"
    }

    /// 把当前天气模式同步到所有有该单选的 surface(菜单栏 + pet 右键),check state 一致。
    func syncWeatherModeAcrossSurfaces() {
        let raw = currentWeatherModeRaw
        menuBarController.syncForcedConditionState(raw)
        shellController?.syncForcedConditionState(raw)
    }

    /// 把跟随 / 漫游两个空间行为开关的状态同步到所有入口(菜单栏 / pet 右键 / 设置面板),
    /// 任一入口改动后保持三处勾选一致(与 `syncWeatherModeAcrossSurfaces` 同模式)。
    func syncSpatialBehaviorAcrossSurfaces() {
        menuBarController.syncFollowingState(isFollowingEnabled)
        menuBarController.syncRoamingState(isRoamingEnabled)
        shellController?.syncSpatialBehavior(following: isFollowingEnabled, roaming: isRoamingEnabled)
    }

    var launchedShellController: DesktopShellController? {
        shellController
    }

    /// Test seam: overwrite the current pet position in `currentRenderState`
    /// so unit tests can simulate where the pet is without driving a full
    /// runtime tick. Only call from test targets.
    func setPetPositionForTest(x: Double, y: Double) {
        currentRenderState = RenderState(
            petPositionX: x,
            petPositionY: y,
            petRotation: currentRenderState.petRotation,
            particleCount: currentRenderState.particleCount,
            particles: currentRenderState.particles,
            contactCount: currentRenderState.contactCount,
            isSnowEnabled: currentRenderState.isSnowEnabled
        )
    }

    /// Frame loop tick rate (Hz). 30 Hz balances physics + companion responsiveness
    /// with main-thread budget: at 60 Hz the DispatchSource timer + per-tick
    /// `Task @MainActor` hop competed with the Pet Orb's own 60 Hz CVDisplayLink
    /// for main-actor time, producing visible app-wide jank. 30 Hz cuts the
    /// per-second main-thread tick load in half with no perceptible loss in
    /// pet drag latency or snow physics smoothness (Rust physics dt simply
    /// becomes 33 ms instead of 16 ms — still well within stable-step territory
    /// for the 2D MPM substepper).
    nonisolated static let frameLoopHz: Double = 30.0

    /// Idle 省电 tick 频率(Hz)。用户 3 分钟无键鼠输入 → IdleStateTracker 触
    /// 发 onSleepingChanged(true) → 切到此频率,CPU 占用 ~ 30Hz/6Hz = 5x 下降。
    /// 物理 dt 跳到 166ms 仍然稳定(MPM substepper 内部 substep,外层 dt 不
    /// 影响 simulation 稳定性,只影响"更新频率")。借鉴 HermesPet v1.2.10
    /// walkTimer 30→6fps 同款思路。
    nonisolated static let idleFrameLoopHz: Double = 6.0

    /// 可见但**静止**(无任何运动/物理驱动:雪/雨/跟随/漫游/拖拽/淋湿淡出/Shimeji 引擎/装饰宠)时的
    /// advanceRuntimeFrame 频率。静止时 pose 恒定 → 降频肉眼无差,省窗口枚举 + orchestrator 开销。
    /// **不踩 §6.1 的坑**:那是「输入空闲」降频(盯着看的动宠会卡);本信号是「无运动」(pet 本就不动)。
    /// 自纠正:每 tick `updateFrameRate()` 重算,任一驱动一活即升回 30Hz(≤~100ms 延迟,肉眼无感)。
    /// 取 10(非 6)留余量:万一漏判某运动源,最坏是 10Hz 轻微 choppy,不是 6Hz 明显卡。
    nonisolated static let visibleIdleFrameLoopHz: Double = 10.0

    static func makeDefaultFrameLoop(
        _ tick: @escaping @MainActor () async -> Void,
        makeTimer: () -> DispatchSourceTimer = {
            DispatchSource.makeTimerSource(queue: .main)
        }
    ) -> FrameLoopHandle {
        let timer = makeTimer()
        timer.schedule(deadline: .now(), repeating: 1.0 / frameLoopHz)
        timer.setEventHandler {
            Task { @MainActor in
                await tick()
            }
        }
        timer.resume()
        return FrameLoopHandle(
            cancelHandler: { timer.cancel() },
            setRateHandler: { newHz in
                // schedule(deadline:repeating:) 可重复调用, 自动 reschedule。
                // deadline: .now() 让新频率立刻生效。
                timer.schedule(deadline: .now(), repeating: 1.0 / max(newHz, 0.1))
            }
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard notification.name == NSApplication.didFinishLaunchingNotification else {
            return
        }

        guard shellController == nil, isLaunchingShell == false else {
            return
        }

        isLaunchingShell = true

        // M.1 — Multi-monitor overlay registry + screen/wake observers.
        let screenFrame = setupOverlayRegistry()

        // N2.3 / N2.4 — Tool mode router (UserDefaults-driven engine).
        setupAgentModeRouter()

        // P3 — 前台 app 切换 → 检测 cwd → 自动切 project(didActivateApplication notification)。
        setupFrontmostProjectDetector()

        // Task B — OpenClaw local gateway probe + auto-launch (best-effort).
        setupOpenClawBootstrap()

        // 「防休眠」—— 按 UD 当前值应用(缺省 off;迁移旧布尔 key)。
        applyScreenAwakeMode()

        // A.3.2 — Chat behavior state machine + shell controller + pet plugin.
        let (controller, wrappedReplyHandler) = setupShellAndStateMachine(
            screenFrame: screenFrame
        )

        // A.5.3 phase 2 — Bonded session + ChatShellView streaming wires.
        setupBondedSession(controller: controller, replyHandler: wrappedReplyHandler)

        showShellWindows(controller)

        // S3 — Pin cards + ⌘⇧P global hotkey.
        setupPinCard()

        // Task C / ⌥Space / ⌘⇧Space / pet-tap — QuickAsk panel + summon hotkeys.
        setupChatCardAndHotkeys(controller: controller)

        // N1 — Dynamic Island capsule + active-space fade observer.
        setupDynamicIsland()

        // Status bar + falling-sand enable + frame loop + live-context provider.
        setupRuntimeAndStatusBar(controller: controller)

        // Phase 0: 天气数据层。每帧把风/温度 wire 进 falling-sand driver。
        setupWeatherStateManager()

        // 阶段 5 — 从 UserDefaults 读持久化的主动协助设置（缺失回落工厂默认）。
        // 必须在 setupBondedSession 之后调（依赖 bondedSession 注入气泡）。
        proactiveSettings = MinimalAppDelegate.loadProactiveSettings(from: userDefaults)
        setupProactiveEngine()

        // 感知层 —— 只读 tail 外部 Claude Code / Codex 会话,桌宠实时反应。
        // 在 setupProactiveEngine 之后(同样依赖 bondedSession 注入气泡)。
        setupAgentSensing()

        // P2 权限应答(默认关,用户菜单主动开)—— 起 hook server + 装 http hook。
        setupPermissionAnswering()

        // Task 5: 开箱 onboarding —— discover 已在 setupShellAndStateMachine 内跑完，
        // 社区库是否空在此时可准确判断。空库 + 未 dismissed → 延迟 1s 弹推荐卡。
        maybeShowStarterOnboarding()

        // 首启动一次性:辅助功能未授权 → 主动弹一次系统授权框。辅助功能是核心(全局热键 + 漫步/爬墙),
        // 缺了体验断裂却无声。`AXIsProcessTrustedWithOptions` 天然自限:只对「从未决定」弹,已在系统设置
        // 列表(授权/拒绝/重置)的不再弹,不打扰。屏幕录制(nice-to-have)/位置(opt-in)不在此主动申请。
        maybePromptAccessibilityOnLaunch()

        isLaunchingShell = false
    }

    /// 首启动检测辅助功能授权:未授权则弹一次系统授权框(可注入 bridge 供测试)。
    @MainActor
    func maybePromptAccessibilityOnLaunch(bridge: AccessibilityBridge = AccessibilityBridge()) {
        guard !bridge.isProcessTrusted else { return }
        bridge.requestPermissionsPrompt()
    }

    static func initialSnowParticles(in screenFrame: NSRect) -> [CGPoint] {
        (0..<12).map { index in
            CGPoint(
                x: CGFloat(index * 73).truncatingRemainder(dividingBy: max(1, screenFrame.width)),
                y: max(0, screenFrame.height - CGFloat(index % 4) * 46)
            )
        }
    }

    func recordShellInteraction(_ event: ShellInteractionEvent) {
        switch event {
        case let .petDrag(positionX, positionY), let .petRelease(positionX, positionY):
            shellInteractionVersion += 1
            currentRenderState = RenderState(
                petPositionX: positionX,
                petPositionY: positionY,
                petRotation: currentRenderState.petRotation,
                particleCount: currentRenderState.particleCount,
                particles: currentRenderState.particles,
                contactCount: currentRenderState.contactCount,
                isSnowEnabled: currentRenderState.isSnowEnabled
            )
        case .snowToggleRequested:
            isSnowEnabled.toggle()
            SnowDiagnostics.log("toggle enabled=\(isSnowEnabled) currentParticles=\(currentRenderState.particleCount)")
            currentRenderState = RenderState(
                petPositionX: currentRenderState.petPositionX,
                petPositionY: currentRenderState.petPositionY,
                petRotation: currentRenderState.petRotation,
                particleCount: currentRenderState.particleCount,
                particles: currentRenderState.particles,
                contactCount: currentRenderState.contactCount,
                isSnowEnabled: isSnowEnabled
            )
            shellController?.syncSnowPlaceholder(
                isEnabled: isSnowEnabled,
                particles: isSnowEnabled ? Self.initialSnowParticles(in: currentScreenFrame()) : []
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        frameLoopHandle?.cancel()
        if let token = frameRateActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            frameRateActivityToken = nil
        }
        if let token = petOcclusionObserver {
            NotificationCenter.default.removeObserver(token)
            petOcclusionObserver = nil
        }
        weatherStateManager?.stop()
        // 防休眠:停电源监听。lidClosedAwake 的 disablesleep 复位无法在退出时可靠弹密码,
        // 故退出即复位是 best-effort —— 铁保证是「下次启动 selfHeal 强制复位残留」(见 applyScreenAwakeMode)。
        screenAwakeController.stopPowerMonitoring()
        // 主动协助引擎清理：停 30s tick timer + 移除 app 切换 observer（防泄漏）。
        // observer 注册在 NSWorkspace.shared.notificationCenter，移除必须用同一个 center。
        proactiveTickTimer?.invalidate()
        if let token = proactiveAppActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        // 感知层轮询计时器 / 文件事件 wakeup 收口。
        agentSensingTickTimer?.invalidate()
        agentTranscriptWakeupWatcher?.stop()
        // 权限应答 server 收口(留 hook 在 settings.json:server 关时 POST 连接被拒 → 快速失败
        // 走正常权限流,不阻塞;下次启动重装刷端口。卸 hook 只在用户菜单主动关时做)。
        permissionHookServer?.stop()
        if let token = chatCardPetMoveObserver {
            NotificationCenter.default.removeObserver(token)
        }
        SnowDiagnostics.log("willTerminate name=\(notification.name.rawValue)")
        // falling-sand 积雪不做跨重启持久化（几秒即重新积起来）。
        // 工具层 spawn 的子进程 (claude -p 等) 统一 SIGTERM 收口,避免变孤儿
        // 进程在后台烧 token。fire-and-forget,不阻塞 quit。
        Task {
            await SubprocessRegistry.shared.terminateAll()
        }
    }
}
