import AppKit
import Testing
@testable import Shell

/// 直接针对单一 source of truth `PetActionMenu` 的单测(不经 surface 装配)。
@MainActor
@Suite("PetActionMenu")
struct PetActionMenuTests {
    private func makeMenu(_ configure: (inout PetActionMenu.Callbacks) -> Void = { _ in },
                          state: PetActionMenu.State = PetActionMenu.State()) -> PetActionMenu {
        var cb = PetActionMenu.Callbacks()
        configure(&cb)
        return PetActionMenu(callbacks: cb, state: state)
    }

    private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }
    /// 经 item 的 target+action 派发(模拟用户点击)。
    private func invoke(_ menuItem: NSMenuItem?) {
        guard let menuItem, let action = menuItem.action else { return }
        _ = (menuItem.target as? NSObject)?.perform(action, with: menuItem)
    }

    @Test("build:顶层项顺序固定 + 天气 submenu 结构")
    func structure() throws {
        let menu = makeMenu().menu
        #expect(menu.items.map(\.title) == [
            "显示聊天", "截图分享", "", "设置...", "", "跟随光标", "桌面漫游", "", "天气", "", "退出 OpenPetAgent"
        ])
        let weather = try #require(item(menu, "天气")?.submenu)
        let titles = weather.items.map(\.title)
        #expect(titles.first == "⏳ 等待首次刷新…")   // 当前天气展示行
        #expect(titles.contains("关闭天气效果"))
        #expect(titles.contains("强制下雪"))
        #expect(titles.contains("立即清除积雪"))
    }

    @Test("点击跟随 toggle:翻转 state + check + 回调新值")
    func toggleFollowing() throws {
        var captured: [Bool] = []
        let pm = makeMenu({ $0.toggleFollowing = { captured.append($0) } })
        let following = try #require(item(pm.menu, "跟随光标"))
        #expect(following.state == .off)   // 默认 off
        invoke(following)
        #expect(following.state == .on)
        #expect(captured == [true])
        invoke(following)
        #expect(following.state == .off)
        #expect(captured == [true, false])
    }

    @Test("天气单选:点一项 → 该项 on 其余 off(互斥)+ 回调 raw")
    func weatherSingleSelect() throws {
        var captured: [String] = []
        let pm = makeMenu({ $0.selectForcedCondition = { captured.append($0) } })
        let weather = try #require(item(pm.menu, "天气")?.submenu)
        invoke(weather.items.first { $0.title == "强制下雪" })
        #expect(captured == ["snowy"])
        #expect(weather.items.filter { $0.state == .on }.map(\.title) == ["强制下雪"])
        invoke(weather.items.first { $0.title == "强制晴天" })
        #expect(captured == ["snowy", "sunny"])
        #expect(weather.items.filter { $0.state == .on }.map(\.title) == ["强制晴天"])
    }

    @Test("applyState:同步 check + 当前天气行,不触发回调")
    func applyStateSyncsWithoutCallback() throws {
        var followingFired = false
        let pm = makeMenu({ $0.toggleFollowing = { _ in followingFired = true } })
        pm.applyState(following: true, roaming: false, forcedConditionRaw: "rainy", weatherCurrentText: "🌧️ 10°C")
        #expect(item(pm.menu, "跟随光标")?.state == .on)
        #expect(item(pm.menu, "桌面漫游")?.state == .off)
        let weather = try #require(item(pm.menu, "天气")?.submenu)
        #expect(weather.items.filter { $0.state == .on }.map(\.title) == ["强制下雨"])
        #expect(weather.items.first?.title == "🌧️ 10°C")
        #expect(followingFired == false)   // applyState 是外部同步,不回调
    }

    @Test("updateWeatherCurrent:只改当前天气展示行")
    func updateWeatherCurrent() throws {
        let pm = makeMenu()
        pm.updateWeatherCurrent("☀️ 25°C")
        let weather = try #require(item(pm.menu, "天气")?.submenu)
        #expect(weather.items.first?.title == "☀️ 25°C")
    }

    @Test("validateMenuItem:跟随/漫游随 isMotionApplicable 灰显,其余恒 true")
    func motionGate() throws {
        let pm = makeMenu()
        pm.isMotionApplicable = { false }
        let following = try #require(item(pm.menu, "跟随光标"))
        let roaming = try #require(item(pm.menu, "桌面漫游"))
        let chat = try #require(item(pm.menu, "显示聊天"))
        #expect(pm.validateMenuItem(following) == false)
        #expect(pm.validateMenuItem(roaming) == false)
        #expect(pm.validateMenuItem(chat) == true)
        pm.isMotionApplicable = { true }
        #expect(pm.validateMenuItem(following) == true)
    }

    @Test("chat/screenshot/settings/清雪/quit 动作各自转发回调")
    func plainActionsForward() throws {
        var hits: [String] = []
        let pm = makeMenu({
            $0.chat = { hits.append("chat") }
            $0.screenshot = { hits.append("shot") }
            $0.settings = { hits.append("settings") }
            $0.clearWeather = { hits.append("clear") }
            $0.quit = { hits.append("quit") }
        })
        invoke(item(pm.menu, "显示聊天"))
        invoke(item(pm.menu, "截图分享"))
        invoke(item(pm.menu, "设置..."))
        let weather = try #require(item(pm.menu, "天气")?.submenu)
        invoke(weather.items.first { $0.title == "立即清除积雪" })
        invoke(item(pm.menu, "退出 OpenPetAgent"))
        #expect(hits == ["chat", "shot", "settings", "clear", "quit"])
    }
}
