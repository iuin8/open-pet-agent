import AppKit
import Testing
import Rendering
@testable import Shell

@Test("Menu bar controller exposes a following toggle menu item")
@MainActor
func menuBarControllerExposesFollowingToggleMenuItem() {
    let controller = MenuBarController()

    let titles = controller.menuForTesting.items.map(\.title)
    #expect(titles.contains("跟随光标"))
}

@Test("Menu bar controller defaults the following toggle to off")
@MainActor
func menuBarControllerDefaultsFollowingToggleToOff() throws {
    let controller = MenuBarController()

    #expect(controller.isFollowingEnabled == false)
    let followingItem = try #require(controller.menuForTesting.items.first(where: { $0.title == "跟随光标" }))
    #expect(followingItem.state == .off)
}

@Test("Menu bar controller honors initial following enabled override")
@MainActor
func menuBarControllerHonorsInitialFollowingEnabledOverride() throws {
    let controller = MenuBarController(initialFollowingEnabled: true)

    #expect(controller.isFollowingEnabled)
    let followingItem = try #require(controller.menuForTesting.items.first(where: { $0.title == "跟随光标" }))
    #expect(followingItem.state == .on)
}

@Test("Menu bar controller toggles following state on menu click")
@MainActor
func menuBarControllerTogglesFollowingStateOnMenuClick() throws {
    let controller = MenuBarController()
    var observedStates: [Bool] = []
    controller.onToggleFollowing = { enabled in
        observedStates.append(enabled)
    }
    let followingItem = try #require(controller.menuForTesting.items.first(where: { $0.title == "跟随光标" }))
    let action = try #require(followingItem.action)

    _ = (followingItem.target as? NSObject)?.perform(action, with: followingItem)

    #expect(controller.isFollowingEnabled)
    #expect(followingItem.state == .on)
    #expect(observedStates == [true])

    _ = (followingItem.target as? NSObject)?.perform(action, with: followingItem)

    #expect(controller.isFollowingEnabled == false)
    #expect(followingItem.state == .off)
    #expect(observedStates == [true, false])
}

@Test("菜单含「桌面漫游」项,默认开(自由漫步基线)")
@MainActor
func menuBarExposesRoamingToggleDefaultOn() throws {
    let controller = MenuBarController()
    #expect(controller.isRoamingEnabled)
    let item = try #require(controller.menuForTesting.items.first(where: { $0.title == "桌面漫游" }))
    #expect(item.state == .on)
}

@Test("「桌面漫游」点击 toggle 状态 + 触发 onToggleRoaming")
@MainActor
func menuBarRoamingToggleFiresCallback() throws {
    let controller = MenuBarController()
    var observed: [Bool] = []
    controller.onToggleRoaming = { observed.append($0) }
    let item = try #require(controller.menuForTesting.items.first(where: { $0.title == "桌面漫游" }))
    let action = try #require(item.action)

    _ = (item.target as? NSObject)?.perform(action, with: item)

    #expect(controller.isRoamingEnabled == false)   // 默认 on → 点一下变 off
    #expect(item.state == .off)
    #expect(observed == [false])
}

@Test("跟随默认关、漫游默认开 —— 两开关独立")
@MainActor
func menuBarFollowingOffRoamingOnByDefault() {
    let controller = MenuBarController()
    #expect(controller.isFollowingEnabled == false)
    #expect(controller.isRoamingEnabled == true)
}

@Test("感知/权限应答/交互冻结 已迁到 设置 → 系统,菜单不再含这 3 项(保持精简一致)")
@MainActor
func menuBarNoLongerExposesMigratedToggles() {
    let controller = MenuBarController()
    let titles = controller.menuForTesting.items.map(\.title)
    #expect(titles.contains("感知编码会话 (Claude Code / Codex)") == false)
    #expect(titles.contains("在卡片上回答权限/问题") == false)
    #expect(titles.contains("交互时冻结 pet (卡片/右键菜单/悬停)") == false)
}

@Test("温度模式已迁移到设置 → 天气，菜单不再含温度模式入口")
@MainActor
func menuBarControllerNoLongerExposesThermalModes() throws {
    let controller = MenuBarController()
    let titles = controller.menuForTesting.items.map(\.title)
    #expect(titles.contains("温度模式") == false)
    for mode in ThermalOverrideMode.allCases where mode != .auto {
        #expect(titles.contains(mode.displayName) == false)
    }
}

@Test("Menu bar controller exposes a quit menu item that invokes the quit handler")
@MainActor
func menuBarControllerExposesQuitMenuItemThatInvokesTheQuitHandler() throws {
    let controller = MenuBarController()
    var quitCount = 0
    controller.onQuit = {
        quitCount += 1
    }
    let quitItem = try #require(controller.menuForTesting.items.first(where: { $0.title == "退出 OpenPetAgent" }))
    let action = try #require(quitItem.action)

    _ = (quitItem.target as? NSObject)?.perform(action, with: quitItem)

    #expect(quitCount == 1)
}

@Test("Menu bar controller exposes a settings menu item")
@MainActor
func menuBarControllerExposesSettingsMenuItem() {
    let controller = MenuBarController()

    let titles = controller.menuForTesting.items.map(\.title)
    #expect(titles.contains("设置..."))
}

@Test("Menu bar controller settings item fires the onSettings closure")
@MainActor
func menuBarControllerSettingsItemFiresOnSettingsClosure() throws {
    let controller = MenuBarController()
    var settingsCount = 0
    controller.onSettings = { settingsCount += 1 }

    let settingsItem = try #require(controller.menuForTesting.items.first(where: { $0.title == "设置..." }))
    let action = try #require(settingsItem.action)

    _ = (settingsItem.target as? NSObject)?.perform(action, with: settingsItem)

    #expect(settingsCount == 1)
}

@Test("Menu bar controller settings item appears before quit item in the menu")
@MainActor
func menuBarControllerSettingsItemAppearsBeforeQuit() throws {
    let controller = MenuBarController()
    let items = controller.menuForTesting.items

    let settingsIndex = try #require(items.firstIndex(where: { $0.title == "设置..." }))
    let quitIndex = try #require(items.firstIndex(where: { $0.title == "退出 OpenPetAgent" }))

    #expect(settingsIndex < quitIndex)
}

@Test("Menu bar controller settings item does not fire when onSettings is not set")
@MainActor
func menuBarControllerSettingsItemNoOpWhenNoHandler() throws {
    // Default onSettings is a no-op, invoking it should not crash.
    let controller = MenuBarController()
    let settingsItem = try #require(controller.menuForTesting.items.first(where: { $0.title == "设置..." }))
    let action = try #require(settingsItem.action)

    // Should not throw or crash.
    _ = (settingsItem.target as? NSObject)?.perform(action, with: settingsItem)
}

@Test("Menu bar controller exposes a screenshot share menu item")
@MainActor
func menuBarControllerExposesScreenshotShareMenuItem() {
    let controller = MenuBarController()

    let titles = controller.menuForTesting.items.map(\.title)
    #expect(titles.contains("截图分享"))
}

@Test("Menu bar controller screenshot item fires the onShareScreenshot closure")
@MainActor
func menuBarControllerScreenshotItemFiresOnShareScreenshotClosure() throws {
    let controller = MenuBarController()
    var shareCount = 0
    controller.onShareScreenshot = { shareCount += 1 }

    let shareItem = try #require(controller.menuForTesting.items.first(where: { $0.title == "截图分享" }))
    let action = try #require(shareItem.action)

    _ = (shareItem.target as? NSObject)?.perform(action, with: shareItem)

    #expect(shareCount == 1)
}

// MARK: - 天气模式统一单选(off + auto + 5 条件合并进单一「天气」submenu)

@MainActor
private func weatherSubmenuItems(_ controller: MenuBarController) throws -> [NSMenuItem] {
    let weather = try #require(controller.menuForTesting.items.first(where: { $0.title == "天气" }))
    let submenu = try #require(weather.submenu)
    return submenu.items
}

@Test("天气 submenu 含统一单选(关闭天气效果 + auto + 5 条件)+ 立即清除积雪")
@MainActor
func menuBarWeatherSubmenuHasUnifiedModeRadioAndClear() throws {
    let controller = MenuBarController()
    let titles = try weatherSubmenuItems(controller).map(\.title)
    #expect(titles.contains("关闭天气效果"))
    for t in ["自动 (跟随真实)", "强制晴天", "强制多云", "强制下雨", "强制下雪", "强制大风"] {
        #expect(titles.contains(t))
    }
    #expect(titles.contains("立即清除积雪"))
}

@Test("旧的独立「天气效果」子菜单 + 「显示天气效果」总开关已废弃")
@MainActor
func menuBarNoLongerHasSeparateWeatherEffectsSubmenu() throws {
    let controller = MenuBarController()
    let topTitles = controller.menuForTesting.items.map(\.title)
    #expect(topTitles.contains("天气效果") == false)
    let weatherTitles = try weatherSubmenuItems(controller).map(\.title)
    #expect(weatherTitles.contains("显示天气效果") == false)
}

@Test("选「关闭天气效果」→ onSelectForcedCondition(\"off\")")
@MainActor
func menuBarSelectingOffFiresOffMode() throws {
    let controller = MenuBarController()
    var observed: [String] = []
    controller.onSelectForcedCondition = { observed.append($0) }
    let offItem = try #require(try weatherSubmenuItems(controller).first(where: { $0.title == "关闭天气效果" }))
    let action = try #require(offItem.action)

    _ = (offItem.target as? NSObject)?.perform(action, with: offItem)

    #expect(observed == ["off"])
    #expect(offItem.state == .on)
}

@Test("选「强制下雪」→ onSelectForcedCondition(\"snowy\") + 单选互斥(off 取消勾选)")
@MainActor
func menuBarSelectingSnowyIsMutuallyExclusiveWithOff() throws {
    let controller = MenuBarController()
    let items = try weatherSubmenuItems(controller)
    let offItem = try #require(items.first(where: { $0.title == "关闭天气效果" }))
    let snowyItem = try #require(items.first(where: { $0.title == "强制下雪" }))
    var observed: [String] = []
    controller.onSelectForcedCondition = { observed.append($0) }

    _ = (offItem.target as? NSObject)?.perform(try #require(offItem.action), with: offItem)
    _ = (snowyItem.target as? NSObject)?.perform(try #require(snowyItem.action), with: snowyItem)

    #expect(observed == ["off", "snowy"])
    #expect(snowyItem.state == .on)
    #expect(offItem.state == .off)   // 单选互斥
}

@Test("立即清除积雪 fires onClearWeather")
@MainActor
func menuBarClearWeatherFires() throws {
    let controller = MenuBarController()
    var clearCount = 0
    controller.onClearWeather = { clearCount += 1 }
    let clearItem = try #require(try weatherSubmenuItems(controller).first(where: { $0.title == "立即清除积雪" }))

    _ = (clearItem.target as? NSObject)?.perform(try #require(clearItem.action), with: clearItem)

    #expect(clearCount == 1)
}

// MARK: - 跟随/漫游按形象灰掉(仅程序化形象 Orb/Slime 生效)

@Test("supportsHostDrivenMotion: 仅 proceduralMotion 为真")
func petDriveModelHostMotionApplicability() {
    #expect(PetDriveModel.proceduralMotion.supportsHostDrivenMotion)
    #expect(PetDriveModel.autonomousEngine.supportsHostDrivenMotion == false)
    #expect(PetDriveModel.activityStateIndicator.supportsHostDrivenMotion == false)
    #expect(PetDriveModel.selfAnimating.supportsHostDrivenMotion == false)
}

@Test("isMotionApplicable=false → 跟随/漫游灰掉,其余项不受影响")
@MainActor
func menuBarMotionTogglesGreyedWhenInapplicable() throws {
    let controller = MenuBarController()
    controller.isMotionApplicable = { false }
    let items = controller.menuForTesting.items
    let following = try #require(items.first(where: { $0.title == "跟随光标" }))
    let roaming = try #require(items.first(where: { $0.title == "桌面漫游" }))
    let settings = try #require(items.first(where: { $0.title == "设置..." }))

    #expect(controller.validateMenuItem(following) == false)
    #expect(controller.validateMenuItem(roaming) == false)
    #expect(controller.validateMenuItem(settings))   // 非运动项恒可用
}

@Test("isMotionApplicable=true(默认/程序化形象)→ 跟随/漫游可用")
@MainActor
func menuBarMotionTogglesEnabledWhenApplicable() throws {
    let controller = MenuBarController()
    controller.isMotionApplicable = { true }
    let items = controller.menuForTesting.items
    let following = try #require(items.first(where: { $0.title == "跟随光标" }))
    let roaming = try #require(items.first(where: { $0.title == "桌面漫游" }))

    #expect(controller.validateMenuItem(following))
    #expect(controller.validateMenuItem(roaming))
}
