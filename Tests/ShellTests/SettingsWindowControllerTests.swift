import AppKit
import Orchestrator
import Rendering
import Testing
@testable import Shell

// MARK: - SettingsWindowController tests
// All tests are headless — they instantiate the controller and drive its
// public seams (closures, public properties) without ever presenting a
// real window on screen.

@Test("Settings window controller exposes an onSave closure property")
@MainActor
func settingsWindowControllerExposesOnSaveClosure() {
    var savedKey: String?
    let controller = SettingsWindowController()
    controller.onSave = { key in savedKey = key }

    controller.simulateSave(apiKey: "sk-test-123")

    #expect(savedKey == "sk-test-123")
}

@Test("handleSave 触发 onSavePetScale(PF6 大小持久化接线)")
@MainActor
func settingsWindowControllerFiresOnSavePetScale() {
    let controller = SettingsWindowController(petScale: 1.7)
    var savedScale: Double?
    controller.onSavePetScale = { savedScale = $0 }

    controller.simulateSave(apiKey: "sk-test")

    #expect(savedScale == 1.7)   // save 必须把当前 petScale 下发持久化(空白 API key 也照存)
}

@Test("Settings window controller passes trimmed API key text to onSave")
@MainActor
func settingsWindowControllerPassesTrimmedAPIKeyToOnSave() {
    var savedKey: String?
    let controller = SettingsWindowController()
    controller.onSave = { key in savedKey = key }

    controller.simulateSave(apiKey: "  sk-abc-456  ")

    #expect(savedKey == "sk-abc-456")
}

@Test(
    "Settings window controller does not fire onSave when API key is blank",
    arguments: ["", "   "]
)
@MainActor
func settingsWindowControllerDoesNotFireOnSaveForBlankKey(blank: String) {
    var saveCount = 0
    let controller = SettingsWindowController()
    controller.onSave = { _ in saveCount += 1 }

    controller.simulateSave(apiKey: blank)

    #expect(saveCount == 0)
}

@Test("Settings window controller pre-fills the API key field when initialised with an existing key")
@MainActor
func settingsWindowControllerPrefillsAPIKey() {
    let controller = SettingsWindowController(existingAPIKey: "sk-existing-789")

    #expect(controller.currentFieldText == "sk-existing-789")
}

@Test("Settings window controller starts with empty field when no key is provided")
@MainActor
func settingsWindowControllerStartsWithEmptyField() {
    let controller = SettingsWindowController()

    #expect(controller.currentFieldText == "")
}

@Test("Settings window controller window title is OpenPetAgent 设置")
@MainActor
func settingsWindowControllerWindowTitle() {
    let controller = SettingsWindowController()

    #expect(controller.windowTitle == "OpenPetAgent 设置")
}

// MARK: - A.1.2 — Base URL / Model field tests

@Test("Settings window controller base URL field has default placeholder")
@MainActor
func settingsWindowControllerBaseURLFieldHasPlaceholder() {
    let controller = SettingsWindowController()

    #expect(controller.baseURLFieldPlaceholder == "https://api.openai.com/v1")
}

@Test("Settings window controller model field has default placeholder")
@MainActor
func settingsWindowControllerModelFieldHasPlaceholder() {
    let controller = SettingsWindowController()

    #expect(controller.modelFieldPlaceholder == "gpt-4o-mini")
}

@Test("Settings window controller pre-fills base URL and model when given initial values")
@MainActor
func settingsWindowControllerPrefillsBaseURLAndModel() {
    let controller = SettingsWindowController(
        existingAPIKey: "sk-test",
        existingBaseURL: "https://api.deepseek.com/v1",
        existingModel: "deepseek-chat"
    )

    #expect(controller.currentBaseURLText == "https://api.deepseek.com/v1")
    #expect(controller.currentModelText == "deepseek-chat")
}

@Test("Settings window controller includes base URL and model in onSave callback")
@MainActor
func settingsWindowControllerIncludesBaseURLAndModelInOnSaveCallback() {
    var savedKey: String?
    var savedBaseURL: String?
    var savedModel: String?
    let controller = SettingsWindowController()
    controller.onSaveAll = { key, baseURL, model in
        savedKey = key
        savedBaseURL = baseURL
        savedModel = model
    }

    controller.simulateSaveAll(apiKey: "sk-test-key", baseURL: "https://api.groq.com/openai/v1", model: "llama3-8b-8192")

    #expect(savedKey == "sk-test-key")
    #expect(savedBaseURL == "https://api.groq.com/openai/v1")
    #expect(savedModel == "llama3-8b-8192")
}

@Test("Settings window controller passes empty base URL when field is whitespace only")
@MainActor
func settingsWindowControllerPassesEmptyBaseURLForWhitespace() {
    var savedBaseURL: String?
    let controller = SettingsWindowController()
    controller.onSaveAll = { _, baseURL, _ in
        savedBaseURL = baseURL
    }

    controller.simulateSaveAll(apiKey: "sk-key", baseURL: "   ", model: "gpt-4o-mini")

    // Empty/whitespace baseURL should be passed as empty string so caller can treat as "use default"
    #expect(savedBaseURL == "")
}

@Test("Settings window controller trims whitespace from base URL and model before saving")
@MainActor
func settingsWindowControllerTrimmsBaseURLAndModel() {
    var savedBaseURL: String?
    var savedModel: String?
    let controller = SettingsWindowController()
    controller.onSaveAll = { _, baseURL, model in
        savedBaseURL = baseURL
        savedModel = model
    }

    controller.simulateSaveAll(apiKey: "sk-key", baseURL: "  https://api.deepseek.com/v1  ", model: "  deepseek-chat  ")

    #expect(savedBaseURL == "https://api.deepseek.com/v1")
    #expect(savedModel == "deepseek-chat")
}

@Test("Settings window controller empty API key with non-empty base URL still fires onSaveAll")
@MainActor
func settingsWindowControllerEmptyAPIKeyWithBaseURLFiresOnSaveAll() {
    var callCount = 0
    let controller = SettingsWindowController()
    controller.onSaveAll = { _, _, _ in callCount += 1 }

    // An empty apiKey but valid baseURL (Ollama scenario) should still save
    controller.simulateSaveAll(apiKey: "", baseURL: "http://localhost:11434/v1", model: "llama3")

    #expect(callCount == 1)
}

@Test("Settings window controller starts base URL and model fields as empty when not provided")
@MainActor
func settingsWindowControllerStartsBaseURLAndModelFieldsEmpty() {
    let controller = SettingsWindowController()

    #expect(controller.currentBaseURLText == "")
    #expect(controller.currentModelText == "")
}

// MARK: - A.4 — Provider picker tests

@Test("Provider picker: selecting Anthropic changes API key label to 'Anthropic Key'")
@MainActor
func providerPickerSelectingAnthropicChangesKeyLabel() {
    let controller = SettingsWindowController(selectedProvider: "openAICompatible")

    controller.simulateSelectProvider("anthropic")

    #expect(controller.apiKeyLabelText == "Anthropic Key")
}

@Test("Provider picker: selecting OpenAI-compatible changes API key label to 'OpenAI Key'")
@MainActor
func providerPickerSelectingOpenAIChangesKeyLabel() {
    let controller = SettingsWindowController(selectedProvider: "anthropic")

    controller.simulateSelectProvider("openAICompatible")

    #expect(controller.apiKeyLabelText == "OpenAI Key")
}

@Test("Provider picker: Anthropic selected → base URL field stays visible (compat mode)")
@MainActor
func providerPickerAnthropicShowsBaseURLField() {
    let controller = SettingsWindowController(selectedProvider: "openAICompatible")

    controller.simulateSelectProvider("anthropic")

    // Anthropic also supports custom base URLs (proxy / self-hosted compat
    // servers), so the field stays visible with an Anthropic placeholder.
    #expect(controller.isBaseURLFieldVisible == true)
    #expect(controller.baseURLFieldPlaceholder == "https://api.anthropic.com")
}

@Test("Provider picker: switching back to OpenAI → base URL field is shown")
@MainActor
func providerPickerSwitchBackToOpenAIShowsBaseURLField() {
    let controller = SettingsWindowController(selectedProvider: "anthropic")

    controller.simulateSelectProvider("openAICompatible")

    #expect(controller.isBaseURLFieldVisible == true)
}

@Test("Provider picker: initialised with anthropic → index 1 is selected")
@MainActor
func providerPickerInitialisedWithAnthropicSelectsIndex1() {
    let controller = SettingsWindowController(selectedProvider: "anthropic")

    #expect(controller.selectedProviderIndex == 1)
}

@Test("Provider picker: save in anthropic mode fires onSaveProvider with 'anthropic'")
@MainActor
func providerPickerSaveFiresCorrectProviderString() {
    var capturedProvider: String?
    var capturedKey: String?
    let controller = SettingsWindowController(selectedProvider: "openAICompatible")
    controller.onSaveProvider = { provider, key, _, _ in
        capturedProvider = provider
        capturedKey = key
    }

    controller.simulateSaveProvider(provider: "anthropic", apiKey: "sk-ant-test", baseURL: "", model: "claude-sonnet-4-5")

    #expect(capturedProvider == "anthropic")
    #expect(capturedKey == "sk-ant-test")
}

@Test("Provider picker: save in openAICompatible mode fires onSaveProvider with 'openAICompatible'")
@MainActor
func providerPickerSaveOpenAIFiresCorrectProviderString() {
    var capturedProvider: String?
    let controller = SettingsWindowController(selectedProvider: "openAICompatible")
    controller.onSaveProvider = { provider, _, _, _ in
        capturedProvider = provider
    }

    controller.simulateSaveProvider(provider: "openAICompatible", apiKey: "sk-test", baseURL: "", model: "gpt-4o")

    #expect(capturedProvider == "openAICompatible")
}

// MARK: - N3.6 — Pet plugin picker tests

/// 测试用桌宠 plugin —— renderer 可为 nil(纯 UI 测试不需要真渲染)。
private enum FakeOrbPlugin: PetPlugin {
    static let identity = PetIdentity(
        id: "orb",
        displayName: "弹力球",
        recommendedSize: NSSize(width: 64, height: 64)
    )
    static func makeRenderer() -> PetRenderer? { nil }
}

private enum FakeSlimePlugin: PetPlugin {
    static let identity = PetIdentity(
        id: "slime",
        displayName: "史莱姆",
        recommendedSize: NSSize(width: 96, height: 96)
    )
    static func makeRenderer() -> PetRenderer? { nil }
}

/// 把类型式 fake plugin 包成注册表用的值类型 entry（registry 实参已切到 `[PetPluginEntry]`）。
private extension PetPlugin {
    static var fakeEntry: PetPluginEntry {
        PetPluginEntry(identity: identity, makeRenderer: { makeRenderer() })
    }
}

@Test("Pet plugin picker: populates popUp items with each plugin displayName in order")
@MainActor
func petPluginPickerPopulatesAllDisplayNames() {
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeSlimePlugin.fakeEntry],
        currentPetPluginID: "orb"
    )
    // popUp 内部不暴露 menu,通过 selectedPetPluginID + simulateSelectPetPlugin
    // 间接验证 displayName 与 id 关联正确。
    controller.simulateSelectPetPlugin("slime")
    #expect(controller.selectedPetPluginID == "slime")

    controller.simulateSelectPetPlugin("orb")
    #expect(controller.selectedPetPluginID == "orb")
}

@Test("Pet plugin picker: defaults selection to currentPetPluginID at init")
@MainActor
func petPluginPickerDefaultsToCurrentID() {
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeSlimePlugin.fakeEntry],
        currentPetPluginID: "slime"
    )

    #expect(controller.selectedPetPluginID == "slime")
}

@Test("Pet plugin picker: unknown currentPetPluginID falls back to first plugin in list")
@MainActor
func petPluginPickerUnknownCurrentFallsBackToFirstItem() {
    // 当前 id 不在 plugin 列表里时,NSPopUpButton 默认选中 index 0
    // → selectedPetPluginID 取第一个 plugin 的 id。
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeSlimePlugin.fakeEntry],
        currentPetPluginID: "unknown-xyz"
    )

    #expect(controller.selectedPetPluginID == "orb")
}

@Test("Pet plugin picker: simulateSave triggers onSavePlugin with selected id")
@MainActor
func petPluginPickerSaveFiresOnSavePluginCallback() {
    var capturedID: String?
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeSlimePlugin.fakeEntry],
        currentPetPluginID: "orb"
    )
    controller.onSavePlugin = { id in capturedID = id }

    controller.simulateSelectPetPlugin("slime")
    controller.simulateSave(apiKey: "sk-test")

    #expect(capturedID == "slime")
}

@Test("Pet plugin picker: onSavePlugin fires even when LLM key is empty (plugin-only save)")
@MainActor
func petPluginPickerOnlyPluginSaveFiresCallback() {
    var capturedID: String?
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeSlimePlugin.fakeEntry],
        currentPetPluginID: "orb"
    )
    controller.onSavePlugin = { id in capturedID = id }

    controller.simulateSelectPetPlugin("slime")
    // simulateSave 传入空 key —— LLM 部分 guard 不通过,但 plugin save 应触发
    controller.simulateSave(apiKey: "")

    #expect(capturedID == "slime")
}

@Test("Pet plugin picker: no plugins → onSavePlugin not fired")
@MainActor
func petPluginPickerNoPluginsDoesNotFireCallback() {
    var fireCount = 0
    let controller = SettingsWindowController()
    controller.onSavePlugin = { _ in fireCount += 1 }

    controller.simulateSave(apiKey: "sk-test")

    #expect(fireCount == 0)
}

@Test("Pet plugin picker: simulateSelectPetPlugin with unknown id is a no-op")
@MainActor
func petPluginPickerSelectUnknownIDNoOp() {
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeSlimePlugin.fakeEntry],
        currentPetPluginID: "orb"
    )

    controller.simulateSelectPetPlugin("does-not-exist")

    // 选择未变 —— 仍为初始的 orb
    #expect(controller.selectedPetPluginID == "orb")
}

// MARK: - N1.3 — 灵动岛 toggle UI 开关测试

@Test("Island toggle: 默认 init(无刘海 + islandEnabled 默认 true)→ toggle 禁用 + state=.off + 文案提示无刘海")
@MainActor
func islandToggleDefaultNoNotchDisabledAndOff() {
    // 默认参数:notchAvailable=false, islandEnabled=true。
    // 期望:即便 islandEnabled 是 true,因为没有刘海,toggle 也强制 off + 禁用。
    let controller = SettingsWindowController()

    #expect(controller.isIslandToggleEnabled == false)
    #expect(controller.isIslandToggleOn == false)
    #expect(controller.islandToggleTitle == "灵动岛(未检测到刘海)")
}

@Test("Island toggle: notchAvailable=true + islandEnabled=true → toggle 启用 + state=.on + 文案显示刘海可用")
@MainActor
func islandToggleNotchAvailableEnabledOn() {
    let controller = SettingsWindowController(
        islandEnabled: true,
        notchAvailable: true
    )

    #expect(controller.isIslandToggleEnabled == true)
    #expect(controller.isIslandToggleOn == true)
    #expect(controller.islandToggleTitle == "启用灵动岛(刘海机型)")
}

@Test("Island toggle: notchAvailable=true + islandEnabled=false → toggle 启用但 state=.off(用户先前关闭过)")
@MainActor
func islandToggleNotchAvailableButDisabledByUser() {
    let controller = SettingsWindowController(
        islandEnabled: false,
        notchAvailable: true
    )

    #expect(controller.isIslandToggleEnabled == true)
    #expect(controller.isIslandToggleOn == false)
    // 文案仍按"启用灵动岛(刘海机型)"(因为机型支持,只是用户关掉了)
    #expect(controller.islandToggleTitle == "启用灵动岛(刘海机型)")
}

@Test("Island toggle: simulateToggleIsland(true) + Save → onSaveIslandEnabled(true) 触发")
@MainActor
func islandToggleSaveFiresWithTrue() {
    var captured: Bool?
    let controller = SettingsWindowController(
        islandEnabled: false,
        notchAvailable: true
    )
    controller.onSaveIslandEnabled = { enabled in captured = enabled }

    controller.simulateToggleIsland(true)
    // 走 plugin-only save 路径,避免依赖 LLM key —— 不影响岛 callback
    controller.simulateSave(apiKey: "")

    #expect(captured == true)
}

@Test("Island toggle: simulateToggleIsland(false) + Save → onSaveIslandEnabled(false) 触发")
@MainActor
func islandToggleSaveFiresWithFalse() {
    var captured: Bool?
    let controller = SettingsWindowController(
        islandEnabled: true,
        notchAvailable: true
    )
    controller.onSaveIslandEnabled = { enabled in captured = enabled }

    controller.simulateToggleIsland(false)
    controller.simulateSave(apiKey: "")

    #expect(captured == false)
}

// MARK: - N2.3 Tool Mode toggle

@Test("Tool Mode toggle: 默认 init → 关闭")
@MainActor
func toolModeToggleDefaultOff() {
    let controller = SettingsWindowController()
    #expect(controller.isToolModeToggleOn == false)
}

@Test("Tool Mode toggle: toolModeEnabled=true 初始化 → toggle 勾选")
@MainActor
func toolModeToggleInitWithTrueIsOn() {
    let controller = SettingsWindowController(toolModeEnabled: true)
    #expect(controller.isToolModeToggleOn == true)
}

@Test("Tool Mode toggle: simulateToggleToolMode(true) + Save → onSaveToolModeEnabled(true) 触发")
@MainActor
func toolModeToggleSaveFiresWithTrue() {
    var captured: Bool?
    let controller = SettingsWindowController(toolModeEnabled: false)
    controller.onSaveToolModeEnabled = { enabled in captured = enabled }

    controller.simulateToggleToolMode(true)
    // 走 island toggle 同款 "无 LLM 输入" save 路径 —— Tool Mode callback
    // 跟 LLM 配置完全独立, 即便没填 key 也应该触发。
    controller.simulateSave(apiKey: "")

    #expect(captured == true)
}

@Test("Tool Mode toggle: simulateToggleToolMode(false) + Save → onSaveToolModeEnabled(false) 触发")
@MainActor
func toolModeToggleSaveFiresWithFalse() {
    var captured: Bool?
    let controller = SettingsWindowController(toolModeEnabled: true)
    controller.onSaveToolModeEnabled = { enabled in captured = enabled }

    controller.simulateToggleToolMode(false)
    controller.simulateSave(apiKey: "")

    #expect(captured == false)
}

// MARK: - Task E — OpenClaw 状态卡 + 系统 toggles + tool engine picker

@Test("Task E: OpenClaw status 默认文案 '⚪ 未启动' 在 init 时显示")
@MainActor
func openClawStatusDefaultDescription() {
    let controller = SettingsWindowController()
    #expect(controller.openClawStatusText == "⚪ 未启动")
}

@Test("Task E: openClawStatusDescription 初始化注入显示在 status label")
@MainActor
func openClawStatusInitialInjection() {
    let controller = SettingsWindowController(
        openClawStatusDescription: "✅ 已就绪 baseURL=http://localhost:18789"
    )
    #expect(controller.openClawStatusText == "✅ 已就绪 baseURL=http://localhost:18789")
}

@Test("Task E: updateOpenClawStatusDescription 异步刷新 status label")
@MainActor
func openClawStatusAsyncUpdate() {
    let controller = SettingsWindowController(
        openClawStatusDescription: "⏳ 检测中"
    )
    controller.updateOpenClawStatusDescription("⚪ 未安装")
    #expect(controller.openClawStatusText == "⚪ 未安装")
}

@Test("Task E: OpenClaw autoStart 默认 true")
@MainActor
func openClawAutoStartDefaultsTrue() {
    let controller = SettingsWindowController()
    #expect(controller.isOpenClawAutoStartOn == true)
}

@Test("Task E: openClawAutoStart=false 初始化 → toggle off")
@MainActor
func openClawAutoStartInitFalse() {
    let controller = SettingsWindowController(openClawAutoStart: false)
    #expect(controller.isOpenClawAutoStartOn == false)
}

@Test("Task E: openClawAllowEndpointEnable 默认 true")
@MainActor
func openClawAllowEndpointEnableDefaultsTrue() {
    let controller = SettingsWindowController()
    #expect(controller.isOpenClawAllowEndpointEnableOn == true)
}

@Test("防休眠: 默认 off")
@MainActor
func screenAwakeModeDefaultsOff() {
    let controller = SettingsWindowController()
    #expect(controller.selectedScreenAwakeModeRaw == "off")
}

@Test("防休眠: screenAwakeModeRaw=displayAwake 初始化 → 选中显示常亮")
@MainActor
func screenAwakeModeInitDisplayAwake() {
    let controller = SettingsWindowController(screenAwakeModeRaw: "displayAwake")
    #expect(controller.selectedScreenAwakeModeRaw == "displayAwake")
}

@Test("防休眠: simulateSelectScreenAwakeMode('systemAwake') → callback fire raw(modeless 即时提交)")
@MainActor
func screenAwakeModeSelectFiresRaw() {
    var captured: String?
    let controller = SettingsWindowController(screenAwakeModeRaw: "off")
    controller.onSaveScreenAwakeMode = { v in captured = v }

    controller.simulateSelectScreenAwakeMode("systemAwake")

    #expect(captured == "systemAwake")
    #expect(controller.selectedScreenAwakeModeRaw == "systemAwake")
}

@Test("防休眠: 定时自动关默认 never + 初始化 + 选择触发回调")
@MainActor
func screenAwakeAutoOff() {
    #expect(SettingsWindowController().selectedScreenAwakeAutoOffRaw == "never")
    #expect(SettingsWindowController(screenAwakeAutoOffRaw: "hour8").selectedScreenAwakeAutoOffRaw == "hour8")

    var captured: String?
    let controller = SettingsWindowController()
    controller.onSaveScreenAwakeAutoOff = { v in captured = v }
    controller.simulateSelectScreenAwakeAutoOff("hour2")
    #expect(captured == "hour2")
}

@Test("防休眠: 低电量自动关默认 true + 初始化 + toggle 触发回调")
@MainActor
func screenAwakeDisableOnLowPower() {
    #expect(SettingsWindowController().isScreenAwakeDisableOnLowPowerOn == true)
    #expect(SettingsWindowController(screenAwakeDisableOnLowPower: false).isScreenAwakeDisableOnLowPowerOn == false)

    var captured: Bool?
    let controller = SettingsWindowController()
    controller.onSaveScreenAwakeDisableOnLowPower = { v in captured = v }
    controller.simulateToggleScreenAwakeDisableOnLowPower(false)
    #expect(captured == false)
}

@Test("防休眠: updateScreenAwakeMode 程序化设值反映到 Picker(回退用,防回环由 App 层幂等 guard)")
@MainActor
func screenAwakeModeUpdateReflectsValue() {
    let controller = SettingsWindowController(screenAwakeModeRaw: "displayAwake")
    controller.updateScreenAwakeMode("off")
    #expect(controller.selectedScreenAwakeModeRaw == "off")
    controller.updateScreenAwakeAutoOff("hour4")
    #expect(controller.selectedScreenAwakeAutoOffRaw == "hour4")
}

@Test("Task E: simulateToggleOpenClawAutoStart(false) + Save → callback fire false")
@MainActor
func openClawAutoStartSaveFiresFalse() {
    var captured: Bool?
    let controller = SettingsWindowController(openClawAutoStart: true)
    controller.onSaveOpenClawAutoStart = { v in captured = v }

    controller.simulateToggleOpenClawAutoStart(false)
    controller.simulateSave(apiKey: "")

    #expect(captured == false)
}

@Test("Task E: simulateToggleOpenClawAllowEndpointEnable(false) + Save → callback fire false")
@MainActor
func openClawAllowEndpointEnableSaveFiresFalse() {
    var captured: Bool?
    let controller = SettingsWindowController(openClawAllowEndpointEnable: true)
    controller.onSaveOpenClawAllowEndpointEnable = { v in captured = v }

    controller.simulateToggleOpenClawAllowEndpointEnable(false)
    controller.simulateSave(apiKey: "")

    #expect(captured == false)
}

@Test("Task E: 灵动岛切桌面隐藏桌宠 toggle 默认 on")
@MainActor
func islandHidePetOnSwitchDefaultsOn() {
    // 注意: notchAvailable 默认 false → toggle.isEnabled=false, 但 state=on
    // 仍按 islandHidePetOnSwitch 参数初始化(默认 true)。
    let controller = SettingsWindowController()
    #expect(controller.isIslandHidePetOnSwitchOn == true)
}

@Test("Task E: islandHidePetOnSwitch=false 初始化 → toggle off")
@MainActor
func islandHidePetOnSwitchInitFalse() {
    let controller = SettingsWindowController(islandHidePetOnSwitch: false)
    #expect(controller.isIslandHidePetOnSwitchOn == false)
}

@Test("Task E: simulateToggleIslandHidePetOnSwitch(false) + Save → callback fire false")
@MainActor
func islandHidePetOnSwitchSaveFiresFalse() {
    var captured: Bool?
    let controller = SettingsWindowController(islandHidePetOnSwitch: true)
    controller.onSaveIslandHidePetOnSwitch = { v in captured = v }

    controller.simulateToggleIslandHidePetOnSwitch(false)
    controller.simulateSave(apiKey: "")

    #expect(captured == false)
}

@Test("Task E: tool engine kind picker 默认值 'claudeCode'")
@MainActor
func toolEngineKindDefaultsToClaudeCode() {
    let controller = SettingsWindowController()
    #expect(controller.selectedToolEngineKind == "claudeCode")
}

@Test("Task E: currentToolEngineKind 'codex' 初始化 → picker 选中 codex")
@MainActor
func toolEngineKindInitCodex() {
    let controller = SettingsWindowController(currentToolEngineKind: "codex")
    #expect(controller.selectedToolEngineKind == "codex")
}

@Test("Task E: currentToolEngineKind 'openCode' 初始化 → picker 选中 openCode")
@MainActor
func toolEngineKindInitOpenCode() {
    let controller = SettingsWindowController(currentToolEngineKind: "openCode")
    #expect(controller.selectedToolEngineKind == "openCode")
}

@Test("Task E: simulateSelectToolEngineKind('codex') + Save → onSaveToolEngineKind fire 'codex'")
@MainActor
func toolEngineKindSaveFiresCodex() {
    var captured: String?
    let controller = SettingsWindowController(currentToolEngineKind: "claudeCode")
    controller.onSaveToolEngineKind = { kind in captured = kind }

    controller.simulateSelectToolEngineKind("codex")
    controller.simulateSave(apiKey: "")

    #expect(captured == "codex")
}

@Test("Task E: simulateSelectToolEngineKind('unknown-xyz') 是 no-op,选择保留")
@MainActor
func toolEngineKindUnknownIsNoOp() {
    let controller = SettingsWindowController(currentToolEngineKind: "codex")
    controller.simulateSelectToolEngineKind("does-not-exist-engine")
    #expect(controller.selectedToolEngineKind == "codex")
}

@Test("Task E: updateToolEngineCLIPath(nil) → 显示 'CLI: 未安装'")
@MainActor
func toolEngineCLIPathNilShowsUninstalled() {
    let controller = SettingsWindowController(toolEngineCLIPath: nil)
    controller.updateToolEngineCLIPath(nil)
    #expect(controller.toolEngineCLIPathLabel.stringValue == "CLI: 未安装")
}

@Test("Task E: updateToolEngineCLIPath('/usr/local/bin/claude') → 显示路径")
@MainActor
func toolEngineCLIPathShowsActualPath() {
    let controller = SettingsWindowController()
    controller.updateToolEngineCLIPath("/usr/local/bin/claude")
    #expect(controller.toolEngineCLIPathLabel.stringValue == "CLI: /usr/local/bin/claude")
}

@Test("Task E: 关于版本号 init 默认 'OpenPetAgent (dev)'")
@MainActor
func aboutVersionDefaultText() {
    let controller = SettingsWindowController()
    #expect(controller.aboutVersionText == "OpenPetAgent (dev)")
}

@Test("Task E: 关于版本号 init 注入自定义字符串显示")
@MainActor
func aboutVersionInjectedText() {
    let controller = SettingsWindowController(aboutVersion: "OpenPetAgent v0.2.0 (abc123)")
    #expect(controller.aboutVersionText == "OpenPetAgent v0.2.0 (abc123)")
}

@Test("Task E: 单次 simulateSave(空 key) → 四个新 callback 同时 fire")
@MainActor
func taskENewCallbacksAllFireOnSingleSave() {
    var toolEngineFired = false
    var autoStartFired = false
    var allowEndpointFired = false
    var hideOnSwitchFired = false

    let controller = SettingsWindowController(
        currentToolEngineKind: "codex",
        openClawAutoStart: false,
        openClawAllowEndpointEnable: false,
        islandHidePetOnSwitch: false
    )
    controller.onSaveToolEngineKind = { _ in toolEngineFired = true }
    controller.onSaveOpenClawAutoStart = { _ in autoStartFired = true }
    controller.onSaveOpenClawAllowEndpointEnable = { _ in allowEndpointFired = true }
    controller.onSaveIslandHidePetOnSwitch = { _ in hideOnSwitchFired = true }

    controller.simulateSave(apiKey: "")

    #expect(toolEngineFired)
    #expect(autoStartFired)
    #expect(allowEndpointFired)
    #expect(hideOnSwitchFired)
}

// MARK: - 温度模式覆盖档（迁移自状态栏菜单）

@Test("ThermalOverrideMode: ambient 值 + auto 不覆盖 + raw 还原")
@MainActor
func thermalOverrideModeValues() {
    #expect(ThermalOverrideMode.auto.ambientTemperature == nil)   // 跟随天气
    #expect(ThermalOverrideMode.winter.ambientTemperature == 0.05)
    #expect(ThermalOverrideMode.spring.ambientTemperature == 0.22)
    #expect(ThermalOverrideMode.sauna.ambientTemperature == 0.55)
    #expect(ThermalOverrideMode.from(raw: "sauna") == .sauna)
    #expect(ThermalOverrideMode.from(raw: "不认识") == .auto)   // 未知回落 auto
    #expect(ThermalOverrideMode.options.first?.id == "auto")     // auto 在最前
}

@Test("Settings: 切温度档触发 preview（不写 UD）")
@MainActor
func thermalOverridePreviewFires() {
    var previewed: [String] = []
    let controller = SettingsWindowController(thermalOverrideRaw: "auto")
    controller.onThermalOverridePreview = { raw in previewed.append(raw) }

    controller.simulateSelectThermalOverride("sauna")

    #expect(controller.selectedThermalOverrideRaw == "sauna")
    #expect(previewed == ["sauna"])
}

@Test("Settings: 保存触发 onSaveThermalOverride 带当前档")
@MainActor
func thermalOverrideSaveFires() {
    var saved: String?
    let controller = SettingsWindowController(thermalOverrideRaw: "auto")
    controller.onSaveThermalOverride = { raw in saved = raw }

    controller.simulateSelectThermalOverride("winter")
    controller.simulateSave(apiKey: "")   // save 始终触发天气类 callback

    #expect(saved == "winter")
}

// MARK: - 调试调参面板（falling-sand 实时调参）

@Test("FallingSandTuning Codable 往返保真 + 默认值匹配生产")
@MainActor
func fallingSandTuningCodableRoundTrip() throws {
    var t = FallingSandTuning()
    #expect(t.snowEmitPerFrame == 40)       // 生产默认
    #expect(t.maxColumnDepth == 24)
    t.snowEmitPerFrame = 77
    t.meltThreshold = 0.33
    let data = try JSONEncoder().encode(t)
    let back = try JSONDecoder().decode(FallingSandTuning.self, from: data)
    #expect(back == t)
    #expect(back.snowEmitPerFrame == 77)
    #expect(back.meltThreshold == 0.33)
}

@Test("Settings: 调参 preview + save 触发回调")
@MainActor
func fallingSandTuningPreviewAndSave() {
    var previewed: [Int] = []
    var saved: FallingSandTuning?
    let controller = SettingsWindowController()
    controller.onFallingSandTuningPreview = { previewed.append($0.snowEmitPerFrame) }
    controller.onSaveFallingSandTuning = { saved = $0 }

    // 模拟拖滑块：直接改 viewModel.tuning（onChange 在真实 UI 触发 preview，测试里手动调）
    controller.simulateSetFallingSandTuning { $0.snowEmitPerFrame = 88 }
    controller.simulateSave(apiKey: "")

    #expect(previewed == [88])
    #expect(saved?.snowEmitPerFrame == 88)
}

// MARK: - 主动协助设置面板

@Test("ProactiveSettings Codable 往返保真 + 默认值匹配生产")
@MainActor
func proactiveSettingsCodableRoundTrip() throws {
    var s = ProactiveSettings()
    #expect(s.level == .moderate)            // 生产默认
    #expect(s.triggerDwell == false)
    #expect(s.dwellThresholdSeconds == 600)
    s.level = .active
    s.triggerDwell = true
    s.triggerLateNight = false
    s.dwellThresholdSeconds = 300
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(ProactiveSettings.self, from: data)
    #expect(back == s)
    #expect(back.level == .active)
    #expect(back.triggerDwell == true)
    #expect(back.dwellThresholdSeconds == 300)
}

@Test("Settings: 主动协助 preview + save 触发回调")
@MainActor
func proactiveSettingsPreviewAndSave() {
    var previewed: [ProactivityLevel] = []
    var saved: ProactiveSettings?
    let controller = SettingsWindowController()
    controller.onProactiveSettingsPreview = { previewed.append($0.level) }
    controller.onSaveProactiveSettings = { saved = $0 }

    // 模拟改控件：直接改 viewModel.proactiveSettings（onChange 在真实 UI 触发 preview，测试里手动调）
    controller.simulateSetProactiveSettings { $0.level = .active }
    controller.simulateSave(apiKey: "")

    #expect(previewed == [.active])
    #expect(saved?.level == .active)
}


// MARK: - Phase 2 多宠同屏 — 「同屏」装饰伙伴 toggle 接线

/// 测试用 Shimeji 导入形象 —— `.shimejiImport` category 让 `canBeDecorative` 通过(可同屏)。
private enum FakeShimejiPlugin: PetPlugin {
    static let identity = PetIdentity(
        id: "shimeji-miku",
        displayName: "初音未来",
        recommendedSize: NSSize(width: 128, height: 128),
        category: .shimejiImport
    )
    static func makeRenderer() -> PetRenderer? { nil }
}

@Test("同屏 toggle: 勾选/取消触发 onToggleDecorativePet(id, on) + 同步 activeDecorativePetIDs")
@MainActor
func decorativeToggleFiresCallback() {
    var events: [(String, Bool)] = []
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeShimejiPlugin.fakeEntry],
        currentPetPluginID: "orb"
    )
    controller.onToggleDecorativePet = { id, on in events.append((id, on)) }

    controller.simulateToggleDecorativePet("shimeji-miku")   // 上屏
    #expect(events.count == 1)
    #expect(events.last?.0 == "shimeji-miku")
    #expect(events.last?.1 == true)
    #expect(controller.activeDecorativePetIDs.contains("shimeji-miku"))

    controller.simulateToggleDecorativePet("shimeji-miku")   // 下屏
    #expect(events.count == 2)
    #expect(events.last?.1 == false)
    #expect(!controller.activeDecorativePetIDs.contains("shimeji-miku"))
}

@Test("同屏 toggle: init 从 activeDecorativePetIDs 注入当前同屏集")
@MainActor
func decorativeToggleInitFromActiveSet() {
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeShimejiPlugin.fakeEntry],
        currentPetPluginID: "orb",
        activeDecorativePetIDs: ["shimeji-miku"]
    )
    #expect(controller.activeDecorativePetIDs == ["shimeji-miku"])
}

@Test("同屏 toggle: 内置形象(非 Shimeji)不可同屏 —— toggle 是 no-op")
@MainActor
func decorativeToggleBuiltinIsNoOp() {
    var fired = 0
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeSlimePlugin.fakeEntry],
        currentPetPluginID: "orb"
    )
    controller.onToggleDecorativePet = { _, _ in fired += 1 }

    controller.simulateToggleDecorativePet("slime")   // builtin slime 不可同屏
    #expect(fired == 0)
    #expect(controller.activeDecorativePetIDs.isEmpty)
}

@Test("同屏 toggle: 主宠不可同屏(canBeDecorative 排主宠)—— toggle 主宠是 no-op")
@MainActor
func decorativeTogglePrimaryIsNoOp() {
    var fired = 0
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeShimejiPlugin.fakeEntry],
        currentPetPluginID: "shimeji-miku"   // shimeji 作主宠
    )
    controller.onToggleDecorativePet = { _, _ in fired += 1 }

    controller.simulateToggleDecorativePet("shimeji-miku")   // 它是主宠 → 不可同屏
    #expect(fired == 0)
    #expect(controller.activeDecorativePetIDs.isEmpty)
}

@Test("同屏 toggle: 装饰伙伴被选为主宠 → 从同屏集移除 + 触发 onToggleDecorativePet(id,false)")
@MainActor
func selectPrimaryDemotesActiveDecorative() {
    var events: [(String, Bool)] = []
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeShimejiPlugin.fakeEntry],
        currentPetPluginID: "orb",
        activeDecorativePetIDs: ["shimeji-miku"]
    )
    controller.onToggleDecorativePet = { id, on in events.append((id, on)) }

    controller.simulateSelectPetPlugin("shimeji-miku")   // 把装饰伙伴升为主宠

    #expect(controller.selectedPetPluginID == "shimeji-miku")
    #expect(!controller.activeDecorativePetIDs.contains("shimeji-miku"))   // 已从同屏集移除
    #expect(events.last?.0 == "shimeji-miku")
    #expect(events.last?.1 == false)   // 通知 App 收掉那只装饰副本
}

@Test("整包同屏: simulateToggleWholePack 触发 onToggleDecorativePack 批量回调(全员上屏)")
@MainActor
func wholePackToggleFiresBatchCallback() {
    // 两只同 packId "alan" 的 shimeji + orb 主宠 → alan 包整包可同屏。
    func shimeji(_ id: String, _ name: String) -> PetPluginEntry {
        PetPluginEntry(
            identity: PetIdentity(id: id, displayName: name, recommendedSize: .zero,
                                  category: .shimejiImport, packId: "alan", packName: "Alan 包"),
            makeRenderer: { nil })
    }
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, shimeji("codex:blue", "Blue"), shimeji("codex:red", "Red")],
        currentPetPluginID: "orb")
    var events: [(ids: [String], on: Bool)] = []
    controller.onToggleDecorativePack = { events.append((ids: $0, on: $1)) }

    controller.simulateToggleWholePack(packId: "alan")   // 空 → 全上屏

    #expect(events.count == 1)
    #expect(Set(events[0].ids) == ["codex:blue", "codex:red"])
    #expect(events[0].on == true)
    #expect(controller.activeDecorativePetIDs == ["codex:blue", "codex:red"])
}

@Test("modeless: 选主宠即时触发(onSelectPet→onSavePlugin),不再等「保存」")
@MainActor
func selectPetAppliesLiveWithoutSave() {
    var applied: [String] = []
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeSlimePlugin.fakeEntry],
        currentPetPluginID: "orb")
    controller.onSavePlugin = { applied.append($0) }   // onSelectPet 接到此

    controller.simulateSelectPetPlugin("slime")   // **不**调 simulateSave

    #expect(applied == ["slime"])   // 选中即时切主宠(根治「主宠选择没生效」)
}

@Test("modeless: 选同一主宠是 no-op(不重复切)")
@MainActor
func reselectSamePetIsNoOp() {
    var applied: [String] = []
    let controller = SettingsWindowController(
        availablePetPlugins: [FakeOrbPlugin.fakeEntry, FakeSlimePlugin.fakeEntry],
        currentPetPluginID: "orb")
    controller.onSavePlugin = { applied.append($0) }
    controller.simulateSelectPetPlugin("orb")   // 已是当前 → guard 拦下
    #expect(applied.isEmpty)
}
