import AppKit

@MainActor
public final class MenuBarController: NSObject {
    // 「温度模式」已迁移到 设置 → 天气 tab（`ThermalOverrideMode` + SettingsWeatherSection）。
    // 物理沙盒 ambient 温度由天气系统 / 温度覆盖档驱动，不再走状态栏菜单。
    //
    // 天气控制统一成**单一「天气」子菜单的单选**：「关闭天气效果」(off) + auto + 5 个强制条件
    // 共 7 项互斥单选。选 off = 关效果(清场+干净桌面);选其余 = 开效果 + 对应强制天气。
    // 这样 on/off 与「哪种天气」合成一条线性单选 —— 不存在「关了又选下雪」的无效状态,
    // 无需置灰联动(旧「天气效果」「天气」两个分裂子菜单 + 总开关已废弃)。

    public var onToggleFollowing: @MainActor (Bool) -> Void = { _ in }
    /// 「桌面漫游」开关切换(自主漫步 + 爬墙)。
    public var onToggleRoaming: @MainActor (Bool) -> Void = { _ in }
    // 感知编码会话 / 权限应答 / 交互冻结 已迁到 设置 → 系统 →「感知与交互」,不再走菜单。
    public var onChat: @MainActor () -> Void = {}
    public var onSettings: @MainActor () -> Void = {}
    public var onShareScreenshot: @MainActor () -> Void = {}

    /// 用户在天气 submenu 选「天气模式」单选项时触发。
    /// raw ∈ {"off", "auto", "sunny", "cloudy", "rainy", "snowy", "windy"};"off" = 关闭天气效果。
    public var onSelectForcedCondition: @MainActor (String) -> Void = { _ in }

    /// 清场：立即清除所有积雪/降水（不改天气模式,只清当前积雪）。
    public var onClearWeather: @MainActor () -> Void = {}
    public var onQuit: @MainActor () -> Void = {
        NSApplication.shared.terminate(nil)
    }

    public private(set) var isFollowingEnabled: Bool
    public private(set) var isRoamingEnabled: Bool

    private let menu = NSMenu()
    private let followingItem: NSMenuItem
    private let roamingItem: NSMenuItem
    private var statusItem: NSStatusItem?

    /// 天气 submenu 内 "当前天气" 信息 row (disabled, 仅展示)。
    private let weatherCurrentItem: NSMenuItem = {
        let item = NSMenuItem(title: "⏳ 等待首次刷新…", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }()

    /// 7 个天气模式单选 sub-item, raw → item 字典便于切换 check state。
    private var forcedConditionItems: [String: NSMenuItem] = [:]

    /// 当前选中的天气模式 raw, 默认 auto。
    private var currentForcedConditionRaw: String = "auto"

    /// 全部支持的天气模式 raw + display name 列表(off 在最前,auto 次之)。
    /// 跟 PetShellWindow / SettingsViewModel 的列表顺序对齐。
    public static let forcedConditionOptions: [(raw: String, displayName: String, symbol: String)] = [
        ("off", "关闭天气效果", "xmark.circle"),
        ("auto", "自动 (跟随真实)", "arrow.triangle.2.circlepath"),
        ("sunny", "强制晴天", "sun.max.fill"),
        ("cloudy", "强制多云", "cloud.fill"),
        ("rainy", "强制下雨", "cloud.rain.fill"),
        ("snowy", "强制下雪", "cloud.snow.fill"),
        ("windy", "强制大风", "wind")
    ]

    public init(
        initialFollowingEnabled: Bool = false,
        initialRoamingEnabled: Bool = true
    ) {
        self.isFollowingEnabled = initialFollowingEnabled
        self.isRoamingEnabled = initialRoamingEnabled
        followingItem = NSMenuItem(title: "跟随光标", action: nil, keyEquivalent: "")
        followingItem.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: nil)
        followingItem.state = initialFollowingEnabled ? .on : .off
        roamingItem = NSMenuItem(title: "桌面漫游", action: nil, keyEquivalent: "")
        roamingItem.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: nil)
        roamingItem.state = initialRoamingEnabled ? .on : .off
        super.init()
        followingItem.target = self
        followingItem.action = #selector(handleFollowingToggle(_:))
        menu.addItem(followingItem)
        roamingItem.target = self
        roamingItem.action = #selector(handleRoamingToggle(_:))
        menu.addItem(roamingItem)
        // 感知编码会话 / 权限应答 / 交互冻结 这 3 个 set-once 进阶开关已迁到 设置 → 系统 →「感知与交互」,
        // 菜单(状态栏 + pet 右键)保持精简且一致。
        menu.addItem(.separator())

        let chatItem = NSMenuItem(title: "打开聊天浮窗", action: #selector(handleChat(_:)), keyEquivalent: " ")
        chatItem.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: nil)
        chatItem.keyEquivalentModifierMask = [.command, .shift]
        chatItem.target = self
        menu.addItem(chatItem)

        let shareItem = NSMenuItem(title: "截图分享", action: #selector(handleShareScreenshot(_:)), keyEquivalent: "")
        shareItem.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)
        shareItem.target = self
        menu.addItem(shareItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(handleSettings(_:)), keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // 「天气」submenu —— 当前快照 + 7 个天气模式单选(off/auto/5 条件)+ 清场 + 直达 Settings。
        let weatherItem = NSMenuItem(title: "天气", action: nil, keyEquivalent: "")
        weatherItem.image = NSImage(systemSymbolName: "cloud.sun.fill", accessibilityDescription: nil)
        let weatherSubmenu = NSMenu()

        weatherSubmenu.addItem(weatherCurrentItem)
        weatherSubmenu.addItem(.separator())

        for option in Self.forcedConditionOptions {
            let item = NSMenuItem(
                title: option.displayName,
                action: #selector(handleForcedConditionSelect(_:)),
                keyEquivalent: ""
            )
            item.image = NSImage(systemSymbolName: option.symbol, accessibilityDescription: nil)
            item.target = self
            item.representedObject = option.raw
            item.state = (option.raw == currentForcedConditionRaw) ? .on : .off
            weatherSubmenu.addItem(item)
            forcedConditionItems[option.raw] = item
        }

        weatherSubmenu.addItem(.separator())

        let clearItem = NSMenuItem(title: "立即清除积雪", action: #selector(handleClearWeather(_:)), keyEquivalent: "")
        clearItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        clearItem.target = self
        weatherSubmenu.addItem(clearItem)

        let weatherSettingsItem = NSMenuItem(
            title: "打开天气设置...",
            action: #selector(handleSettings(_:)),
            keyEquivalent: ""
        )
        weatherSettingsItem.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
        weatherSettingsItem.target = self
        weatherSubmenu.addItem(weatherSettingsItem)

        weatherItem.submenu = weatherSubmenu
        menu.addItem(weatherItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 OpenPetAgent", action: #selector(handleQuit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    public var menuForTesting: NSMenu {
        menu
    }

    public func attachToSystemStatusBar(title: String = "❄") -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = title
        item.menu = menu
        statusItem = item
        return item
    }

    /// 显示 / 隐藏菜单栏状态项(由设置开关驱动,默认隐藏)。隐藏时彻底移除 NSStatusItem
    /// (不只是 isVisible=false,避免占位)。截图分享的锚点已有 overlay 兜底,隐藏无碍。
    public func setStatusItemVisible(_ visible: Bool, title: String = "❄") {
        if visible {
            if statusItem == nil { _ = attachToSystemStatusBar(title: title) }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// 当前菜单栏状态项是否显示(测试用)。
    public var isStatusItemVisible: Bool { statusItem != nil }

    /// 状态项按钮(截图分享锚点用);隐藏时为 nil → 调用方回退到 overlay。
    public var statusItemButton: NSStatusBarButton? { statusItem?.button }

    @objc private func handleFollowingToggle(_ sender: Any?) {
        isFollowingEnabled.toggle()
        followingItem.state = isFollowingEnabled ? .on : .off
        onToggleFollowing(isFollowingEnabled)
    }

    @objc private func handleRoamingToggle(_ sender: Any?) {
        isRoamingEnabled.toggle()
        roamingItem.state = isRoamingEnabled ? .on : .off
        onToggleRoaming(isRoamingEnabled)
    }

    /// 由 caller 把跟随状态同步到菜单 check state, 不触发 callback(跨入口一致)。
    public func syncFollowingState(_ enabled: Bool) {
        isFollowingEnabled = enabled
        followingItem.state = enabled ? .on : .off
    }

    /// 由 caller 把漫游状态同步到菜单 check state, 不触发 callback(跨入口一致)。
    public func syncRoamingState(_ enabled: Bool) {
        isRoamingEnabled = enabled
        roamingItem.state = enabled ? .on : .off
    }

    /// 当前形象是否响应「跟随光标 / 桌面漫游」开关 —— 由 caller(app)注入,读当前 renderer 的
    /// `driveModel.supportsHostDrivenMotion`。pull 式:菜单每次打开经 `validateMenuItem` 实时求值,
    /// 换形象后无需推送、不会 stale。默认 `{ true }`(未注入时维持旧行为=恒可点)。
    public var isMotionApplicable: () -> Bool = { true }

    @objc private func handleClearWeather(_ sender: Any?) {
        onClearWeather()
    }

    @objc private func handleChat(_ sender: Any?) {
        onChat()
    }

    @objc private func handleForcedConditionSelect(_ sender: Any?) {
        guard
            let item = sender as? NSMenuItem,
            let raw = item.representedObject as? String
        else { return }
        selectForcedCondition(raw)
    }

    /// 设置天气模式 (UI check state + 通知 callback)。Test seam 也走这里。
    public func selectForcedCondition(_ raw: String) {
        currentForcedConditionRaw = raw
        for (key, item) in forcedConditionItems {
            item.state = (key == raw) ? .on : .off
        }
        onSelectForcedCondition(raw)
    }

    /// 由 WeatherStateManager.onUpdate 调:更新 submenu 内"当前天气"展示行
    /// (温度/风速/condition/刷新时间)。天气模式的 check state 由
    /// `selectForcedCondition(_:)` / `syncForcedConditionState(_:)` 单独维护。
    public func updateWeatherCurrent(_ description: String) {
        weatherCurrentItem.title = description
    }

    /// 由 caller (MinimalAppDelegate) 把当前天气模式 raw(含 "off")同步到 submenu
    /// check state, 不触发 callback。
    public func syncForcedConditionState(_ raw: String) {
        guard forcedConditionItems[raw] != nil else { return }
        currentForcedConditionRaw = raw
        for (key, item) in forcedConditionItems {
            item.state = (key == raw) ? .on : .off
        }
    }

    @objc private func handleSettings(_ sender: Any?) {
        onSettings()
    }

    @objc private func handleShareScreenshot(_ sender: Any?) {
        onShareScreenshot()
    }

    @objc private func handleQuit(_ sender: Any?) {
        onQuit()
    }
}

extension MenuBarController: NSMenuItemValidation {
    /// 菜单展开时实时求值:仅「跟随光标 / 桌面漫游」随当前形象的 `isMotionApplicable` 灰掉,
    /// 其余项恒可用。`autoenablesItems` 默认 true → 菜单对每个 target=self 的项调此方法。
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === followingItem || menuItem === roamingItem {
            return isMotionApplicable()
        }
        return true
    }
}
