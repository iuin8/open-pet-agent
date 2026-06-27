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

    /// 主宠右键菜单 —— 走共享的 `PetActionMenu`(与状态栏菜单同一份定义)。装饰宠走精简菜单不用它。
    private var actionMenu: PetActionMenu?

    /// 空间行为开关状态(跟随默认 off / 漫游默认 on,启动由 caller sync 校正)。check state 由 actionMenu 维护。
    private var isFollowingEnabled = false
    private var isRoamingEnabled = true
    /// 「当前天气」展示行文案(weather 更新时刷新;applyState 不清)。
    private var currentWeatherText = "⏳ 等待首次刷新…"

    /// 当前形象是否响应**「跟随光标」**开关 —— 由 caller(DesktopShellController)注入,读当前
    /// renderer 的 `driveModel.supportsHostDrivenMotion`。pull 式:右键菜单每次打开经 `validateMenuItem`
    /// 实时求值,换形象后无需推送、不会 stale。默认 `{ true }`(未注入时维持旧行为=恒可点)。
    public var isMotionApplicable: () -> Bool = { true }
    /// 当前形象是否响应**「桌面漫游」**开关 —— 独立闸,读 renderer 的 `supportsAutonomousRoaming`。
    /// 弹力球(Orb)等纯物理形象 → 漫游灰、跟随仍可用。默认 `{ true }`(未注入维持旧行为)。
    public var isRoamingApplicable: () -> Bool = { true }

    /// 右键上下文菜单是否正开着 —— 开着时 App「交互时冻结 pet」让 pet 停住,免漫步把菜单甩在身后
    /// (NSMenu 是原生菜单不跟随窗口,但帧循环 DispatchSourceTimer 队列驱动、不受菜单 tracking 暂停 →
    /// 菜单开着 pet 照样漫步;由 menu delegate 追踪开关态)。
    public private(set) var isContextMenuOpen = false

    /// 当前选中的 force condition raw, 默认 "auto"。install() 时按 caller
    /// 传入的 initialForcedConditionRaw 同步, 之后用户点击 sub-item 时更新。
    private var currentForcedConditionRaw: String = "auto"

    // 天气模式选项已收口到单一定义 `PetActionMenu.forcedConditionOptions`,本类不再重复一份。

    public func install(
        onMouseDown: @escaping @MainActor () -> Void = {},
        onMouseUp: @escaping @MainActor (NSPoint, Int) -> Void,
        onMouseDragged: @escaping @MainActor (NSPoint) -> Void = { _ in },
        onShowChat: @escaping @MainActor () -> Void = {},
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

    // 主宠右键菜单的动作都走共享 PetActionMenu 的闭包回调(见 installContextMenu),
    // 不再各自 @objc。装饰宠菜单仍用下面 quit/setAsPrimary/settings 的 @objc handler。
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

    /// 由 caller(DesktopShellController)把跟随/漫游状态同步到右键菜单 check state,
    /// 不触发 callback(跨入口一致)。check state 由 actionMenu 维护(跟随/漫游灰显走其 validateMenuItem)。
    public func syncSpatialBehavior(following: Bool, roaming: Bool) {
        isFollowingEnabled = following
        isRoamingEnabled = roaming
        actionMenu?.applyState(following: following, roaming: roaming,
                               forcedConditionRaw: currentForcedConditionRaw, weatherCurrentText: currentWeatherText)
    }

    /// 设置 force condition (UI check state + 通知 callback)。
    /// Test seam, 跟 MenuBarController.selectForcedCondition 同款模式。
    public func selectForcedCondition(_ raw: String) {
        currentForcedConditionRaw = raw
        actionMenu?.setForcedCondition(raw)
        onForceConditionSelected(raw)
    }

    /// 由 caller (DesktopShellController.setMenuCallbacks) 启动时把 UserDefaults
    /// 持久化的 force condition raw 同步到 submenu check state, 不触发 callback。
    public func syncForcedConditionState(_ raw: String) {
        currentForcedConditionRaw = raw
        actionMenu?.setForcedCondition(raw)
    }

    /// 更新右键菜单天气 submenu 内「当前天气」展示行(与状态栏同步,weather 更新时调)。
    public func updateWeatherCurrent(_ description: String) {
        currentWeatherText = description
        actionMenu?.updateWeatherCurrent(description)
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
        // 主宠右键菜单走共享 PetActionMenu(与状态栏菜单同一份定义,加项只改 PetActionMenu 一处)。
        var cb = PetActionMenu.Callbacks()
        cb.chat = { [weak self] in self?.onShowChat() }
        cb.screenshot = { [weak self] in self?.onShareScreenshot() }
        cb.settings = { [weak self] in self?.onSettings() }
        cb.toggleFollowing = { [weak self] on in self?.isFollowingEnabled = on; self?.onToggleFollowing(on) }
        cb.toggleRoaming = { [weak self] on in self?.isRoamingEnabled = on; self?.onToggleRoaming(on) }
        cb.selectForcedCondition = { [weak self] raw in self?.currentForcedConditionRaw = raw; self?.onForceConditionSelected(raw) }
        cb.clearWeather = { [weak self] in self?.onClearWeather() }
        cb.quit = { [weak self] in self?.onQuit() }

        var state = PetActionMenu.State()
        state.following = isFollowingEnabled
        state.roaming = isRoamingEnabled
        state.forcedConditionRaw = currentForcedConditionRaw
        state.weatherCurrentText = currentWeatherText
        let action = PetActionMenu(callbacks: cb, state: state)
        action.isMotionApplicable = { [weak self] in self?.isMotionApplicable() ?? true }
        action.isRoamingApplicable = { [weak self] in self?.isRoamingApplicable() ?? true }
        action.menu.delegate = self   // 追踪右键菜单开关 → 开着时冻结 pet
        actionMenu = action
        self.menu = action.menu
        contentView?.menu = action.menu
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
