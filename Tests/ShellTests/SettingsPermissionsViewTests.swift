import Testing
@testable import Shell

// MARK: - PermissionBadge 纯映射测试(无头,不需要 viewModel)

@Test("状态 → 徽章文案 + 是否显示动作按钮")
func permissionBadgeMapping() {
    // granted:打勾、无按钮
    #expect(PermissionBadge.text(for: .granted) == "已授权")
    #expect(PermissionBadge.showsActionButton(for: .granted) == false)
    // notDetermined:未授权、显「授权」
    #expect(PermissionBadge.text(for: .notDetermined) == "未授权")
    #expect(PermissionBadge.showsActionButton(for: .notDetermined))
    #expect(PermissionBadge.actionTitle(for: .notDetermined) == "授权")
    // denied:未授权、显「打开系统设置」
    #expect(PermissionBadge.text(for: .denied) == "未授权")
    #expect(PermissionBadge.showsActionButton(for: .denied))
    #expect(PermissionBadge.actionTitle(for: .denied) == "打开系统设置")
    // reserved:未使用、无按钮
    #expect(PermissionBadge.text(for: .reserved) == "未使用")
    #expect(PermissionBadge.showsActionButton(for: .reserved) == false)
}

@Test("symbol 四态不为空")
func permissionBadgeSymbols() {
    for status in [PermissionStatus.granted, .denied, .notDetermined, .reserved] {
        let sym = PermissionBadge.symbol(for: status)
        #expect(!sym.isEmpty)
    }
}

// MARK: - SettingsViewModel 权限态测试

@MainActor
private func makeTestViewModel() -> SettingsViewModel {
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
        agentModeEnabled: false,
        agentEngineKind: "claudeCode",
        agentEngineCLIPath: nil,
        openClawStatusDescription: "",
        openClawAutoStart: false,
        openClawAllowEndpointEnable: false,
        aboutVersion: "test"
    )
}

@MainActor
@Test("refreshPermissions 把 probe 四态灌进 viewModel")
func viewModelRefreshPermissions() {
    let vm = makeTestViewModel()
    let probe = SystemPermissionProbe(
        accessibilityStatus: { .granted },
        screenRecordingStatus: { .denied },
        locationStatus: { .notDetermined }
    )
    vm.refreshPermissions(using: probe)
    #expect(vm.permissionStatuses[.accessibility] == .granted)
    #expect(vm.permissionStatuses[.screenRecording] == .denied)
    #expect(vm.permissionStatuses[.location] == .notDetermined)
    #expect(vm.permissionStatuses[.appleEvents] == .reserved)
}

@MainActor
@Test("refreshPermissions 初始 permissionStatuses 为空,调用后填充四项")
func viewModelPermissionStatusesInitiallyEmpty() {
    let vm = makeTestViewModel()
    #expect(vm.permissionStatuses.isEmpty)
    let probe = SystemPermissionProbe()
    vm.refreshPermissions(using: probe)
    #expect(vm.permissionStatuses.count == SystemPermission.allCases.count)
}

@MainActor
@Test("onRequestPermission / onRefreshPermissions 默认 no-op,可覆盖")
func viewModelPermissionCallbacksOverridable() {
    let vm = makeTestViewModel()
    var requested: SystemPermission?
    var refreshed = false
    vm.onRequestPermission = { requested = $0 }
    vm.onRefreshPermissions = { refreshed = true }

    vm.onRequestPermission(.accessibility)
    vm.onRefreshPermissions()

    #expect(requested == .accessibility)
    #expect(refreshed)
}
