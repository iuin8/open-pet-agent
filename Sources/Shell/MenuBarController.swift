import AppKit

/// 状态栏菜单宿主 —— 菜单结构走**共享的 `PetActionMenu`**(与右键桌宠菜单同一份定义,
/// 加项只改 PetActionMenu 一处、两菜单自动同步)。本类只负责:① 状态项生命周期
/// ② 把 PetActionMenu 的动作回调 / 状态同步桥接到 App。
@MainActor
public final class MenuBarController: NSObject {
    public var onToggleFollowing: @MainActor (Bool) -> Void = { _ in }
    /// 「桌面漫游」开关切换(自主漫步 + 爬墙)。
    public var onToggleRoaming: @MainActor (Bool) -> Void = { _ in }
    public var onChat: @MainActor () -> Void = {}
    public var onSettings: @MainActor () -> Void = {}
    public var onShareScreenshot: @MainActor () -> Void = {}

    /// 用户在天气 submenu 选「天气模式」单选项时触发("off"/"auto"/5 条件)。
    public var onSelectForcedCondition: @MainActor (String) -> Void = { _ in }
    /// 清场:立即清除积雪/降水(不改天气模式)。
    public var onClearWeather: @MainActor () -> Void = {}
    public var onQuit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }

    public private(set) var isFollowingEnabled: Bool
    public private(set) var isRoamingEnabled: Bool

    /// 当前形象是否响应**「跟随光标」**开关(灰显 gate),App 注入;转发给共享菜单。
    public var isMotionApplicable: () -> Bool = { true } {
        didSet { actionMenu.isMotionApplicable = isMotionApplicable }
    }
    /// 当前形象是否响应**「桌面漫游」**开关(独立灰显 gate,Orb 等纯物理形象灰掉),App 注入;转发给共享菜单。
    public var isRoamingApplicable: () -> Bool = { true } {
        didSet { actionMenu.isRoamingApplicable = isRoamingApplicable }
    }

    /// 7 个天气模式选项(转发共享定义,兼容旧引用)。
    public static let forcedConditionOptions = PetActionMenu.forcedConditionOptions

    private let actionMenu: PetActionMenu
    private var statusItem: NSStatusItem?
    private var currentForcedConditionRaw = "auto"
    private var currentWeatherText = "⏳ 等待首次刷新…"

    public init(initialFollowingEnabled: Bool = false, initialRoamingEnabled: Bool = true) {
        self.isFollowingEnabled = initialFollowingEnabled
        self.isRoamingEnabled = initialRoamingEnabled
        var state = PetActionMenu.State()
        state.following = initialFollowingEnabled
        state.roaming = initialRoamingEnabled
        self.actionMenu = PetActionMenu(callbacks: PetActionMenu.Callbacks(), state: state)
        super.init()
        var cb = PetActionMenu.Callbacks()
        cb.chat = { [weak self] in self?.onChat() }
        cb.screenshot = { [weak self] in self?.onShareScreenshot() }
        cb.settings = { [weak self] in self?.onSettings() }
        cb.toggleFollowing = { [weak self] on in self?.isFollowingEnabled = on; self?.onToggleFollowing(on) }
        cb.toggleRoaming = { [weak self] on in self?.isRoamingEnabled = on; self?.onToggleRoaming(on) }
        cb.selectForcedCondition = { [weak self] raw in
            self?.currentForcedConditionRaw = raw
            self?.onSelectForcedCondition(raw)
        }
        cb.clearWeather = { [weak self] in self?.onClearWeather() }
        cb.quit = { [weak self] in self?.onQuit() }
        actionMenu.callbacks = cb
        actionMenu.isMotionApplicable = { [weak self] in self?.isMotionApplicable() ?? true }
        actionMenu.isRoamingApplicable = { [weak self] in self?.isRoamingApplicable() ?? true }
    }

    public var menuForTesting: NSMenu { actionMenu.menu }

    // MARK: - 状态项生命周期

    public func attachToSystemStatusBar(title: String = "❄") -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = title
        item.menu = actionMenu.menu
        statusItem = item
        return item
    }

    /// 显示 / 隐藏菜单栏状态项(由设置开关驱动,默认隐藏)。隐藏时彻底移除 NSStatusItem。
    public func setStatusItemVisible(_ visible: Bool, title: String = "❄") {
        if visible {
            if statusItem == nil { _ = attachToSystemStatusBar(title: title) }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    public var isStatusItemVisible: Bool { statusItem != nil }
    public var statusItemButton: NSStatusBarButton? { statusItem?.button }

    // MARK: - 状态同步(不触发 callback,跨入口一致)

    public func syncFollowingState(_ enabled: Bool) {
        isFollowingEnabled = enabled
        applyMenuState()
    }

    public func syncRoamingState(_ enabled: Bool) {
        isRoamingEnabled = enabled
        applyMenuState()
    }

    /// 把当前天气模式 raw 同步到 submenu check state,不触发 callback。
    public func syncForcedConditionState(_ raw: String) {
        currentForcedConditionRaw = raw
        applyMenuState()
    }

    /// 更新 submenu 内「当前天气」展示行(WeatherStateManager.onUpdate 调)。
    public func updateWeatherCurrent(_ description: String) {
        currentWeatherText = description
        actionMenu.updateWeatherCurrent(description)
    }

    /// 设置天气模式(UI check + 通知 callback)。Test seam,模拟用户点选。
    public func selectForcedCondition(_ raw: String) {
        currentForcedConditionRaw = raw
        applyMenuState()
        onSelectForcedCondition(raw)
    }

    /// 菜单项灰显校验(测试用,转发共享菜单)。
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        actionMenu.validateMenuItem(menuItem)
    }

    private func applyMenuState() {
        actionMenu.applyState(following: isFollowingEnabled, roaming: isRoamingEnabled,
                              forcedConditionRaw: currentForcedConditionRaw, weatherCurrentText: currentWeatherText)
    }
}
