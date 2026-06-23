import Testing
@testable import Shell

// MARK: - 辅助: 构建测试用 SettingsViewModel(与 SettingsPermissionsViewTests 同款)

@MainActor
private func makeWeatherTestViewModel() -> SettingsViewModel {
    SettingsViewModel(
        selectedProviderIndex: 0,
        apiKey: "",
        baseURL: "",
        model: "",
        availablePetPlugins: [],
        selectedPetPluginID: "",
        islandEnabled: false,
        notchAvailable: false,
        islandHidePetOnSwitch: false,
        toolModeEnabled: false,
        toolEngineKind: "claudeCode",
        toolEngineCLIPath: nil,
        openClawStatusDescription: "",
        openClawAutoStart: false,
        openClawAllowEndpointEnable: false,
        aboutVersion: "test"
    )
}

// MARK: - 自动跟随位置开关测试

@MainActor
@Test("autoFollowLocation 初始值为 false")
func autoFollowLocationDefaultsFalse() {
    let vm = makeWeatherTestViewModel()
    #expect(vm.autoFollowLocation == false)
}

@MainActor
@Test("自动跟随位置开关 toggle → 触发 onCommitAutoFollowLocation")
func autoFollowLocationToggle() {
    let vm = makeWeatherTestViewModel()
    var observed: [Bool] = []
    vm.onCommitAutoFollowLocation = { observed.append($0) }
    vm.autoFollowLocation = true
    // 模拟 .onChange 触发回调(UI 层 onChange 手动调用 onCommitAutoFollowLocation)
    vm.onCommitAutoFollowLocation(vm.autoFollowLocation)
    #expect(observed == [true])
}

@MainActor
@Test("autoFollowLocation 关闭时触发回调 false")
func autoFollowLocationToggleOff() {
    let vm = makeWeatherTestViewModel()
    var observed: [Bool] = []
    vm.onCommitAutoFollowLocation = { observed.append($0) }
    vm.autoFollowLocation = true
    vm.onCommitAutoFollowLocation(true)
    vm.autoFollowLocation = false
    vm.onCommitAutoFollowLocation(false)
    #expect(observed == [true, false])
}

@MainActor
@Test("onCommitAutoFollowLocation 默认为 no-op,不 crash")
func autoFollowLocationDefaultCallback() {
    let vm = makeWeatherTestViewModel()
    // 默认闭包什么都不做,调用不应 crash
    vm.onCommitAutoFollowLocation(true)
    vm.onCommitAutoFollowLocation(false)
}
