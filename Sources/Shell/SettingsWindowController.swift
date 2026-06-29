import AppKit
import Orchestrator
import Rendering
import RuntimeBridge
import SwiftUI

/// Manages the OpenPetAgent Settings window, which lets the user configure the
/// LLM provider (OpenAI-compatible or Anthropic), API key, base URL, model,
/// pet plugin, 灵动岛, 工具模式 engine, OpenClaw daemon 自动启动等。
///
/// **Task: SwiftUI 重写**:原 AppKit `NSStackView + NSBox` layout 二次崩(文字
/// 堆叠 / alignment 失效),完整切到 SwiftUI Form/GroupBox 风格,参考
/// HermesPet (https://github.com/basionwang-bot/HermesPet) 的 sidebar + detail 模式。
///
/// **公共 API 100% 向后兼容**:所有 `onSave*` callback、test-readable 属性
/// (`currentFieldText` / `apiKeyLabelText` / `selectedProviderIndex` 等) 都
/// 转发到内部 `SettingsViewModel`,callsite (MinimalAppDelegate+Settings.swift)
/// + 现有测试无需修改。
///
/// 用法示例:
/// ```swift
/// let settings = SettingsWindowController(
///     selectedProvider: .openAICompatible,
///     existingAPIKey: currentKey,
///     existingBaseURL: currentBaseURL,
///     existingModel: currentModel,
///     openClawStatusDescription: "⚪ 未启动"
/// )
/// settings.onSaveAll = { key, baseURL, model in /* persist */ }
/// settings.show()
/// // 异步拿到 OpenClaw status 后:
/// settings.updateOpenClawStatusDescription("✅ 已就绪 baseURL=http://localhost:18789")
/// ```
@MainActor
public final class SettingsWindowController {
    // MARK: - Public interface — Save callbacks (向后兼容,不动)

    /// Called when the user taps Save.
    /// - Parameters:
    ///   - provider: The selected provider raw string ("openAICompatible" or "anthropic").
    ///   - apiKey: Trimmed API key (empty means "use default" or no key).
    ///   - baseURL: Trimmed base URL (empty means "use default"; ignored for Anthropic).
    ///   - model: Trimmed model name (empty means "use default").
    public var onSaveProvider: @MainActor (String, String, String, String) -> Void = { _, _, _, _ in }

    /// Legacy three-field save closure kept for backward compatibility.
    /// Fires with key, baseURL, model. New code should use `onSaveProvider`.
    public var onSaveAll: @MainActor (String, String, String) -> Void = { _, _, _ in }

    /// Legacy single-field save closure kept for backward compatibility.
    public var onSave: @MainActor (String) -> Void = { _ in }

    /// N3.6: Called when the user taps Save with the chosen pet plugin id.
    public var onSavePlugin: @MainActor (String) -> Void = { _ in }

    /// N1.3: Called when the user taps Save with the chosen 灵动岛 toggle state。
    public var onSaveIslandEnabled: @MainActor (Bool) -> Void = { _ in }

    /// N2.3: Called when the user taps Save with the chosen 工具模式 toggle state。
    public var onSaveToolModeEnabled: @MainActor (Bool) -> Void = { _ in }

    /// Task E: Called when the user taps Save with the chosen 工具 engine kind raw string。
    public var onSaveToolEngineKind: @MainActor (String) -> Void = { _ in }

    /// 开机自启 toggle 改动时触发(modeless 即时提交)。
    public var onSaveLaunchAtLogin: @MainActor (Bool) -> Void = { _ in }

    /// 「在菜单栏显示图标」toggle 改动时触发(modeless 即时提交)。
    public var onSaveMenuBarIconVisible: @MainActor (Bool) -> Void = { _ in }

    /// 「感知编码会话」toggle 改动时触发(从菜单迁入)。
    public var onSaveAgentSensing: @MainActor (Bool) -> Void = { _ in }
    /// 「在卡片上回答权限/问题」toggle 改动时触发(从菜单迁入)。
    public var onSavePermissionAnswering: @MainActor (Bool) -> Void = { _ in }
    /// 「交互时冻结桌宠」toggle 改动时触发(从菜单迁入)。
    public var onSaveFreezeWhenInteracting: @MainActor (Bool) -> Void = { _ in }

    /// Task E: Called when the user taps Save with the OpenClaw "启动时自动探测 daemon" toggle state。
    public var onSaveOpenClawAutoStart: @MainActor (Bool) -> Void = { _ in }

    /// Task E: Called when the user taps Save with "允许 OpenPetAgent 自动 enable chatCompletions endpoint" toggle state。
    public var onSaveOpenClawAllowEndpointEnable: @MainActor (Bool) -> Void = { _ in }

    /// Task E: Called when the user taps Save with "灵动岛切桌面时隐藏桌宠" toggle state。
    public var onSaveIslandHidePetOnSwitch: @MainActor (Bool) -> Void = { _ in }

    /// 「防休眠」模式 Picker 改动时触发(modeless 即时提交,raw = ScreenAwakeMode)。
    public var onSaveScreenAwakeMode: @MainActor (String) -> Void = { _ in }

    /// 「防休眠」定时自动关 Picker 改动时触发(raw = ScreenAwakeAutoOff)。
    public var onSaveScreenAwakeAutoOff: @MainActor (String) -> Void = { _ in }

    /// 「低电量自动关」开关改动时触发。
    public var onSaveScreenAwakeDisableOnLowPower: @MainActor (Bool) -> Void = { _ in }

    /// Fires with city id (CityCatalog.userDefaultsKey) when user saves.
    public var onSaveCity: @MainActor (String) -> Void = { _ in }

    /// Fires with forced condition raw ("auto" / "sunny" / "cloudy" / "rainy"
    /// / "snowy" / "windy") when user saves.
    public var onSaveForcedCondition: @MainActor (String) -> Void = { _ in }

    /// Fires with 温度档 raw ("auto" / "winter" / "spring" / "sauna") when user saves。
    public var onSaveThermalOverride: @MainActor (String) -> Void = { _ in }

    /// 调试调参 preview（拖滑块即时生效，**不写 UD**）。
    public var onFallingSandTuningPreview: @MainActor (FallingSandTuning) -> Void = { _ in }
    /// 调试调参 save（写 UD + 即时生效）。
    public var onSaveFallingSandTuning: @MainActor (FallingSandTuning) -> Void = { _ in }
    /// 弹力球抛射调参 preview（拖滑块即时生效 + 持久化）。
    public var onBallisticTuningPreview: @MainActor (BallisticTuning) -> Void = { _ in }

    /// 主动协助 preview（改设置立刻热更新引擎，**不写 UD**）。
    public var onProactiveSettingsPreview: @MainActor (ProactiveSettings) -> Void = { _ in }
    /// 主动协助 save（写 UD + 即时生效）。
    public var onSaveProactiveSettings: @MainActor (ProactiveSettings) -> Void = { _ in }

    /// PF6 桌宠大小 preview（拖滑杆立刻缩放桌宠，**不写 UD**）。
    public var onPetScalePreview: @MainActor (Double) -> Void = { _ in }
    /// PF6 桌宠大小 save（写 UD + 即时生效）。
    public var onSavePetScale: @MainActor (Double) -> Void = { _ in }

    /// Phase 2 多宠同屏:库 sheet 勾/取消「同屏」即时触发(modeless,无 save/回滚)。
    /// `(id, on)` —— on=true 上屏一只装饰伙伴,false 下屏。App 侧写 UD `pet.decorative.ids` + spawn/despawn。
    public var onToggleDecorativePet: @MainActor (String, Bool) -> Void = { _, _ in }

    /// Phase 2 S5 整包同屏:包头「全部同屏」一次批量上/下屏整包成员。`(ids, on)` —— App 侧单次批量
    /// 写 UD + spawn/despawn(免逐只 N 次 sync)。
    public var onToggleDecorativePack: @MainActor ([String], Bool) -> Void = { _, _ in }

    /// Preview callback — Picker change 立刻拉新天气数据看效果, **不写 UD**。
    /// MinimalAppDelegate+Settings wire: 只调 weatherStateManager.updateLocation
    /// / updateForcedCondition, 不持久化。Cancel 用同款 callback 调原 city
    /// 回滚到原数据。
    public var onCityPreview: @MainActor (String) -> Void = { _ in }
    public var onForcedConditionPreview: @MainActor (String) -> Void = { _ in }
    /// Preview callback — 温度档 Picker change 立刻覆盖 ambient 看效果，**不写 UD**。
    public var onThermalOverridePreview: @MainActor (String) -> Void = { _ in }

    /// 自动跟随位置开关即时提交回调 — 由 App 注入(写 UD + 切坐标源)。
    public var onCommitAutoFollowLocation: @MainActor (Bool) -> Void = { _ in }

    // MARK: - 系统权限回调（Task 4: App 层注入 probe 真实现）

    /// 点「申请/打开系统设置」时由 App 注入(probe.request)。
    public var onRequestPermission: (SystemPermission) -> Void = { _ in } {
        didSet { viewModel.onRequestPermission = onRequestPermission }
    }

    /// 设置窗口变为 key / onAppear 时由 App 注入(刷新四态)。
    public var onRefreshPermissions: () -> Void = {} {
        didSet { viewModel.onRefreshPermissions = onRefreshPermissions }
    }

    // MARK: - App 内部访问（供 App 模块 onboarding 复用同一 SettingsViewModel 实例）

    /// 供 App 模块的 onboarding 创建 CommunityPetsSheet，内部注入同一 SettingsViewModel 实例。
    /// SettingsViewModel 是 Shell-internal，由此工厂方法封装避免跨模块暴露。
    public func makeCommunityPetsSheet(
        initialTab: CommunityTab = .codex,
        onClose: (() -> Void)? = nil,
        onInstalled: @escaping @MainActor () -> Void
    ) -> CommunityPetsSheet {
        CommunityPetsSheet(initialTab: initialTab, viewModel: viewModel, onClose: onClose, onInstalled: onInstalled)
    }

    /// 供 App 模块的 onboarding 触发宠物列表热刷新（等同 PetLibraryView 的 rebuildPetList 调用）。
    public func rebuildPetListForOnboarding() {
        viewModel.rebuildPetList()
    }

    // MARK: - Test-readable properties (转发到 viewModel)

    /// The current text in the API key field (trimmed). Used by tests.
    public var currentFieldText: String { viewModel.apiKey }

    /// The current text in the Base URL field (trimmed). Used by tests.
    public var currentBaseURLText: String { viewModel.baseURL }

    /// The current text in the Model field (trimmed). Used by tests.
    public var currentModelText: String { viewModel.model }

    /// The label text for the API key row. Reflects the selected provider.
    public var apiKeyLabelText: String { viewModel.apiKeyLabel }

    /// Whether the Base URL field is visible. SwiftUI 版始终可见(Anthropic
    /// 也支持自定义 baseURL,跟 AppKit 版的最新行为一致)。
    public var isBaseURLFieldVisible: Bool { true }

    /// Placeholder string shown in the Base URL field.
    public var baseURLFieldPlaceholder: String { viewModel.baseURLPlaceholder }

    /// Placeholder string shown in the Model field.
    public var modelFieldPlaceholder: String { viewModel.modelPlaceholder }

    /// Index of the selected provider in the picker(由 `soulBackends` 顺序决定,
    /// 默认 0=openAICompatible / 1=anthropic / 2=openclaw)。
    public var selectedProviderIndex: Int { viewModel.selectedProviderIndex }

    /// 当前 picker 列出的后端数量(测试用:验证 3 个内置后端全列出)。
    public var soulBackendCount: Int { viewModel.soulBackends.count }

    /// 当前选中后端是否自动管理(openclaw)→ 隐藏手填字段。
    public var isSelectedBackendManaged: Bool { viewModel.selectedBackendManaged }

    /// 自动管理后端选中时显示的说明文案(测试用)。
    public var selectedBackendManagedNote: String { viewModel.selectedBackendManagedNote }

    /// The id of the currently selected pet plugin.
    public var selectedPetPluginID: String { viewModel.selectedPetPluginID }

    /// N1.3: 当前灵动岛 toggle 是否被勾选。
    public var isIslandToggleOn: Bool { viewModel.effectiveIslandOn }

    /// N2.3: 当前 Tool Mode toggle 是否被勾选。
    public var isToolModeToggleOn: Bool { viewModel.toolModeEnabled }

    /// N1.3: 灵动岛 toggle 是否可点击。
    public var isIslandToggleEnabled: Bool { viewModel.notchAvailable }

    /// N1.3: 灵动岛 toggle 当前显示的文字。
    public var islandToggleTitle: String { viewModel.islandToggleTitle }

    /// Task E: 当前 OpenClaw status 文案。
    public var openClawStatusText: String { viewModel.openClawStatusDescription }

    /// Task E: 当前选中的 tool engine kind raw string。
    public var selectedToolEngineKind: String { viewModel.toolEngineKind }

    /// 当前 "开机自启" toggle 是否勾选。
    public var isLaunchAtLoginOn: Bool { viewModel.launchAtLogin }

    /// 当前 "在菜单栏显示图标" toggle 是否勾选。
    public var isMenuBarIconVisibleOn: Bool { viewModel.menuBarIconVisible }

    /// 当前 "感知编码会话" / "权限应答" / "交互冻结" toggle 状态(测试用)。
    public var isAgentSensingOn: Bool { viewModel.agentSensingEnabled }
    public var isPermissionAnsweringOn: Bool { viewModel.permissionAnsweringEnabled }
    public var isFreezeWhenInteractingOn: Bool { viewModel.freezeWhenInteracting }

    /// App 用:把开机自启 toggle 程序化设到真实状态(注册失败回退用)。
    public func updateLaunchAtLogin(_ on: Bool) {
        guard viewModel.launchAtLogin != on else { return }
        viewModel.launchAtLogin = on
    }

    /// Task E: 当前 OpenClaw 自动启动 toggle 是否勾选。
    public var isOpenClawAutoStartOn: Bool { viewModel.openClawAutoStart }

    /// Task E: 当前 "允许自动 enable chatCompletions" toggle 是否勾选。
    public var isOpenClawAllowEndpointEnableOn: Bool { viewModel.openClawAllowEndpointEnable }

    /// Task E: 当前 "灵动岛切桌面隐藏桌宠" toggle 是否勾选。
    public var isIslandHidePetOnSwitchOn: Bool { viewModel.islandHidePetOnSwitch }

    /// 当前 "防休眠" 模式 raw("off" / "displayAwake" / "systemAwake" / "lidClosedAwake")。
    public var selectedScreenAwakeModeRaw: String { viewModel.screenAwakeModeRaw }

    /// 当前 "防休眠" 定时自动关 raw。
    public var selectedScreenAwakeAutoOffRaw: String { viewModel.screenAwakeAutoOffRaw }

    /// 当前 "低电量自动关" 开关。
    public var isScreenAwakeDisableOnLowPowerOn: Bool { viewModel.screenAwakeDisableOnLowPower }

    /// App 用:把模式 Picker 程序化设到某值(安全闸自动关 / 提权取消回退)。
    /// 防回环靠 App 层 `onSaveScreenAwakeMode` 的幂等 guard(raw == 当前真实 mode → no-op),
    /// 不依赖 onChange 时序,故这里只单纯设值。
    public func updateScreenAwakeMode(_ raw: String) {
        guard viewModel.screenAwakeModeRaw != raw else { return }
        viewModel.screenAwakeModeRaw = raw
    }

    /// App 用:把「定时自动关」Picker 程序化设到某值(如启用 lid 时默认 8h)。
    public func updateScreenAwakeAutoOff(_ raw: String) {
        guard viewModel.screenAwakeAutoOffRaw != raw else { return }
        viewModel.screenAwakeAutoOffRaw = raw
    }

    /// Task E: 关于面板里显示的版本字符串。
    public var aboutVersionText: String { viewModel.aboutVersion }

    /// 当前选中的温度档 raw ("auto" / "winter" / "spring" / "sauna")。测试用。
    public var selectedThermalOverrideRaw: String { viewModel.thermalOverrideRaw }

    /// 暴露 toolEngineCLI label 的 stringValue 兼容旧测试。
    /// SwiftUI 重写后 CLI 路径已并入 viewModel,这里返回 "CLI: <path>" 或
    /// "CLI: 未安装",与原 NSTextField 行为一致。
    public var toolEngineCLIPathLabel: ToolEngineCLILabelProxy {
        ToolEngineCLILabelProxy { [weak viewModel] in
            viewModel?.toolEngineCLIDisplay ?? "CLI: 未安装"
        }
    }

    /// The window's title (test-readable without presenting the window).
    public let windowTitle = "OpenPetAgent 设置"

    // MARK: - Private state

    private let window: NSWindow
    /// SwiftUI 视图绑定的状态对象。所有字段都来源于此,save 时也从此读取。
    private let viewModel: SettingsViewModel
    /// 装载 SwiftUI root view 的 NSHostingView,在 `show()` 首次延迟构造。
    private var hostingView: NSHostingView<SettingsRootView>?
    /// 关窗 flush LLM 用的 window delegate(强持有,否则被释放)。
    private var closeObserver: SettingsCloseObserver?
    /// 窗口变 key 时刷新权限态的 observer token；deinit 时移除,防止 NotificationCenter 泄漏。
    private var didBecomeKeyObserver: NSObjectProtocol?

    // MARK: - Init

    public init(
        selectedProvider: String = "openAICompatible",
        existingAPIKey: String = "",
        existingBaseURL: String = "",
        existingModel: String = "",
        // 默认 = `SoulBackendOption.defaults`(preview / 测试用,不经 App 注入时);
        // 生产由 App 从 `SoulBackendRegistry.all` 注入,picker 不写死二元。
        availableSoulBackends: [SoulBackendOption] = SoulBackendOption.defaults,
        availablePetPlugins: [PetPluginEntry] = [],
        currentPetPluginID: String = "orb",
        petScale: Double = 1,
        activeDecorativePetIDs: Set<String> = [],
        islandEnabled: Bool = true,
        notchAvailable: Bool = false,
        toolModeEnabled: Bool = false,
        currentToolEngineKind: String = "claudeCode",
        // 默认 = 当前内置三 engine,供 SwiftUI preview / 测试用(它们不经 App 注入);
        // 生产路径由 App 从 `ToolEngineRegistry.all` 注入,picker 不写死。
        availableToolEngines: [(id: String, displayName: String)] = [
            (id: "claudeCode", displayName: "Claude Code"),
            (id: "codex", displayName: "Codex"),
            (id: "openCode", displayName: "opencode")
        ],
        toolEngineCLIPath: String? = nil,
        openClawStatusDescription: String = "⚪ 未启动",
        openClawAutoStart: Bool = true,
        openClawAllowEndpointEnable: Bool = true,
        launchAtLogin: Bool = false,
        menuBarIconVisible: Bool = false,
        agentSensingEnabled: Bool = true,
        permissionAnsweringEnabled: Bool = false,
        freezeWhenInteracting: Bool = true,
        screenAwakeModeRaw: String = "off",
        screenAwakeAutoOffRaw: String = "never",
        screenAwakeDisableOnLowPower: Bool = true,
        islandHidePetOnSwitch: Bool = true,
        autoFollowLocation: Bool = false,
        selectedCityID: String = "beijing",
        forcedConditionRaw: String = "auto",
        thermalOverrideRaw: String = "auto",
        fallingSandTuning: FallingSandTuning = FallingSandTuning(),
        ballisticTuning: BallisticTuning = BallisticTuning(),
        proactiveSettings: ProactiveSettings = .default,
        currentWeatherDescription: String = "⏳ 等待首次刷新…",
        aboutVersion: String = "OpenPetAgent (dev)"
    ) {
        // 按 id 在注入列表里定位当前后端(取代写死「anthropic→1 否则 0」)。
        // 关键:openclaw 现在能正确定位到自己的下标 —— 修掉「openclaw 激活时 picker
        // 错显 OpenAI 兼容选中」的视觉 bug。未知 id → 归 0(openAICompatible)。
        let providerIndex = availableSoulBackends.firstIndex { $0.id == selectedProvider } ?? 0

        self.viewModel = SettingsViewModel(
            selectedProviderIndex: providerIndex,
            soulBackends: availableSoulBackends,
            apiKey: existingAPIKey,
            baseURL: existingBaseURL,
            model: existingModel,
            availablePetPlugins: availablePetPlugins,
            selectedPetPluginID: currentPetPluginID,
            petScale: petScale,
            activeDecorativeIDs: activeDecorativePetIDs,
            islandEnabled: islandEnabled,
            notchAvailable: notchAvailable,
            islandHidePetOnSwitch: islandHidePetOnSwitch,
            toolModeEnabled: toolModeEnabled,
            toolEngineKind: currentToolEngineKind,
            availableToolEngines: availableToolEngines,
            toolEngineCLIPath: toolEngineCLIPath,
            openClawStatusDescription: openClawStatusDescription,
            openClawAutoStart: openClawAutoStart,
            openClawAllowEndpointEnable: openClawAllowEndpointEnable,
            launchAtLogin: launchAtLogin,
            menuBarIconVisible: menuBarIconVisible,
            agentSensingEnabled: agentSensingEnabled,
            permissionAnsweringEnabled: permissionAnsweringEnabled,
            freezeWhenInteracting: freezeWhenInteracting,
            screenAwakeModeRaw: screenAwakeModeRaw,
            screenAwakeAutoOffRaw: screenAwakeAutoOffRaw,
            screenAwakeDisableOnLowPower: screenAwakeDisableOnLowPower,
            autoFollowLocation: autoFollowLocation,
            selectedCityID: selectedCityID,
            forcedConditionRaw: forcedConditionRaw,
            thermalOverrideRaw: thermalOverrideRaw,
            fallingSandTuning: fallingSandTuning,
            ballisticTuning: ballisticTuning,
            proactiveSettings: proactiveSettings,
            currentWeatherDescription: currentWeatherDescription,
            aboutVersion: aboutVersion
        )

        // 固定 contentRect 跟 SwiftUI root view 的 frame(640×520) 对齐 +
        // 少量 chrome 高度。NSPanel `.titled` 自动算 titlebar 高度。
        // 用自定义 SettingsKeyForwardingWindow 子类把 ⌘A/C/V/X/Z 等编辑快捷键
        // 转发到 first responder 的标准 selector — SwiftUI TextField 在没有
        // 完整 NSApp menu bar 的非典型 menu app 里默认拿不到 ⌘+key 事件。
        let size = NSSize(width: 640, height: 520)
        let rect = NSRect(origin: .zero, size: size)
        window = SettingsKeyForwardingWindow(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenPetAgent 设置"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces]

        // Preview wire: 城市 / 强制天气 picker 切完立刻预览(modeless,改动即时生效,**不写 UD**),
        // 保存才持久化(handleSave 走 onSaveCity / onSaveForcedCondition)。无取消/回滚。
        // 必须 init 末段 (所有 stored property 写入后) 才能用 `self` 引用。
        self.viewModel.onCityPreview = { [weak self] cityID in
            self?.onCityPreview(cityID)
        }
        self.viewModel.onForcedConditionPreview = { [weak self] raw in
            self?.onForcedConditionPreview(raw)
        }
        self.viewModel.onThermalOverridePreview = { [weak self] raw in
            self?.onThermalOverridePreview(raw)
        }
        self.viewModel.onFallingSandTuningPreview = { [weak self] tuning in
            self?.onFallingSandTuningPreview(tuning)
        }
        self.viewModel.onBallisticTuningPreview = { [weak self] tuning in
            self?.onBallisticTuningPreview(tuning)
        }
        self.viewModel.onProactiveSettingsPreview = { [weak self] settings in
            self?.onProactiveSettingsPreview(settings)
        }
        self.viewModel.onPetScalePreview = { [weak self] scale in
            self?.onPetScalePreview(scale)
        }
        self.viewModel.onToggleDecorativePet = { [weak self] id, on in
            self?.onToggleDecorativePet(id, on)
        }
        self.viewModel.onToggleDecorativePack = { [weak self] ids, on in
            self?.onToggleDecorativePack(ids, on)
        }
        // Modeless 即时提交:控件改动 → 直接调 App 的持久化+应用闭包(读 call 时已被 App 注入)。
        self.viewModel.onSelectPet = { [weak self] id in self?.onSavePlugin(id) }
        self.viewModel.onCommitIsland = { [weak self] on in self?.onSaveIslandEnabled(on) }
        self.viewModel.onCommitIslandHidePet = { [weak self] on in self?.onSaveIslandHidePetOnSwitch(on) }
        self.viewModel.onCommitToolMode = { [weak self] on in self?.onSaveToolModeEnabled(on) }
        self.viewModel.onCommitToolEngine = { [weak self] raw in self?.onSaveToolEngineKind(raw) }
        self.viewModel.onCommitLaunchAtLogin = { [weak self] on in self?.onSaveLaunchAtLogin(on) }
        self.viewModel.onCommitMenuBarIconVisible = { [weak self] on in self?.onSaveMenuBarIconVisible(on) }
        self.viewModel.onCommitAgentSensing = { [weak self] on in self?.onSaveAgentSensing(on) }
        self.viewModel.onCommitPermissionAnswering = { [weak self] on in self?.onSavePermissionAnswering(on) }
        self.viewModel.onCommitFreezeWhenInteracting = { [weak self] on in self?.onSaveFreezeWhenInteracting(on) }
        self.viewModel.onCommitOpenClawAutoStart = { [weak self] on in self?.onSaveOpenClawAutoStart(on) }
        self.viewModel.onCommitOpenClawAllowEndpoint = { [weak self] on in self?.onSaveOpenClawAllowEndpointEnable(on) }
        self.viewModel.onCommitScreenAwakeMode = { [weak self] raw in self?.onSaveScreenAwakeMode(raw) }
        self.viewModel.onCommitScreenAwakeAutoOff = { [weak self] raw in self?.onSaveScreenAwakeAutoOff(raw) }
        self.viewModel.onCommitScreenAwakeDisableOnLowPower = { [weak self] on in self?.onSaveScreenAwakeDisableOnLowPower(on) }
        self.viewModel.onCommitAutoFollowLocation = { [weak self] on in self?.onCommitAutoFollowLocation(on) }
        self.viewModel.onCommitLLM = { [weak self] in self?.commitLLM() }

        // 关窗时 flush LLM 文本框(用户输完没按回车直接关窗也持久化;binding 已实时更新 viewModel)。
        let observer = SettingsCloseObserver { [weak self] in self?.commitLLM() }
        window.delegate = observer
        self.closeObserver = observer

        // Step 3(Task 4): 设置窗变为 key 时刷新权限态。
        // 用户去系统设置授权后切回 → 立即重查四态,无需手动刷新。
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // 必须保持 queue: .main,否则 assumeIsolated 会 crash(precondition:当前需在 main actor)。
            MainActor.assumeIsolated {
                self?.viewModel.onRefreshPermissions()
            }
        }
    }

    deinit {
        if let o = didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: - Show

    /// Present the window centred on screen。
    public func show() {
        // 每次开设置重新 discover:① 读启动后才生成的 Live2D 缩略图缓存(启动 discover 跑在
        // 后台生成之前 → registry 快照缩略图为 nil,不刷新就一直占位);② 拾取 CLI / 外部新装的
        // 宠(免重启)。selectedPetPluginID 仍在列表则保留选中。
        viewModel.rebuildPetList()
        if hostingView == nil {
            let root = SettingsRootView(viewModel: viewModel)
            let hosting = NSHostingView(rootView: root)
            // 决策 #1/#6 (HermesPet):禁掉 NSHostingView 反向请求 NSWindow.setFrame,
            // 否则 SwiftUI 算 intrinsic size 时可能跟 controller 自身 setFrame
            // 撞车触发 macOS 26 嵌套 layout 崩溃。
            if #available(macOS 13.0, *) {
                hosting.sizingOptions = []
            }
            window.contentView = hosting
            hostingView = hosting
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 异步刷新

    /// Task 4: 用 probe 刷新权限四态(App 初始灌一次;窗口变 key / onAppear 也会通过 onRefreshPermissions 触发)。
    public func refreshPermissions(using probe: SystemPermissionProbe) {
        viewModel.refreshPermissions(using: probe)
    }

    /// 当前权限四态快照(测试用)。
    public var permissionStatuses: [SystemPermission: PermissionStatus] { viewModel.permissionStatuses }

    /// caller 拿到 `OpenClawGatewayManager.shared.status` 后用此方法异步更新 UI。
    public func updateOpenClawStatusDescription(_ description: String) {
        viewModel.openClawStatusDescription = description
    }

    /// caller 重新探测 CLI binary 后调本方法刷新当前 tool engine 路径行。
    public func updateToolEngineCLIPath(_ path: String?) {
        viewModel.toolEngineCLIPath = path
    }

    /// WeatherStateManager 每次 refresh 后调本方法刷新设置面板"当前天气"卡片。
    public func updateCurrentWeatherDescription(_ description: String) {
        viewModel.currentWeatherDescription = description
    }

    /// 由 App 推入「自动跟随」的真实当前位置文案(逆地理编码城市 + 坐标);`nil` 清空。
    public func updateAutoFollowLocationLabel(_ label: String?) {
        viewModel.autoFollowLocationLabel = label
    }

    // MARK: - Test seams (向后兼容,绕过真实 UI 直接驱动 viewModel)

    /// Programmatically trigger the save flow with all four values.
    public func simulateSaveAll(apiKey: String, baseURL: String, model: String) {
        viewModel.apiKey = apiKey
        viewModel.baseURL = baseURL
        viewModel.model = model
        handleSave()
    }

    /// Programmatically save with provider selection.
    public func simulateSaveProvider(provider: String, apiKey: String, baseURL: String, model: String) {
        viewModel.selectedProviderIndex = viewModel.soulBackends.firstIndex { $0.id == provider } ?? 0
        viewModel.apiKey = apiKey
        viewModel.baseURL = baseURL
        viewModel.model = model
        handleSave()
    }

    /// Programmatically trigger the save flow (single-field legacy seam).
    public func simulateSave(apiKey: String) {
        viewModel.apiKey = apiKey
        viewModel.baseURL = ""
        viewModel.model = ""
        handleSave()
    }

    /// Programmatically select a provider by name (for tests that check UI state).
    public func simulateSelectProvider(_ provider: String) {
        viewModel.selectedProviderIndex = viewModel.soulBackends.firstIndex { $0.id == provider } ?? 0
    }

    /// N1.3: 直接设置灵动岛 toggle 状态(测试用)。
    /// 注意:若 notchAvailable=false,islandEnabled 强制保持 false(matches
    /// 原 AppKit 行为 — toggle.isEnabled=false 时 state 无法变化)。
    internal func simulateToggleIsland(_ on: Bool) {
        guard viewModel.notchAvailable else { return }
        viewModel.islandEnabled = on
    }

    /// N2.3: 直接设置 Tool Mode toggle 状态(测试用)。
    public func simulateToggleToolMode(_ on: Bool) {
        viewModel.toolModeEnabled = on
    }

    /// N3.6: Programmatically select a pet plugin by id(测试用)。
    public func simulateSelectPetPlugin(_ pluginID: String) {
        viewModel.selectPetPlugin(pluginID)
    }

    /// 当前激活为同屏装饰伙伴的宠物 id 集(测试用)。
    public var activeDecorativePetIDs: Set<String> { viewModel.activeDecorativeIDs }

    /// Phase 2: 切某宠的「同屏」装饰伙伴状态(测试用)—— 跟库 sheet 的同屏 pill 一致,
    /// 触发 onToggleDecorativePet 回调。
    public func simulateToggleDecorativePet(_ id: String) {
        viewModel.toggleDecorativePet(id)
    }

    /// Phase 2 S5: 切某包整包同屏(测试用)—— 按 packId 在 groupedByPack 找到包再 toggleWholePack。
    /// 触发 onToggleDecorativePack 批量回调。找不到包静默忽略。
    public func simulateToggleWholePack(packId: String) {
        guard let pack = viewModel.groupedByPack.lazy.flatMap(\.packs).first(where: { $0.id == packId }) else { return }
        viewModel.toggleWholePack(pack)
    }

    /// Task E: 选择 tool engine kind by raw string(测试用)。
    public func simulateSelectToolEngineKind(_ kindRaw: String) {
        viewModel.selectToolEngineKind(kindRaw)
    }

    /// 直接设置 "开机自启" toggle(测试用)—— 触发 onCommit,跟真实 Toggle.onChange 一致。
    public func simulateToggleLaunchAtLogin(_ on: Bool) {
        viewModel.launchAtLogin = on
        viewModel.onCommitLaunchAtLogin(on)
    }

    /// 直接设置 "在菜单栏显示图标" toggle(测试用)。
    public func simulateToggleMenuBarIconVisible(_ on: Bool) {
        viewModel.menuBarIconVisible = on
        viewModel.onCommitMenuBarIconVisible(on)
    }

    /// 直接设置 感知/权限/冻结 toggle(测试用)。
    public func simulateToggleAgentSensing(_ on: Bool) {
        viewModel.agentSensingEnabled = on
        viewModel.onCommitAgentSensing(on)
    }
    public func simulateTogglePermissionAnswering(_ on: Bool) {
        viewModel.permissionAnsweringEnabled = on
        viewModel.onCommitPermissionAnswering(on)
    }
    public func simulateToggleFreezeWhenInteracting(_ on: Bool) {
        viewModel.freezeWhenInteracting = on
        viewModel.onCommitFreezeWhenInteracting(on)
    }

    /// Task E: 直接设置 OpenClaw 自动启动 toggle(测试用)。
    public func simulateToggleOpenClawAutoStart(_ on: Bool) {
        viewModel.openClawAutoStart = on
    }

    /// Task E: 直接设置 "允许自动 enable chatCompletions" toggle(测试用)。
    public func simulateToggleOpenClawAllowEndpointEnable(_ on: Bool) {
        viewModel.openClawAllowEndpointEnable = on
    }

    /// Task E: 直接设置 "灵动岛切桌面隐藏桌宠" toggle(测试用)。
    public func simulateToggleIslandHidePetOnSwitch(_ on: Bool) {
        viewModel.islandHidePetOnSwitch = on
    }

    /// 选择 "防休眠" 模式 by raw(测试用)—— 触发 onCommit，跟真实 Picker.onChange 一致。
    public func simulateSelectScreenAwakeMode(_ raw: String) {
        viewModel.screenAwakeModeRaw = raw
        viewModel.onCommitScreenAwakeMode(raw)
    }

    /// 选择 "防休眠" 定时自动关 by raw(测试用)。
    public func simulateSelectScreenAwakeAutoOff(_ raw: String) {
        viewModel.screenAwakeAutoOffRaw = raw
        viewModel.onCommitScreenAwakeAutoOff(raw)
    }

    /// 设 "低电量自动关" 开关(测试用)。
    public func simulateToggleScreenAwakeDisableOnLowPower(_ on: Bool) {
        viewModel.screenAwakeDisableOnLowPower = on
        viewModel.onCommitScreenAwakeDisableOnLowPower(on)
    }

    /// 选择温度档 by raw（测试用）—— 触发 preview，跟真实 Picker.onChange 一致。
    public func simulateSelectThermalOverride(_ raw: String) {
        viewModel.thermalOverrideRaw = raw
        viewModel.onThermalOverridePreview(raw)
    }

    /// 当前调参（测试用）。
    public var currentFallingSandTuning: FallingSandTuning { viewModel.fallingSandTuning }

    /// 改调参（测试用）—— 改 viewModel + 触发 preview，跟真实滑块 onChange 一致。
    public func simulateSetFallingSandTuning(_ mutate: (inout FallingSandTuning) -> Void) {
        var t = viewModel.fallingSandTuning
        mutate(&t)
        viewModel.fallingSandTuning = t
        viewModel.onFallingSandTuningPreview(t)
    }

    /// 当前主动协助设置（测试用）。
    public var currentProactiveSettings: ProactiveSettings { viewModel.proactiveSettings }

    /// 改主动协助设置（测试用）—— 改 viewModel + 触发 preview，跟真实控件 onChange 一致。
    public func simulateSetProactiveSettings(_ mutate: (inout ProactiveSettings) -> Void) {
        var s = viewModel.proactiveSettings
        mutate(&s)
        viewModel.proactiveSettings = s
        viewModel.onProactiveSettingsPreview(s)
    }

    // MARK: - Private handlers

    /// 测试 seam（`simulateSave*`)+ 兼容旧路径用 —— 一次性提交所有字段(modeless 下 UI 已逐项即时提交,
    /// 这里只剩 test/兜底语义)。生产交互不再走此(无「保存」按钮),各控件 onChange 直接 commit。
    private func handleSave() {
        let hasPlugin = !viewModel.petPlugins.isEmpty
        if hasPlugin { onSavePlugin(viewModel.selectedPetPluginID) }
        onSaveIslandEnabled(viewModel.effectiveIslandOn)
        onSaveToolModeEnabled(viewModel.toolModeEnabled)
        onSaveToolEngineKind(viewModel.toolEngineKind)
        onSaveLaunchAtLogin(viewModel.launchAtLogin)
        onSaveMenuBarIconVisible(viewModel.menuBarIconVisible)
        onSaveAgentSensing(viewModel.agentSensingEnabled)
        onSavePermissionAnswering(viewModel.permissionAnsweringEnabled)
        onSaveFreezeWhenInteracting(viewModel.freezeWhenInteracting)
        onSaveOpenClawAutoStart(viewModel.openClawAutoStart)
        onSaveOpenClawAllowEndpointEnable(viewModel.openClawAllowEndpointEnable)
        onSaveScreenAwakeMode(viewModel.screenAwakeModeRaw)
        onSaveScreenAwakeAutoOff(viewModel.screenAwakeAutoOffRaw)
        onSaveScreenAwakeDisableOnLowPower(viewModel.screenAwakeDisableOnLowPower)
        onSaveIslandHidePetOnSwitch(viewModel.islandHidePetOnSwitch)
        onSaveCity(viewModel.selectedCityID)
        onSaveForcedCondition(viewModel.forcedConditionRaw)
        onSaveThermalOverride(viewModel.thermalOverrideRaw)
        onSaveFallingSandTuning(viewModel.fallingSandTuning)
        onSaveProactiveSettings(viewModel.proactiveSettings)
        onSavePetScale(viewModel.petScale)
        commitLLM()
    }

    /// 提交 LLM(provider/key/baseURL/model)—— 文本框 onSubmit / 关窗 flush / 切
    /// provider 时调。provider 字符串按选中后端 `id` 分发(不写死二元)。
    func commitLLM() {
        let backend = viewModel.selectedBackend
        // 自动管理后端(openclaw):只持久化「选了它」这个身份,不要求手填、也不写
        // 任何云槽(其专属槽由 App auto-bootstrap 管,这里碰了反会清掉)。
        if backend.managed {
            onSaveProvider(backend.id, "", "", "")
            return
        }
        let trimmedKey = viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = viewModel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = viewModel.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !trimmedKey.isEmpty
        let hasBaseURL = !trimmedBaseURL.isEmpty
        // 云后端字段都空 → 不触发(避免空配置覆盖已存的 key)。
        guard hasKey || hasBaseURL else { return }
        onSaveProvider(backend.id, trimmedKey, trimmedBaseURL, trimmedModel)
        onSaveAll(trimmedKey, trimmedBaseURL, trimmedModel)
        if hasKey { onSave(trimmedKey) }
    }
}

/// 设置窗关闭时 flush LLM 文本框(modeless 下文本框只在回车/关窗提交)。强持有于 controller。
final class SettingsCloseObserver: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// 旧测试代码用 `controller.toolEngineCLIPathLabel.stringValue` 读 CLI 路径,
/// 此结构体提供 `stringValue` 计算属性桥接到 viewModel,保持 API 兼容。
public struct ToolEngineCLILabelProxy {
    private let read: () -> String
    init(_ read: @escaping () -> String) { self.read = read }
    public var stringValue: String { read() }
}
