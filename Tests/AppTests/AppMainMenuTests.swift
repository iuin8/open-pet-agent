import AppKit
import Testing
@testable import App

/// `AppMainMenu.make()` 结构单测 —— 验证全局兜底编辑菜单的 selector / keyEquivalent /
/// modifier 都按标准 NSText 编辑动作接好。只检查 `make()` 返回的菜单结构,**不启动
/// NSApplication**,避免触碰共享 NSApp / run loop。
@MainActor
struct AppMainMenuTests {

    /// 取「编辑」submenu(主菜单第 2 项的 submenu)。找不到则返回 nil。
    private func editMenu() -> NSMenu? {
        AppMainMenu.make().items.dropFirst().first?.submenu
    }

    /// 在编辑菜单里按 action selector 找 item。
    private func item(action: Selector) -> NSMenuItem? {
        editMenu()?.items.first { $0.action == action }
    }

    @Test("make() 含一个非空的「编辑」submenu")
    func makeContainsEditSubmenu() {
        let edit = editMenu()
        #expect(edit != nil)
        #expect(edit?.title == "编辑")
        #expect((edit?.items.isEmpty ?? true) == false)
    }

    @Test("剪切 item = NSText.cut(_:) / ⌘X")
    func cutItemMapsToNSTextCut() {
        let cut = item(action: #selector(NSText.cut(_:)))
        #expect(cut != nil)
        #expect(cut?.keyEquivalent == "x")
        #expect(cut?.keyEquivalentModifierMask.contains(.command) == true)
    }

    @Test("拷贝 item = NSText.copy(_:) / ⌘C")
    func copyItemMapsToNSTextCopy() {
        let copy = item(action: #selector(NSText.copy(_:)))
        #expect(copy != nil)
        #expect(copy?.keyEquivalent == "c")
        #expect(copy?.keyEquivalentModifierMask.contains(.command) == true)
    }

    @Test("粘贴 item = NSText.paste(_:) / ⌘V")
    func pasteItemMapsToNSTextPaste() {
        let paste = item(action: #selector(NSText.paste(_:)))
        #expect(paste != nil)
        #expect(paste?.keyEquivalent == "v")
        #expect(paste?.keyEquivalentModifierMask.contains(.command) == true)
    }

    @Test("全选 item = NSText.selectAll(_:) / ⌘A")
    func selectAllItemMapsToNSTextSelectAll() {
        let selectAll = item(action: #selector(NSText.selectAll(_:)))
        #expect(selectAll != nil)
        #expect(selectAll?.keyEquivalent == "a")
        #expect(selectAll?.keyEquivalentModifierMask.contains(.command) == true)
    }

    @Test("撤销 item selector 名为 undo: / ⌘Z,不含 shift")
    func undoItemMapsToUndoSelector() {
        let undo = item(action: Selector(("undo:")))
        #expect(undo != nil)
        #expect(undo?.keyEquivalent == "z")
        #expect(undo?.keyEquivalentModifierMask.contains(.command) == true)
        #expect(undo?.keyEquivalentModifierMask.contains(.shift) == false)
    }

    @Test("重做 item selector 名为 redo: / ⇧⌘Z")
    func redoItemMapsToRedoSelector() {
        let redo = item(action: Selector(("redo:")))
        #expect(redo != nil)
        #expect(redo?.keyEquivalent == "z")
        #expect(redo?.keyEquivalentModifierMask.contains(.command) == true)
        #expect(redo?.keyEquivalentModifierMask.contains(.shift) == true)
    }
}
