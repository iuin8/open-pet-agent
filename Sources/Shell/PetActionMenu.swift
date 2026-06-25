import AppKit

/// 桌宠操作菜单的**单一 source of truth** —— 状态栏菜单(`MenuBarController`)与右键桌宠菜单
/// (`PetShellWindow`)都从此类产出同一份 NSMenu,保证两菜单内容、顺序、标题完全一致。
/// 以后加 / 删菜单项**只改这里一处**,两个 surface 自动同步,杜绝「只加一边漏另一边」。
///
/// 动作走**闭包回调**(各 surface 注入),状态(勾选 / 灰显 / 当前天气)经 `applyState` 外部同步;
/// 故本类与具体宿主解耦。装饰宠的精简菜单不走这里(`PetShellWindow.installDecorativeContextMenu`)。
@MainActor
public final class PetActionMenu: NSObject, NSMenuItemValidation {

    /// 各菜单动作的回调集 —— surface 注入,点击即调。
    public struct Callbacks {
        public var chat: () -> Void = {}
        public var screenshot: () -> Void = {}
        public var settings: () -> Void = {}
        /// toggle 点击后回调新值(surface 据此更新自身镜像态 + 触发真实动作)。
        public var toggleFollowing: (Bool) -> Void = { _ in }
        public var toggleRoaming: (Bool) -> Void = { _ in }
        public var selectForcedCondition: (String) -> Void = { _ in }
        public var clearWeather: () -> Void = {}
        public var quit: () -> Void = {}
        public init() {}
    }

    /// 菜单可变状态:勾选态 + 天气单选 + 「当前天气」展示 + 运动开关适用性(灰显)。
    public struct State {
        public var following = false
        public var roaming = true
        public var forcedConditionRaw = "auto"
        /// 「当前天气」展示行文案(disabled 信息行)。
        public var weatherCurrentText = "⏳ 等待首次刷新…"
        public init() {}
    }

    /// 7 个天气模式单选(off 在最前,auto 次之)—— 全仓唯一定义,状态栏 / 右键 / 设置面板顺序对齐。
    public static let forcedConditionOptions: [(raw: String, displayName: String, symbol: String)] = [
        ("off", "关闭天气效果", "xmark.circle"),
        ("auto", "自动 (跟随真实)", "arrow.triangle.2.circlepath"),
        ("sunny", "强制晴天", "sun.max.fill"),
        ("cloudy", "强制多云", "cloud.fill"),
        ("rainy", "强制下雨", "cloud.rain.fill"),
        ("snowy", "强制下雪", "cloud.snow.fill"),
        ("windy", "强制大风", "wind")
    ]

    public let menu = NSMenu()
    /// 跟随 / 漫游随当前形象灰显的 gate —— pull 式,`validateMenuItem` 每次菜单打开实时求值
    /// (换形象后无需推送、不 stale)。surface 注入。
    public var isMotionApplicable: () -> Bool = { true }

    /// 动作回调 —— surface 在 init 后注入(闭包需捕获 surface self)。
    public var callbacks: Callbacks
    private var state: State

    private var followingItem: NSMenuItem!
    private var roamingItem: NSMenuItem!
    private var forcedConditionItems: [String: NSMenuItem] = [:]
    private let weatherCurrentItem = NSMenuItem(title: "⏳ 等待首次刷新…", action: nil, keyEquivalent: "")

    public init(callbacks: Callbacks, state: State = State()) {
        self.callbacks = callbacks
        self.state = state
        super.init()
        build()
        applyState(state)
    }

    // MARK: - 构建(唯一菜单结构定义)

    private func build() {
        addAction("显示聊天", symbol: "bubble.left.and.bubble.right.fill", key: " ",
                  modifiers: [.command, .shift], action: #selector(handleChat))
        addAction("截图分享", symbol: "camera.fill", action: #selector(handleScreenshot))
        menu.addItem(.separator())
        addAction("设置...", symbol: "gearshape.fill", key: ",", action: #selector(handleSettings))
        menu.addItem(.separator())
        followingItem = addAction("跟随光标", symbol: "cursorarrow.rays", action: #selector(handleFollowing))
        roamingItem = addAction("桌面漫游", symbol: "figure.walk", action: #selector(handleRoaming))
        menu.addItem(.separator())
        menu.addItem(buildWeatherItem())
        menu.addItem(.separator())
        addAction("退出 OpenPetAgent", key: "q", action: #selector(handleQuit))
    }

    @discardableResult
    private func addAction(_ title: String, symbol: String? = nil, key: String = "",
                           modifiers: NSEvent.ModifierFlags? = nil, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let modifiers { item.keyEquivalentModifierMask = modifiers }
        item.target = self
        menu.addItem(item)
        return item
    }

    private func buildWeatherItem() -> NSMenuItem {
        let weatherItem = NSMenuItem(title: "天气", action: nil, keyEquivalent: "")
        weatherItem.image = NSImage(systemSymbolName: "cloud.sun.fill", accessibilityDescription: nil)
        let submenu = NSMenu()
        weatherCurrentItem.isEnabled = false
        submenu.addItem(weatherCurrentItem)
        submenu.addItem(.separator())
        for option in Self.forcedConditionOptions {
            let item = NSMenuItem(title: option.displayName, action: #selector(handleForcedCondition(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: option.symbol, accessibilityDescription: nil)
            item.target = self
            item.representedObject = option.raw
            submenu.addItem(item)
            forcedConditionItems[option.raw] = item
        }
        submenu.addItem(.separator())
        let clearItem = NSMenuItem(title: "立即清除积雪", action: #selector(handleClearWeather), keyEquivalent: "")
        clearItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        clearItem.target = self
        submenu.addItem(clearItem)
        weatherItem.submenu = submenu
        return weatherItem
    }

    // MARK: - 状态同步(外部驱动 check / 灰显 / 当前天气,不触发回调)

    public func applyState(_ newState: State) {
        state = newState
        followingItem?.state = newState.following ? .on : .off
        roamingItem?.state = newState.roaming ? .on : .off
        weatherCurrentItem.title = newState.weatherCurrentText
        for (raw, item) in forcedConditionItems {
            item.state = (raw == newState.forcedConditionRaw) ? .on : .off
        }
    }

    public func updateWeatherCurrent(_ text: String) {
        state.weatherCurrentText = text
        weatherCurrentItem.title = text
    }

    public func setForcedCondition(_ raw: String) {
        state.forcedConditionRaw = raw
        for (key, item) in forcedConditionItems { item.state = (key == raw) ? .on : .off }
    }

    // MARK: - 动作(target = self,转发闭包)

    @objc private func handleChat() { callbacks.chat() }
    @objc private func handleScreenshot() { callbacks.screenshot() }
    @objc private func handleSettings() { callbacks.settings() }
    @objc private func handleClearWeather() { callbacks.clearWeather() }
    @objc private func handleQuit() { callbacks.quit() }

    @objc private func handleFollowing() {
        state.following.toggle()
        followingItem.state = state.following ? .on : .off
        callbacks.toggleFollowing(state.following)
    }

    @objc private func handleRoaming() {
        state.roaming.toggle()
        roamingItem.state = state.roaming ? .on : .off
        callbacks.toggleRoaming(state.roaming)
    }

    @objc private func handleForcedCondition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        setForcedCondition(raw)
        callbacks.selectForcedCondition(raw)
    }

    /// 跟随 / 漫游随当前形象 `motionApplicable` 灰显;其余恒可用。
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === followingItem || menuItem === roamingItem { return isMotionApplicable() }
        return true
    }
}
