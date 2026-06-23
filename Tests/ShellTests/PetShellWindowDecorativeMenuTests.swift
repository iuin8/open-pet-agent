import AppKit
import Testing
@testable import Shell

/// 右键「设为主宠」特性:装饰宠用精简菜单(设为主宠 / 设置 / 退出),主宠用全功能菜单(无「设为主宠」)。
@MainActor
@Suite("PetShellWindow 装饰宠右键菜单")
struct PetShellWindowDecorativeMenuTests {
    private func makeWindow() -> PetShellWindow {
        let w = PetShellWindow(
            contentRect: NSRect(x: 0, y: 0, width: 90, height: 90),
            styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSView(frame: w.frame)
        return w
    }

    @Test("装饰菜单 = 设为主宠 / 设置 / 退出,不含主宠专属项(天气 / 聊天)")
    func decorativeMenuIsFocused() {
        let w = makeWindow()
        w.install(onMouseUp: { _, _ in }, onSetAsPrimary: {}, decorativeMenu: true)
        let titles = w.menu?.items.map(\.title) ?? []
        #expect(titles.contains("设为主宠"))
        #expect(titles.contains("设置..."))
        #expect(titles.contains("退出"))
        #expect(!titles.contains("天气"))
        #expect(!titles.contains("显示聊天"))
    }

    @Test("点「设为主宠」触发 onSetAsPrimary 回调")
    func setAsPrimaryFires() {
        let w = makeWindow()
        var fired = false
        w.install(onMouseUp: { _, _ in }, onSetAsPrimary: { fired = true }, decorativeMenu: true)
        w.setAsPrimaryFromContextMenu(nil)
        #expect(fired)
    }

    @Test("主宠全功能菜单不含「设为主宠」(只装饰宠可升主宠)")
    func fullMenuHasNoSetAsPrimary() {
        let w = makeWindow()
        w.install(onMouseUp: { _, _ in })   // decorativeMenu 默认 false → 全功能菜单
        let titles = w.menu?.items.map(\.title) ?? []
        #expect(!titles.contains("设为主宠"))
        #expect(titles.contains("天气"))   // 全功能菜单标志项仍在
    }
}
