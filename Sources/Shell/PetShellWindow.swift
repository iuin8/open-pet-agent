import AppKit

@MainActor
public final class PetShellWindow: NSWindow {
    // `.borderless` 窗口默认 canBecomeKey=false → 拖拽 / 右键菜单 / 点击交互需要时显式放开。
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    private var onMouseDown: @MainActor () -> Void = {}
    /// `(落点, clickCount)` —— clickCount 区分单击(轻反应)/双击(开对话卡片)。
    private var onMouseUp: @MainActor (NSPoint, Int) -> Void = { _, _ in }
    /// 拖拽中每帧新窗口 origin(底原点全局)。改2:`isMovableByWindowBackground=false` 后由
    /// 本类显式按鼠标位移驱动,确定 drag 起/移/止(对齐 HermesPet 显式 DragGesture)。
    private var onMouseDragged: @MainActor (NSPoint) -> Void = { _ in }
    /// 拖拽起点缓存:按下时的鼠标全局位置 + 窗口 origin,拖动时算新 origin = 起点 origin + 鼠标位移。
    private var dragStartMouseScreen: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var onShowChat: @MainActor () -> Void = {}
    private var onSnowToggle: @MainActor () -> Void = {}
    /// 「跟随光标」/「桌面漫游」开关切换。
    private var onToggleFollowing: @MainActor (Bool) -> Void = { _ in }
    private var onToggleRoaming: @MainActor (Bool) -> Void = { _ in }
    private var onSettings: @MainActor () -> Void = {}
    private var onShareScreenshot: @MainActor () -> Void = {}
    /// 用户在右键菜单"天气 →"submenu 选 force condition 时触发。
    /// raw ∈ {"auto", "sunny", "cloudy", "rainy", "snowy", "windy"}。
    private var onForceConditionSelected: @MainActor (String) -> Void = { _ in }
    /// 「立即清除积雪」—— 清当前积雪,不改天气模式。
    private var onClearWeather: @MainActor () -> Void = {}
    private var onQuit: @MainActor () -> Void = {}
    /// 装饰宠右键「设为主宠」—— 把本宠升为主宠(host 处理交换)。仅装饰宠菜单含此项。
    private var onSetAsPrimary: @MainActor () -> Void = {}
    /// 是否用「装饰宠精简菜单」(设为主宠 / 设置 / 退出),否则用主宠全功能菜单。
    private var usesDecorativeMenu = false

    /// 6 个 force condition sub-item 引用, 用 raw → item 字典维护 check state。
    private var forcedConditionItems: [String: NSMenuItem] = [:]

    /// 空间行为开关状态 + 菜单项引用(跟随默认 off / 漫游默认 on,启动由 caller sync 校正)。
    private var isFollowingEnabled = false
    private var isRoamingEnabled = true
    private var followingItem: NSMenuItem?
    private var roamingItem: NSMenuItem?

    /// 当前形象是否响应「跟随光标 / 桌面漫游」开关 —— 由 caller(DesktopShellController)注入,读当前
    /// renderer 的 `driveModel.supportsHostDrivenMotion`。pull 式:右键菜单每次打开经 `validateMenuItem`
    /// 实时求值,换形象后无需推送、不会 stale。默认 `{ true }`(未注入时维持旧行为=恒可点)。
    public var isMotionApplicable: () -> Bool = { true }

    /// 右键上下文菜单是否正开着 —— 开着时 App「交互时冻结 pet」让 pet 停住,免漫步把菜单甩在身后
    /// (NSMenu 是原生菜单不跟随窗口,但帧循环 DispatchSourceTimer 队列驱动、不受菜单 tracking 暂停 →
    /// 菜单开着 pet 照样漫步;由 menu delegate 追踪开关态)。
    public private(set) var isContextMenuOpen = false

    /// 当前选中的 force condition raw, 默认 "auto"。install() 时按 caller
    /// 传入的 initialForcedConditionRaw 同步, 之后用户点击 sub-item 时更新。
    private var currentForcedConditionRaw: String = "auto"

    /// 全部支持的天气模式 raw + display name + SF Symbol 列表(off 在最前,auto 次之)。
    /// 跟 MenuBarController.forcedConditionOptions 顺序对齐。"off" = 关闭天气效果(单选第一项,
    /// 取代旧的独立总开关 —— 选 off 即关效果,选其余即开效果+对应强制天气,无无效状态)。
    public static let forcedConditionOptions: [(raw: String, displayName: String, symbol: String)] = [
        ("off", "关闭天气效果", "xmark.circle"),
        ("auto", "自动 (跟随真实)", "arrow.triangle.2.circlepath"),
        ("sunny", "强制晴天", "sun.max.fill"),
        ("cloudy", "强制多云", "cloud.fill"),
        ("rainy", "强制下雨", "cloud.rain.fill"),
        ("snowy", "强制下雪", "cloud.snow.fill"),
        ("windy", "强制大风", "wind")
    ]

    public func install(
        onMouseDown: @escaping @MainActor () -> Void = {},
        onMouseUp: @escaping @MainActor (NSPoint, Int) -> Void,
        onMouseDragged: @escaping @MainActor (NSPoint) -> Void = { _ in },
        onShowChat: @escaping @MainActor () -> Void = {},
        onSnowToggle: @escaping @MainActor () -> Void = {},
        onSettings: @escaping @MainActor () -> Void = {},
        onShareScreenshot: @escaping @MainActor () -> Void = {},
        onForceConditionSelected: @escaping @MainActor (String) -> Void = { _ in },
        onQuit: @escaping @MainActor () -> Void = {},
        onSetAsPrimary: @escaping @MainActor () -> Void = {},
        decorativeMenu: Bool = false
    ) {
        self.onMouseDown = onMouseDown
        self.onMouseUp = onMouseUp
        self.onMouseDragged = onMouseDragged
        self.onShowChat = onShowChat
        self.onSnowToggle = onSnowToggle
        self.onSettings = onSettings
        self.onShareScreenshot = onShareScreenshot
        self.onForceConditionSelected = onForceConditionSelected
        self.onQuit = onQuit
        self.onSetAsPrimary = onSetAsPrimary
        self.usesDecorativeMenu = decorativeMenu
        installContextMenu()
    }

    public override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartMouseScreen = NSEvent.mouseLocation
            dragStartWindowOrigin = frame.origin
            windowMouseDown()
        case .leftMouseDragged:
            // 显式跟手:新 origin = 起点 origin + (当前鼠标 - 起点鼠标),全局底原点同系。
            if let startMouse = dragStartMouseScreen, let startOrigin = dragStartWindowOrigin {
                let now = NSEvent.mouseLocation
                onMouseDragged(NSPoint(x: startOrigin.x + (now.x - startMouse.x),
                                       y: startOrigin.y + (now.y - startMouse.y)))
            }
        case .leftMouseUp:
            windowMouseUp(clickCount: event.clickCount)
            dragStartMouseScreen = nil
            dragStartWindowOrigin = nil
        default:
            break
        }

        super.sendEvent(event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let menu, let contentView else {
            super.rightMouseDown(with: event)
            return
        }

        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }

    public func windowMouseDown() {
        onMouseDown()
    }

    /// clickCount 默认 1（保留旧无参调用方/测试的兼容）。
    public func windowMouseUp(clickCount: Int = 1) {
        onMouseUp(frame.origin, clickCount)
    }

    @objc public func showChatFromContextMenu(_ sender: Any?) {
        onShowChat()
    }

    @objc public func requestSnowToggleFromContextMenu(_ sender: Any?) {
        onSnowToggle()
    }

    @objc public func quitFromContextMenu(_ sender: Any?) {
        onQuit()
    }

    @objc public func setAsPrimaryFromContextMenu(_ sender: Any?) {
        onSetAsPrimary()
    }

    @objc public func settingsFromContextMenu(_ sender: Any?) {
        onSettings()
    }

    /// 菜单批 A: 让 DesktopShellController.setMenuCallbacks 在 init 后注入这两个
    /// 高层 callback (init 时通常是空闭包占位)。
    public func updateMenuCallbacks(
        onSettings: @escaping @MainActor () -> Void,
        onShareScreenshot: @escaping @MainActor () -> Void,
        onForceConditionSelected: @escaping @MainActor (String) -> Void = { _ in },
        onClearWeather: @escaping @MainActor () -> Void = {},
        onToggleFollowing: @escaping @MainActor (Bool) -> Void = { _ in },
        onToggleRoaming: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.onSettings = onSettings
        self.onShareScreenshot = onShareScreenshot
        self.onForceConditionSelected = onForceConditionSelected
        self.onClearWeather = onClearWeather
        self.onToggleFollowing = onToggleFollowing
        self.onToggleRoaming = onToggleRoaming
    }

    @objc public func toggleFollowingFromContextMenu(_ sender: Any?) {
        isFollowingEnabled.toggle()
        followingItem?.state = isFollowingEnabled ? .on : .off
        onToggleFollowing(isFollowingEnabled)
    }

    @objc public func toggleRoamingFromContextMenu(_ sender: Any?) {
        isRoamingEnabled.toggle()
        roamingItem?.state = isRoamingEnabled ? .on : .off
        onToggleRoaming(isRoamingEnabled)
    }

    /// 由 caller(DesktopShellController)把跟随/漫游状态同步到右键菜单 check state,
    /// 不触发 callback(跨入口一致)。
    public func syncSpatialBehavior(following: Bool, roaming: Bool) {
        isFollowingEnabled = following
        isRoamingEnabled = roaming
        followingItem?.state = following ? .on : .off
        roamingItem?.state = roaming ? .on : .off
    }

    /// 右键菜单展开时实时求值:仅「跟随光标 / 桌面漫游」随当前形象的 `isMotionApplicable` 灰掉,
    /// 其余项交回 `super`(保留 NSWindow 内建校验)。`autoenablesItems` 默认 true → 菜单对每个
    /// target=self 的项调此方法。
    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === followingItem || menuItem === roamingItem {
            return isMotionApplicable()
        }
        return super.validateMenuItem(menuItem)
    }

    @objc public func clearWeatherFromContextMenu(_ sender: Any?) {
        onClearWeather()
    }

    @objc public func shareScreenshotFromContextMenu(_ sender: Any?) {
        onShareScreenshot()
    }

    @objc public func forceConditionFromContextMenu(_ sender: Any?) {
        guard
            let item = sender as? NSMenuItem,
            let raw = item.representedObject as? String
        else { return }
        selectForcedCondition(raw)
    }

    /// 设置 force condition (UI check state + 通知 callback)。
    /// Test seam, 跟 MenuBarController.selectForcedCondition 同款模式。
    public func selectForcedCondition(_ raw: String) {
        currentForcedConditionRaw = raw
        for (key, item) in forcedConditionItems {
            item.state = (key == raw) ? .on : .off
        }
        onForceConditionSelected(raw)
    }

    /// 由 caller (DesktopShellController.setMenuCallbacks) 启动时把 UserDefaults
    /// 持久化的 force condition raw 同步到 submenu check state, 不触发 callback。
    public func syncForcedConditionState(_ raw: String) {
        guard forcedConditionItems[raw] != nil else { return }
        currentForcedConditionRaw = raw
        for (key, item) in forcedConditionItems {
            item.state = (key == raw) ? .on : .off
        }
    }

    /// 装饰宠精简右键菜单:设为主宠 / 设置 / 退出。主宠用全功能菜单(installContextMenu)。
    /// 装饰宠不持 chat/天气/跟随等主宠专属动作(那些 callback 在装饰宠上是空闭包,放进去只会是死项)。
    private func installDecorativeContextMenu() {
        let menu = NSMenu()
        let setPrimary = NSMenuItem(
            title: "设为主宠",
            action: #selector(setAsPrimaryFromContextMenu(_:)),
            keyEquivalent: "")
        setPrimary.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        setPrimary.target = self
        menu.addItem(setPrimary)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "设置...",
            action: #selector(settingsFromContextMenu(_:)),
            keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitFromContextMenu(_:)),
            keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self   // 追踪右键菜单开关 → 开着时冻结 pet
        self.menu = menu
        contentView?.menu = menu
    }

    private func installContextMenu() {
        if usesDecorativeMenu {
            installDecorativeContextMenu()
            return
        }
        let menu = NSMenu()

        // 主要交流入口 — Task C 改 QuickAsk 后由屏幕中央毛玻璃浮窗替代头顶气泡。
        // (兼容旧测试: 保留 "显示聊天" 别名作为隐藏菜单项)
        let chatItem = NSMenuItem(
            title: "显示聊天",
            action: #selector(showChatFromContextMenu(_:)),
            keyEquivalent: " "
        )
        chatItem.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: nil)
        chatItem.keyEquivalentModifierMask = [.command, .shift]
        chatItem.target = self
        menu.addItem(chatItem)

        let screenshotItem = NSMenuItem(
            title: "截图分享",
            action: #selector(shareScreenshotFromContextMenu(_:)),
            keyEquivalent: ""
        )
        screenshotItem.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)
        screenshotItem.target = self
        menu.addItem(screenshotItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "设置...",
            action: #selector(settingsFromContextMenu(_:)),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // 空间行为开关(跟菜单栏同款):跟随光标 + 桌面漫游(漫步 + 爬墙),互相独立。
        let following = NSMenuItem(
            title: "跟随光标",
            action: #selector(toggleFollowingFromContextMenu(_:)),
            keyEquivalent: ""
        )
        following.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: nil)
        following.target = self
        following.state = isFollowingEnabled ? .on : .off
        menu.addItem(following)
        followingItem = following

        let roaming = NSMenuItem(
            title: "桌面漫游",
            action: #selector(toggleRoamingFromContextMenu(_:)),
            keyEquivalent: ""
        )
        roaming.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: nil)
        roaming.target = self
        roaming.state = isRoamingEnabled ? .on : .off
        menu.addItem(roaming)
        roamingItem = roaming

        // 物理沙盒手动开关 — Weather wire 后默认按真实天气自动控制, 此项作为
        // 强制 override (覆盖天气, 跟 Settings → 天气 → 强制天气 / 菜单栏 ❄
        // 天气 submenu 同款 6 个选项)。
        //
        // (兼容旧测试: 保留 "下雪" 别名作为隐藏菜单项 — 旧测试搜
        // `$0.title == "下雪"` 仍能找到, 走 requestSnowToggleFromContextMenu
        // 路径)。
        let snowAlias = NSMenuItem(
            title: "下雪",
            action: #selector(requestSnowToggleFromContextMenu(_:)),
            keyEquivalent: ""
        )
        snowAlias.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)
        snowAlias.target = self
        snowAlias.isHidden = true  // 隐藏 alias, 不在 menu UI 显示, 仅供测试 lookup
        menu.addItem(snowAlias)

        // "天气 →" submenu — 7 个天气模式单选 (off/auto/sunny/cloudy/rainy/snowy/windy)
        // + 「立即清除积雪」。off = 关闭天气效果(取代旧总开关)。跟菜单栏 ❄ 天气 submenu 同构。
        let weatherItem = NSMenuItem(title: "天气", action: nil, keyEquivalent: "")
        weatherItem.image = NSImage(systemSymbolName: "cloud.sun.fill", accessibilityDescription: nil)
        let weatherSubmenu = NSMenu()

        for option in Self.forcedConditionOptions {
            let item = NSMenuItem(
                title: option.displayName,
                action: #selector(forceConditionFromContextMenu(_:)),
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
        let clearItem = NSMenuItem(
            title: "立即清除积雪",
            action: #selector(clearWeatherFromContextMenu(_:)),
            keyEquivalent: ""
        )
        clearItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        clearItem.target = self
        weatherSubmenu.addItem(clearItem)
        weatherItem.submenu = weatherSubmenu
        menu.addItem(weatherItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitFromContextMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self   // 追踪右键菜单开关 → 开着时冻结 pet
        self.menu = menu
        contentView?.menu = menu
    }
}

// MARK: - 右键菜单开关追踪(给「交互时冻结 pet」)

extension PetShellWindow: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {
        isContextMenuOpen = true
    }

    public func menuDidClose(_ menu: NSMenu) {
        isContextMenuOpen = false
    }
}
