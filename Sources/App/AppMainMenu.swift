import AppKit

/// 全局主菜单工厂 —— 给「无菜单栏的 accessory app」补一层标准编辑快捷键地基。
///
/// **背景**：OpenPetAgent 走 `setActivationPolicy(.accessory)`（见
/// `PetAgentApp.launchReadyApp`），系统**不给它画顶部菜单栏**。而标准 Edit 菜单的
/// 「剪切/拷贝/粘贴/全选/撤销/重做」item 平时正是 ⌘X/C/V/A/Z 这套 keyEquivalent
/// 的路由载体。缺这套菜单 → 这些快捷键无处可达，所有窗口里的文本编辑都「快捷键失效」。
///
/// **本菜单的作用**：把这套标准 item 注入 `NSApp.mainMenu`，纯粹给全局 keyEquivalent
/// 一个兜底落点。即便菜单栏不可见，AppKit 仍会用 `mainMenu` 解析 ⌘+key 并沿 responder
/// chain 派发对应 selector，最终落到聚焦字段的 field editor（`NSText` 实现了全部四个
/// 编辑 selector）。
///
/// **与现有逐窗口补丁的关系**：AppKit 的 ⌘+key 路由顺序是「window.performKeyEquivalent
/// **先于** mainMenu」。所以 `ChatShellView` / `SettingsKeyForwardingWindow` 里现有的
/// `performKeyEquivalent` 补丁仍然先命中、零回归；本菜单只兜底那些**没写补丁的窗口**
/// （如 `ChatCardWindowController` 宿主的 `ChatCardComposer` 输入框）。两者互补，不冲突。
///
/// 所有 item 的 `target` 留 `nil` —— 走 responder chain 自动寻址，不绑定固定接收者。
@MainActor
enum AppMainMenu {

    /// 构建主菜单：第 1 项 App 菜单（含退出），第 2 项「编辑」菜单（标准编辑动作）。
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        return mainMenu
    }

    // MARK: - App 菜单

    /// App 菜单：目前只承载「退出 PetAgent」（⌘Q）。
    private static func makeAppMenuItem() -> NSMenuItem {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            makeItem(
                title: "退出 PetAgent",
                action: Selector(("terminate:")),
                keyEquivalent: "q",
                modifierMask: .command
            )
        )
        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    // MARK: - 编辑菜单

    /// 编辑菜单：撤销/重做 + 剪切/拷贝/粘贴 + 全选。承载 ⌘Z / ⇧⌘Z / ⌘X/C/V/A 路由。
    private static func makeEditMenuItem() -> NSMenuItem {
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")

        editMenu.addItem(
            makeItem(
                title: "撤销",
                action: Selector(("undo:")),
                keyEquivalent: "z",
                modifierMask: .command
            )
        )
        editMenu.addItem(
            makeItem(
                title: "重做",
                action: Selector(("redo:")),
                keyEquivalent: "z",
                modifierMask: [.command, .shift]
            )
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            makeItem(
                title: "剪切",
                action: #selector(NSText.cut(_:)),
                keyEquivalent: "x",
                modifierMask: .command
            )
        )
        editMenu.addItem(
            makeItem(
                title: "拷贝",
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c",
                modifierMask: .command
            )
        )
        editMenu.addItem(
            makeItem(
                title: "粘贴",
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v",
                modifierMask: .command
            )
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            makeItem(
                title: "全选",
                action: #selector(NSText.selectAll(_:)),
                keyEquivalent: "a",
                modifierMask: .command
            )
        )

        editMenuItem.submenu = editMenu
        return editMenuItem
    }

    // MARK: - Helper

    /// 造一个走 responder chain 的菜单项：`target = nil`，keyEquivalent 用小写字母，
    /// 显式设 `keyEquivalentModifierMask`（不靠 keyEquivalent 大小写隐式推断 shift）。
    private static func makeItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = nil
        item.keyEquivalentModifierMask = modifierMask
        return item
    }
}
