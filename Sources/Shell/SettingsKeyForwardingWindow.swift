import AppKit

/// `NSWindow` 子类,把 ⌘+key 编辑快捷键(Cmd-V / C / X / A / Z / Shift+Z)
/// 转发到 first responder 的标准 NSText 编辑 selector。
///
/// **为什么需要**:OpenPetAgent 是非典型 menu bar app —— 没有完整的 application
/// menu bar(`NSApp.mainMenu` 只有 ❄ 状态栏菜单,没 "Edit" 菜单项)。
/// 标准 NSApp menu 的"剪切/拷贝/粘贴/全选"item 平时承载 ⌘+key 路由,缺这套
/// menu 时 SwiftUI TextField / SecureField 收不到事件,看起来"快捷键失效"。
///
/// 重写 `performKeyEquivalent` 直接调 `NSApp.sendAction(_:to:from:)` 走
/// first responder chain → SwiftUI 内部包装的 NSTextField field editor 接住
/// 标准 selector(paste:/copy:/cut:/selectAll:/undo:/redo:)。
///
/// 复用 `SettingsContentView.editingSelector(for:)` 的 key event → selector
/// 解析(同一份逻辑,跟旧 AppKit 路径一致)。
@MainActor
final class SettingsKeyForwardingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘W = macOS 标准「关闭窗口」快捷键。本 app 无完整 application menu(只有状态栏菜单),
        // 缺标准 File→Close item 承载 ⌘W → 这里直接路由到 performClose(关窗,不回滚 —— 设置即时生效)。
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        if let selector = SettingsContentView.editingSelector(for: event),
           NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc = 关闭设置窗(标准面板行为;设置即时生效,无回滚)。first responder 是
    /// TextField 时 SwiftUI 先吃 Esc(清空/退出编辑),不会误关窗。
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}
