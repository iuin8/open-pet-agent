import AppKit
import CoreGraphics
import Context
import Foundation
import Orchestrator
import Weather
import Rendering
import RuntimeBridge
import Shell
import AgentMode

// MARK: - Settings window

extension MinimalAppDelegate {
    /// 构建一个 SettingsWindowController(读当前 UD 状态 + 接好所有回调),**不赋值不显示**。
    /// `showSettingsWindow` 每次重建以刷新状态;`ensureSettingsWindowController` 仅在缺失时建。
    private func buildSettingsController() -> SettingsWindowController {
        // 当前后端经 `SoulBackendRegistry`(单一事实源,认得 openclaw)解析 —— 取代旧
        // `LLMProviderKind.resolve` + isAnthropic 二元分支(它不认 openclaw,导致 openclaw
        // 激活时 picker 错显「OpenAI 兼容」选中)。existingKey 从该后端声明的槽读;managed
        // 后端(openclaw,三槽 nil)→ 字段空(picker 选中时本就隐藏字段,不读)。
        let currentBackend = SoulBackendRegistry.resolve(from: userDefaults)
        let existingKey = currentBackend.picker.apiKeySlot.flatMap { userDefaults.string(forKey: $0) } ?? ""
        let existingBaseURL = currentBackend.picker.baseURLSlot.flatMap { userDefaults.string(forKey: $0) } ?? ""
        let existingModel = currentBackend.picker.modelSlot.flatMap { userDefaults.string(forKey: $0) } ?? ""

        // N3.6: 收集已注册 pet plugin + 当前选中 id,传给设置面板渲染下拉框。
        // 顺序按 PetPluginRegistry 注册顺序(MinimalAppDelegate 在 launching
        // 时显式 register OrbPetPlugin → SlimePetPlugin),UI 层不再 sort。
        let availablePlugins = PetPluginRegistry.shared.all
        let currentPluginID = userDefaults.string(forKey: Self.petPluginUserDefaultsKey) ?? "orb"

        // N1.3: 灵动岛 toggle 初始值 = UserDefaults 当前值(缺失视为 true,
        // 跟启动期 didFinishLaunching 的同一份判定保持一致);notchAvailable
        // 用 mainScreenHasNotch() 探测主屏,与启动期判定同源。
        let islandEnabled =
            userDefaults.object(forKey: Self.dynamicIslandEnabledKey) as? Bool ?? true
        let notchAvailable = DynamicIslandController.mainScreenHasNotch()

        // N2.3: 工具模式 toggle 当前值 (默认 false, 实验特性)。
        let agentModeEnabled = userDefaults.bool(forKey: Self.agentModeEnabledKey)

        // Task E: 收集 settings 面板需要的额外参数 —— tool engine kind /
        // OpenClaw 状态 / OpenClaw toggles / 关于版本号。
        // picker 当前选中值走 `AgentEngineRegistry.resolve`(单一事实源):UD 缺失/
        // 存了未知值 → 归一到 claudeCode,与 `applySelectedAgentEngine` 的 engine
        // 解析一致,避免 picker 回显一个 registry 里不存在的 stale id。
        let currentAgentEngineKindRaw = AgentEngineRegistry.resolve(from: userDefaults).id
        let openClawAutoStart =
            (userDefaults.object(forKey: OpenClawGatewayManager.autoStartKey) as? Bool) ?? true
        let openClawAllowEndpointEnable =
            (userDefaults.object(forKey: OpenClawGatewayManager.allowEndpointEnableKey) as? Bool) ?? true
        let islandHidePetOnSwitch =
            (userDefaults.object(forKey: Self.islandHidePetOnSwitchKey) as? Bool) ?? true
        // 开机自启:读 SMAppService 当前状态(权威源,含 requiresApproval 视为已请求 → 勾上)。
        let launchAtLogin = launchAtLoginManager.isEnabled || launchAtLoginManager.requiresApproval
        let menuBarIconVisible = menuBarIconVisibleSetting()
        // 感知与交互(从菜单迁入):读各自 UD 当前态(与启动期 wiring 同款默认)。
        let agentSensingOn = (userDefaults.object(forKey: Self.agentSensingEnabledKey) as? Bool) ?? true
        let permissionAnsweringOn = (userDefaults.object(forKey: Self.permissionAnsweringEnabledKey) as? Bool) ?? false
        let freezeOn = (userDefaults.object(forKey: Self.freezeWhenInteractingEnabledKey) as? Bool) ?? true
        // 读 controller 的 live 会话状态(而非 UD)——lidClosedAwake 是会话级,UD 启动已降级。
        let screenAwakeModeRaw = screenAwakeController.mode.rawValue
        let screenAwakeAutoOffRaw = screenAwakeController.autoOff.rawValue
        let screenAwakeDisableOnLowPower = screenAwakeController.disableOnLowPower
        let aboutVersion = Self.aboutVersionString()

        let controller = SettingsWindowController(
            selectedProvider: currentBackend.id,
            existingAPIKey: existingKey,
            existingBaseURL: existingBaseURL,
            existingModel: existingModel,
            // provider picker 列表从 `SoulBackendRegistry.all` 动态派生(不写死二元;
            // Shell 不依赖 App,故由 App 注入,镜像 availableAgentEngines / availablePetPlugins)。
            availableSoulBackends: SoulBackendRegistry.all.map(\.settingsOption),
            availablePetPlugins: availablePlugins,
            currentPetPluginID: currentPluginID,
            petScale: petScaleSetting,
            activeDecorativePetIDs: Set(wantedDecorativePetIDs()),
            islandEnabled: islandEnabled,
            notchAvailable: notchAvailable,
            agentModeEnabled: agentModeEnabled,
            currentAgentEngineKind: currentAgentEngineKindRaw,
            // engine picker 列表从 `AgentEngineRegistry.all` 动态派生(不写死;
            // Shell 不依赖 AgentMode,故由 App 注入,镜像 availablePetPlugins)。
            availableAgentEngines: AgentEngineRegistry.all.map { (id: $0.id, displayName: $0.displayName) },
            agentEngineCLIPath: nil,  // 异步在 controller.show() 后探测注入
            openClawStatusDescription: "⏳ 正在检测…",
            openClawAutoStart: openClawAutoStart,
            openClawAllowEndpointEnable: openClawAllowEndpointEnable,
            launchAtLogin: launchAtLogin,
            menuBarIconVisible: menuBarIconVisible,
            agentSensingEnabled: agentSensingOn,
            permissionAnsweringEnabled: permissionAnsweringOn,
            freezeWhenInteracting: freezeOn,
            screenAwakeModeRaw: screenAwakeModeRaw,
            screenAwakeAutoOffRaw: screenAwakeAutoOffRaw,
            screenAwakeDisableOnLowPower: screenAwakeDisableOnLowPower,
            islandHidePetOnSwitch: islandHidePetOnSwitch,
            autoFollowLocation: userDefaults.bool(forKey: Self.autoFollowLocationKey),
            selectedCityID: userDefaults.string(forKey: CityCatalog.userDefaultsKey) ?? CityCatalog.default.id,
            forcedConditionRaw: currentWeatherModeRaw,   // 含 "off"(关效果)统一天气模式
            thermalOverrideRaw: userDefaults.string(forKey: Self.thermalOverrideKey) ?? "auto",
            fallingSandTuning: fallingSandTuning,
            ballisticTuning: petMotionController.tuning,
            proactiveSettings: proactiveSettings,
            currentWeatherDescription: currentWeatherDescription,
            aboutVersion: aboutVersion
        )

        // Task E: OpenClaw status / tool engine CLI 路径异步注入 —— 都需要
        // hop 到 actor / 跑 Process subprocess, 不能阻塞 init。
        Task { [weak controller, userDefaults] in
            let status = await OpenClawGatewayManager.shared.status
            let desc = Self.describeOpenClawStatus(status)
            await MainActor.run {
                controller?.updateOpenClawStatusDescription(desc)
            }
            // CLI 路径探测 —— 跟 router 启动时同款 CLIAvailability 流程,
            // 让用户能在 UI 上看到当前 engine binary 是否真的能解析到。
            // 选 engine + binary 名都走 `AgentEngineRegistry`(单一事实源,不再
            // 写死 enum 分支);UD 没设 / 值不识别 → fallback claudeCode。
            let entry = AgentEngineRegistry.resolve(from: userDefaults)
            let cli = CLIAvailability()
            let augmentedPath = CLIProcessEnvironment.augmented()["PATH"] ?? ""
            let paths = augmentedPath.split(separator: ":").map(String.init)
            let resolved = await cli.locate(binary: entry.binaryName, searchPaths: paths)
            await MainActor.run {
                controller?.updateAgentEngineCLIPath(resolved)
            }
        }

        // N3.6: 切换 pet plugin —— 写 UserDefaults + 运行时 replace renderer。
        // 同 id 不重建(避免界面抖一下);unknown id 仍写 UserDefaults 但不
        // replace(下次启动若 plugin 注册了再生效)。
        controller.onSavePlugin = { [weak self] newPluginID in
            guard let self else { return }
            let previousID = self.userDefaults.string(forKey: Self.petPluginUserDefaultsKey) ?? "orb"
            self.userDefaults.set(newPluginID, forKey: Self.petPluginUserDefaultsKey)
            guard newPluginID != previousID,
                  let plugin = PetPluginRegistry.shared.plugin(for: newPluginID) else { return }
            self.shellController?.replacePetRenderer(with: plugin.makeRenderer(),
                                                     recommendedSize: plugin.identity.recommendedSize)
            // 新主宠若此前是同屏装饰伙伴 → 收掉那只装饰副本(主宠由 shellController 渲染,避免重影)。
            self.syncDecorativePets()
        }

        // Phase 2 多宠同屏:库 sheet 勾/取消「同屏」即时 spawn/despawn 装饰伙伴 + 持久化(modeless)。
        // 走 app 自己的 userDefaults.set(无外部 `defaults write` 的 UD 域不一致问题,见 lessons §2.3)。
        controller.onToggleDecorativePet = { [weak self] id, on in
            guard let self else { return }
            var ids = self.userDefaults.stringArray(forKey: Self.decorativePetIDsKey) ?? []
            if on {
                if !ids.contains(id) { ids.append(id) }
            } else {
                ids.removeAll { $0 == id }
            }
            self.setDecorativePetIDs(ids)
        }

        // S5 整包同屏:一批成员 id 一次性上/下屏 —— 单次批量改 UD + 单次 setDecorativePetIDs(sync 一次)。
        controller.onToggleDecorativePack = { [weak self] memberIDs, on in
            guard let self else { return }
            var ids = self.userDefaults.stringArray(forKey: Self.decorativePetIDsKey) ?? []
            if on {
                for id in memberIDs where !ids.contains(id) { ids.append(id) }
            } else {
                let drop = Set(memberIDs)
                ids.removeAll { drop.contains($0) }
            }
            self.setDecorativePetIDs(ids)
        }

        // PF6:桌宠大小 —— modeless 即时缩放 + 持久化(拖滑杆 onChange 直接生效落 UD)。
        controller.onPetScalePreview = { [weak self] scale in
            guard let self else { return }
            self.userDefaults.set(scale, forKey: Self.petScaleKey)
            self.shellController?.setPetScale(CGFloat(scale))
        }
        controller.onSavePetScale = { [weak self] scale in
            guard let self else { return }
            self.userDefaults.set(scale, forKey: Self.petScaleKey)
            self.shellController?.setPetScale(CGFloat(scale))
        }

        // N1.3: 切换灵动岛开关 —— 写 UserDefaults + 即时生效。
        // 三条路径:
        //   1) 已有 controller,且仍是刘海机型 → 改 isEnabled,didSet 自动
        //      orderFrontRegardless / orderOut。
        //   2) 还没有 controller(用户启动时关掉了 / 老用户首次启用 / 启动
        //      后插了刘海外接屏) + 现在主屏有刘海 + enabled=true → 懒创建。
        //   3) 启用但主屏无刘海 → 不创建(UI 那边 toggle 已被禁,正常不会
        //      触发此分支;保留 guard 避免诡异 case)。
        controller.onSaveIslandEnabled = { [weak self] enabled in
            guard let self else { return }
            self.userDefaults.set(enabled, forKey: Self.dynamicIslandEnabledKey)
            if let island = self.dynamicIslandController {
                island.isEnabled = enabled
            } else if enabled,
                      DynamicIslandController.mainScreenHasNotch() {
                // 优先找带刘海的屏(外接屏场景 NSScreen.main 不一定是
                // MBP 自带屏), 没找到就用 main 兜底。
                let notchedScreen = NSScreen.screens.first(where: {
                    DynamicIslandController.hasNotch($0)
                }) ?? NSScreen.main
                if let screen = notchedScreen {
                    let island = DynamicIslandController(screen: screen, isEnabled: true)
                    island.onTapped = { [weak self] in
                        self?.toggleChatCard()
                    }
                    self.dynamicIslandController = island
                }
            }
        }

        // N2.3 / N2.4: 切换工具模式 —— 写 UserDefaults + 即时调
        // `AgentModeRouter.setEngine` 注册 / 注销 engine, 用户无需重启。
        // - enabled=true → 按 `tool.engine.kind` 注册对应 engine
        // - enabled=false → setEngine(nil) 清空, prompt 回退 LLM 路径
        // router 始终存在 (`didFinishLaunching` 总会创建一个); 这里不需要
        // 处理 "router 还没创建" 的 case。
        //
        // N2.4 完整 GUI engine 选择 dropdown 留下一阶段做, 当前用户通过
        // 手动写 UserDefaults["tool.engine.kind"] = "codex" 切到 Codex。
        controller.onSaveAgentModeEnabled = { [weak self] enabled in
            guard let self else { return }
            self.userDefaults.set(enabled, forKey: Self.agentModeEnabledKey)
            if enabled {
                Self.applySelectedAgentEngine(
                    to: self.agentModeRouter,
                    defaults: self.userDefaults
                )
                self.wireACPPermissionHandler()   // ACP-2:engine 是 ACP 时注入 onPermissionRequest
            } else {
                let none: ClaudeCodeEngine? = nil
                self.agentModeRouter?.setEngine(none)
            }
        }

        // Task E: 工具 engine kind picker callback —— 写 UserDefaults。
        // 若当前 Tool Mode toggle 已开启, 立即让 router 切到新 engine
        // (applySelectedAgentEngine 会重新读 UserDefaults 选 engine)。
        controller.onSaveAgentEngineKind = { [weak self] kindRaw in
            guard let self else { return }
            self.userDefaults.set(kindRaw, forKey: AgentEngineKind.userDefaultsKey)
            if self.userDefaults.bool(forKey: Self.agentModeEnabledKey) {
                Self.applySelectedAgentEngine(
                    to: self.agentModeRouter,
                    defaults: self.userDefaults
                )
                self.wireACPPermissionHandler()   // ACP-2:engine 是 ACP 时注入 onPermissionRequest
            }
        }

        // Task E: OpenClaw autoStart toggle —— 写 UserDefaults, 下次启动生效。
        // 当前会话不强拉 daemon (避免用户切回 off 又 on 的过程中反复 spawn 进程)。
        // 开机自启 toggle —— register/unregister SMAppService.mainApp(权威源,无 UD)。
        // 失败 → 回退 toggle 到真实状态 + 提示;requiresApproval(用户曾在登录项关过)→ 引导去系统设置。
        controller.onSaveLaunchAtLogin = { [weak self] enabled in
            guard let self else { return }
            do {
                try self.launchAtLoginManager.setEnabled(enabled)
            } catch {
                self.settingsWindowController?.updateLaunchAtLogin(self.launchAtLoginManager.isEnabled)
                self.notifyLaunchAtLogin("设置开机自启失败:\(error.localizedDescription)")
                return
            }
            if enabled, self.launchAtLoginManager.requiresApproval {
                self.notifyLaunchAtLogin("已请求开机自启 —— 请在 系统设置 › 通用 › 登录项 中允许 OpenPetAgent。")
                Self.openLoginItemsSettings()
            }
        }

        // "在菜单栏显示图标" toggle —— 写 UD + 即时显隐状态项(MenuBarController 自管生命周期)。
        controller.onSaveMenuBarIconVisible = { [weak self] visible in
            guard let self else { return }
            self.userDefaults.set(visible, forKey: Self.menuBarIconVisibleKey)
            self.menuBarController.setStatusItemVisible(visible)
        }

        // 感知与交互(从菜单迁入)—— 复用原菜单栏的同款 apply 逻辑。
        controller.onSaveAgentSensing = { [weak self] enabled in
            guard let self else { return }
            self.userDefaults.set(enabled, forKey: Self.agentSensingEnabledKey)
            Task { await self.agentSensingService?.setEnabled(enabled) }
        }
        controller.onSavePermissionAnswering = { [weak self] enabled in
            self?.setPermissionAnswering(enabled: enabled)
        }
        controller.onSaveFreezeWhenInteracting = { [weak self] enabled in
            guard let self else { return }
            self.isFreezeWhenInteractingEnabled = enabled
            self.userDefaults.set(enabled, forKey: Self.freezeWhenInteractingEnabledKey)
        }

        controller.onSaveOpenClawAutoStart = { [weak self] enabled in
            guard let self else { return }
            self.userDefaults.set(enabled, forKey: OpenClawGatewayManager.autoStartKey)
        }

        // Task E: "允许自动 enable chatCompletions" toggle —— 写 UserDefaults,
        // 下次 bootstrapIfPossible 时生效。
        controller.onSaveOpenClawAllowEndpointEnable = { [weak self] enabled in
            guard let self else { return }
            self.userDefaults.set(enabled, forKey: OpenClawGatewayManager.allowEndpointEnableKey)
        }

        // Task E: "灵动岛切桌面隐藏桌宠" toggle —— 写 UserDefaults。
        // 实际"切桌面 fade pet"逻辑由 DesktopShellController 在切换时
        // 自行查询此 key (follow-up wire 点)。
        controller.onSaveIslandHidePetOnSwitch = { [weak self] enabled in
            guard let self else { return }
            self.userDefaults.set(enabled, forKey: Self.islandHidePetOnSwitchKey)
        }

        // "防休眠" 模式 Picker —— 即时应用 + 持久化。lidClosedAwake 弹风险确认 + 提权(async)。
        controller.onSaveScreenAwakeMode = { [weak self] raw in
            guard let self else { return }
            // 幂等 guard:程序化回退(updateScreenAwakeMode 把 Picker 设回当前真实 mode)触发的
            // 这次 commit 直接 no-op —— 防 onAutoChange→刷 Picker→onChange→onSave 回环 + 防 lid 重弹确认框。
            guard raw != self.screenAwakeController.mode.rawValue else { return }
            let mode = ScreenAwakeMode(rawValue: raw) ?? .off
            let autoOff = ScreenAwakeAutoOff(rawValue: self.currentScreenAwakeAutoOffRaw()) ?? .never

            if mode == .lidClosedAwake {
                // 风险确认 alert(散热 / 全局 / 需密码)。取消 → Picker 回退到当前真实模式。
                guard self.confirmEnableLidClosedAwake() else {
                    self.settingsWindowController?.updateScreenAwakeMode(self.screenAwakeController.mode.rawValue)
                    return
                }
                // 首次开且「自动关」为 never → 默认置 8h 兜底(防无限期),并反映到 UI。
                var effectiveAutoOff = autoOff
                if effectiveAutoOff == .never {
                    effectiveAutoOff = ScreenAwakeAutoOff.lidClosedDefault
                    self.userDefaults.set(effectiveAutoOff.rawValue, forKey: Self.screenAwakeAutoOffKey)
                    self.settingsWindowController?.updateScreenAwakeAutoOff(effectiveAutoOff.rawValue)
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let final = await self.screenAwakeController.apply(mode: .lidClosedAwake, autoOff: effectiveAutoOff)
                    self.persistScreenAwakeMode(final)
                    // 提权取消 / 电池拒开 → final != lid,回退 Picker(onAutoChange 也会，updateScreenAwakeMode 幂等)。
                    if final != .lidClosedAwake {
                        self.settingsWindowController?.updateScreenAwakeMode(final.rawValue)
                    }
                }
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let final = await self.screenAwakeController.apply(mode: mode, autoOff: autoOff)
                    self.persistScreenAwakeMode(final)
                    // 离开 lid 复位被取消 → final 仍是 lid,回退 Picker。
                    if final.rawValue != raw {
                        self.settingsWindowController?.updateScreenAwakeMode(final.rawValue)
                    }
                }
            }
        }

        // "防休眠" 定时自动关 Picker —— 写 UD + 重排定时器。
        controller.onSaveScreenAwakeAutoOff = { [weak self] raw in
            guard let self else { return }
            self.userDefaults.set(raw, forKey: Self.screenAwakeAutoOffKey)
            self.screenAwakeController.setAutoOff(ScreenAwakeAutoOff(rawValue: raw) ?? .never)
        }

        // "低电量自动关" 开关 —— 写 UD + 更新 controller。
        controller.onSaveScreenAwakeDisableOnLowPower = { [weak self] on in
            guard let self else { return }
            self.userDefaults.set(on, forKey: Self.screenAwakeDisableOnLowPowerKey)
            self.screenAwakeController.disableOnLowPower = on
        }

        // 城市 picker — 写 UserDefaults + 通知 WeatherStateManager 立刻切到新城市,
        // 不等下一个 15min Timer cycle。
        controller.onSaveCity = { [weak self] cityID in
            guard let self else { return }
            self.userDefaults.set(cityID, forKey: CityCatalog.userDefaultsKey)
            let coord = CityCatalog.city(forID: cityID).coordinate
            SnowDiagnostics.log("citySaved id=\(cityID) lat=\(coord.latitude) lng=\(coord.longitude)")
            // updateLocation 已在 preview 时调过, 保存只持久化 UD。
            // 但若用户打开 settings 没切城市直接点保存(城市没变过, preview 未触发),
            // 也要确认 updateLocation 一次保证 weather 走当前城市。
            if let manager = self.weatherStateManager {
                Task { await manager.updateLocation(coord) }
            }
        }

        // 城市 —— modeless:切城市即时拉新天气数据 + 持久化 UD。
        controller.onCityPreview = { [weak self] cityID in
            guard let self else { return }
            self.userDefaults.set(cityID, forKey: CityCatalog.userDefaultsKey)
            let coord = CityCatalog.city(forID: cityID).coordinate
            SnowDiagnostics.log("citySelect id=\(cityID) lat=\(coord.latitude) lng=\(coord.longitude)")
            if let manager = self.weatherStateManager {
                Task { await manager.updateLocation(coord) }
            }
        }

        // 自动跟随位置开关:写 UD + 切坐标源(CL 一次性取位 / 回退城市坐标)。
        controller.onCommitAutoFollowLocation = { [weak self] on in
            guard let self else { return }
            self.userDefaults.set(on, forKey: Self.autoFollowLocationKey)
            if on {
                self.fetchAndShowAutoFollowLocation()
            } else {
                self.settingsWindowController?.updateAutoFollowLocationLabel(nil)
                let cityID = self.userDefaults.string(forKey: CityCatalog.userDefaultsKey) ?? CityCatalog.default.id
                let coord = CityCatalog.city(forID: cityID).coordinate
                if let mgr = self.weatherStateManager { Task { await mgr.updateLocation(coord) } }
            }
        }

        // 天气模式 raw — "off"(关效果) / "auto" / 5 个 condition。modeless:切完即时生效 + 持久化。
        controller.onForcedConditionPreview = { [weak self] raw in
            SnowDiagnostics.log("weatherModeSelect raw=\(raw)")
            self?.selectWeatherMode(raw, persist: true)
        }
        controller.onSaveForcedCondition = { [weak self] raw in
            self?.selectWeatherMode(raw, persist: true)
        }

        // 温度模式覆盖档 — modeless:切档即时覆盖 ambient + 持久化 UD。
        controller.onThermalOverridePreview = { [weak self] raw in
            guard let self else { return }
            self.userDefaults.set(raw, forKey: Self.thermalOverrideKey)
            self.applyThermalOverride(.from(raw: raw))
        }

        // 温度模式覆盖档 save — 写 UD + 立刻应用。
        controller.onSaveThermalOverride = { [weak self] raw in
            guard let self else { return }
            self.userDefaults.set(raw, forKey: Self.thermalOverrideKey)
            self.applyThermalOverride(.from(raw: raw))
        }

        // 调试调参 — modeless:拖滑块即时生效 + 持久化 UD。
        controller.onFallingSandTuningPreview = { [weak self] tuning in
            self?.saveFallingSandTuning(tuning)
        }
        controller.onSaveFallingSandTuning = { [weak self] tuning in
            self?.saveFallingSandTuning(tuning)
        }
        // 弹力球抛射调参 — modeless:拖滑块即时生效(写 petMotionController.tuning)+ 持久化 UD。
        controller.onBallisticTuningPreview = { [weak self] tuning in
            self?.saveBallisticTuning(tuning)
        }

        // 主动协助 — modeless:改设置即时热更新引擎 + 持久化 UD。
        controller.onProactiveSettingsPreview = { [weak self] settings in
            self?.saveProactiveSettings(settings)
        }
        controller.onSaveProactiveSettings = { [weak self] settings in
            self?.saveProactiveSettings(settings)
        }

        // P2b:SOUL.md 编辑(人格 section)—— 写文件 + Finder reveal。初始读 SOUL.md(无则默认人格)。
        controller.onCommitSoul = { content in
            try? PersonaConfig.writeSoul(content)
        }
        controller.onRevealSoul = {
            NSWorkspace.shared.activateFileViewerSelecting([PersonaConfig.soulMDURL])
        }
        controller.onCommitPersonaSource = { [weak self] raw in
            guard let self, let source = PersonaSource(rawValue: raw) else { return }
            PersonaConfig.setCurrentSource(source, defaults: self.userDefaults)
        }
        controller.onCommitIdentity = { content in try? PersonaConfig.writeIdentity(content) }
        controller.onCommitUser = { content in try? PersonaConfig.writeUser(content) }
        controller.configureSoulEditor(
            initialText: PersonaConfig.readSoul() ?? PersonaConfig.defaultSoulContent,
            initialSource: PersonaConfig.resolveSource(from: userDefaults).rawValue,
            initialIdentity: PersonaConfig.readIdentity() ?? PersonaConfig.defaultIdentityContent,
            initialUser: PersonaConfig.readUser() ?? PersonaConfig.defaultUserContent
        )

        // MARK: - 系统权限 probe 注入(Task 4 + Task 6)

        // AccessibilityBridge 查询辅助功能授权态 + 弹系统授权框。
        let accessibilityBridge = AccessibilityBridge()
        // probe 由 onRequestPermission/onRefreshPermissions 闭包持有,与 controller 同生命周期。
        let probe = SystemPermissionProbe(
            accessibilityStatus: { accessibilityBridge.isProcessTrusted ? .granted : .notDetermined },
            // 弹系统授权框(首次)**并**打开系统设置面板:对「已在列表里但被关掉」(重装重置 / 曾拒绝)
            // 的情况,弹框不会再出 → 必须落到系统设置才点得了,否则又是「授权按钮点了没反应」。
            requestAccessibility: {
                accessibilityBridge.requestPermissionsPrompt()
                Self.openSystemSettingsPane(for: .accessibility)
            },
            screenRecordingStatus: { CGPreflightScreenCaptureAccess() ? .granted : .notDetermined },
            requestScreenRecording: {
                _ = CGRequestScreenCaptureAccess()
                Self.openSystemSettingsPane(for: .screenRecording)
            },
            locationStatus: { [weak self] in self?.locationAdapter?.permissionStatus ?? .notDetermined },
            requestLocation: { [weak self] in self?.locationAdapter?.requestAuthorization() },
            openSettings: { perm in Self.openSystemSettingsPane(for: perm) }
        )
        controller.onRequestPermission = { [weak controller] perm in
            probe.request(perm)
            // 申请后立即重查:系统弹框是异步的,下次窗口激活/onAppear 也会再刷新。
            controller?.refreshPermissions(using: probe)
        }
        controller.onRefreshPermissions = { [weak controller] in
            controller?.refreshPermissions(using: probe)
        }
        // 初始灌一次权限态(打开设置面板时即显示真实状态)。
        controller.refreshPermissions(using: probe)

        controller.onSaveProvider = { [weak self] providerString, newKey, newBaseURL, newModel in
            guard let self else { return }

            // 持久化「选了哪个后端」(身份)。
            self.userDefaults.set(providerString, forKey: LLMProviderKind.userDefaultsKey)

            // 槽位驱动写入(取代写死 `switch kind`):每个后端在 registry 里声明自己的三个
            // 槽,这里按声明写/清。**managed 后端(openclaw)三槽为 nil → 一个都不写**,
            // 只持久身份、不碰其专属槽(专属槽由 setupOpenClawBootstrap 管)。
            let backend = SoulBackendRegistry.lookup(id: providerString) ?? SoulBackendRegistry.all[0]
            func writeOrClear(_ value: String, into slot: String?) {
                guard let slot else { return }
                if value.isEmpty {
                    self.userDefaults.removeObject(forKey: slot)
                } else {
                    self.userDefaults.set(value, forKey: slot)
                }
            }
            writeOrClear(newKey, into: backend.picker.apiKeySlot)
            writeOrClear(newBaseURL, into: backend.picker.baseURLSlot)
            writeOrClear(newModel, into: backend.picker.modelSlot)

            // Hot-reload: re-resolve provider from the now-current UserDefaults
            // 并热替换共享 box,用户改完设置无需重启即生效。
            Task { [userDefaults = self.userDefaults,
                    box = self.llmProviderBox] in
                await AppBootstrap.reloadLLMProvider(
                    into: box,
                    userDefaults: userDefaults
                )
            }
        }
        // 重开设置时若已开「自动跟随位置」→ 取一次真实位置显示城市(延迟到 settingsWindowController 赋值后)。
        if userDefaults.bool(forKey: Self.autoFollowLocationKey) {
            DispatchQueue.main.async { [weak self] in self?.fetchAndShowAutoFollowLocation() }
        }
        return controller
    }

    /// 建并存 SettingsWindowController 并显示窗口。每次重建以读取当前 UD 状态。
    func showSettingsWindow() {
        let controller = buildSettingsController()
        settingsWindowController = controller
        controller.show()
    }

    /// 确保 SettingsWindowController 已建(**不显示窗口**)—— 供 onboarding 在用户从未打开过
    /// 设置时拿到其封装的 CommunityPetsSheet / viewModel。已存在则复用。
    func ensureSettingsWindowController() {
        if settingsWindowController == nil {
            settingsWindowController = buildSettingsController()
        }
    }

    /// 应用温度模式覆盖档（设置 → 天气）。即时生效，**不写 UD**（持久化由 onSave 负责）。
    ///   - 非 auto → 用该档固定 ambient 覆盖物理沙盒环境温度，无视天气。
    ///   - auto    → 恢复到最近一次天气驱动的温度（无则保持当前值），交还天气系统接管。
    func applyThermalOverride(_ mode: ThermalOverrideMode) {
        thermalOverride = mode
        let effective = mode.ambientTemperature ?? lastWeatherNormalizedTemp ?? fallingSandAmbientTemperature
        fallingSandAmbientTemperature = effective
        SnowDiagnostics.log("thermalOverride mode=\(mode.rawValue) ambient=\(effective)")
    }

    /// 应用 falling-sand 调参（设置 → 调试）。preview 即时生效、**不写 UD**；save 才持久化。
    func applyFallingSandTuning(_ tuning: FallingSandTuning) {
        fallingSandTuning = tuning
        shellController?.setFallingSandTuning(tuning)
    }

    /// 保存 falling-sand 调参：即时生效 + JSON 持久化到 UD。
    func saveFallingSandTuning(_ tuning: FallingSandTuning) {
        applyFallingSandTuning(tuning)
        if let data = try? JSONEncoder().encode(tuning) {
            userDefaults.set(data, forKey: Self.fallingSandTuningKey)
        }
    }

    /// 从 UD 读 falling-sand 调参（缺失/解码失败回落工厂默认）。
    static func loadFallingSandTuning(from ud: UserDefaults) -> FallingSandTuning {
        guard let data = ud.data(forKey: fallingSandTuningKey),
              let tuning = try? JSONDecoder().decode(FallingSandTuning.self, from: data)
        else { return FallingSandTuning() }
        return tuning
    }

    /// 应用弹力球抛射调参（设置 → 调试）：即时写入运动控制器,下一帧抛射用新参数。
    func applyBallisticTuning(_ tuning: BallisticTuning) {
        petMotionController.tuning = tuning
    }

    /// 保存弹力球抛射调参：即时生效 + JSON 持久化到 UD。
    func saveBallisticTuning(_ tuning: BallisticTuning) {
        applyBallisticTuning(tuning)
        if let data = try? JSONEncoder().encode(tuning) {
            userDefaults.set(data, forKey: Self.ballisticTuningKey)
        }
    }

    /// 从 UD 读弹力球抛射调参（缺失/解码失败回落工厂默认）。
    static func loadBallisticTuning(from ud: UserDefaults) -> BallisticTuning {
        guard let data = ud.data(forKey: ballisticTuningKey),
              let tuning = try? JSONDecoder().decode(BallisticTuning.self, from: data)
        else { return BallisticTuning() }
        return tuning
    }

    /// 应用主动协助设置（设置 → 主动协助）。即时生效，**不写 UD**；save 才持久化。
    func applyProactiveSettings(_ settings: ProactiveSettings) {
        proactiveSettings = settings
        if let engine = proactiveEngine {
            Task { await engine.updateSettings(settings) }
        }
    }

    /// 保存主动协助设置：即时生效 + JSON 持久化到 UD。
    func saveProactiveSettings(_ settings: ProactiveSettings) {
        applyProactiveSettings(settings)
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: Self.proactiveSettingsKey)
        }
    }

    /// 从 UD 读主动协助设置（缺失/解码失败回落工厂默认）。
    static func loadProactiveSettings(from ud: UserDefaults) -> ProactiveSettings {
        guard let data = ud.data(forKey: proactiveSettingsKey),
              let settings = try? JSONDecoder().decode(ProactiveSettings.self, from: data)
        else { return .default }
        return settings
    }

    /// 开启「合盖也保持唤醒」前的风险确认 alert。返回用户是否确认继续。
    /// 提权(密码框)由 ScreenAwakeController 在确认后再触发。
    func confirmEnableLidClosedAwake() -> Bool {
        let alert = NSAlert()
        alert.messageText = "开启「合盖也保持唤醒」?"
        alert.informativeText = """
        这会修改系统全局设置(pmset disablesleep),让 Mac 合盖也不休眠、无需外接显示器。

        • 需要输入管理员密码
        • 仅在接电源时维持(拔电会自动关闭)
        • 合盖跑负载有散热风险 —— 别放在堵住底部进风的软面上
        • 退出 App / 切换模式会自动复位;建议设个「自动关闭」时长兜底

        继续?
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "继续(需要密码)")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 启动自愈:检测到上次「合盖防休眠」未正常复位(崩溃残留)时的解释性确认。
    /// 透明告知用户为何在启动时弹密码框(避免像钓鱼),返回是否复位。
    func confirmRecoverSleepResidue() -> Bool {
        let alert = NSAlert()
        alert.messageText = "恢复系统休眠设置?"
        alert.informativeText = """
        检测到上次「合盖防休眠」未正常复位 —— 系统当前被设为不休眠(pmset disablesleep)。

        点「恢复」会把它复位(需要管理员密码)。点「稍后」则保持现状,下次启动会再次提示。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "恢复(需要密码)")
        alert.addButton(withTitle: "稍后")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 开机自启相关提示走 pet 气泡(context「启动」,与防休眠分开)。
    func notifyLaunchAtLogin(_ reason: String) {
        bondedSession?.injectProactiveSuggestion(context: "启动", reply: reason) { _ in }
    }

    /// 打开 系统设置 › 通用 › 登录项(macOS 13+ 深链)。
    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 系统设置深链(Task 4)

    /// 跳到对应权限的系统设置隐私页。
    static func openSystemSettingsPane(for permission: SystemPermission) {
        let anchor: String
        switch permission {
        case .accessibility:   anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .location:        anchor = "Privacy_LocationServices"
        case .appleEvents:     anchor = "Privacy_Automation"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 自动跟随位置:取一次真实坐标 → 喂天气 + 逆地理编码城市名,把「城市 · 坐标」推给设置面板,
    /// 让用户感知定位是否准确(而非显示手选城市的旧坐标)。定位中 / 失败有对应文案。
    @MainActor
    func fetchAndShowAutoFollowLocation() {
        settingsWindowController?.updateAutoFollowLocationLabel("定位中…")
        locationAdapter?.requestOneShotLocation { [weak self] coord in
            guard let self else { return }
            guard let coord else {
                self.settingsWindowController?.updateAutoFollowLocationLabel("定位失败,暂用所选城市")
                return
            }
            if let mgr = self.weatherStateManager { Task { await mgr.updateLocation(coord) } }
            let coordText = String(format: "%.4f°N, %.4f°E", coord.latitude, coord.longitude)
            self.locationAdapter?.reverseGeocode(coord) { [weak self] city in
                let label = (city.map { "\($0) · " } ?? "") + coordText
                self?.settingsWindowController?.updateAutoFollowLocationLabel(label)
            }
        }
    }

    func shareOverlayScreenshot() {
        guard let shellController else { return }

        let overlayWindow = shellController.overlayWindowForScreenshot

        // Anchor the NSSharingServicePicker to the status bar button when
        // available; fall back to the overlay window's content view so the
        // picker always has a valid NSView to attach to.
        let anchorView: NSView = menuBarController.statusItemButton ?? overlayWindow.contentView ?? NSView()

        screenshotService.captureAndShare(window: overlayWindow, anchorView: anchorView)
    }

    /// Task E: 把 `OpenClawGatewayManager.Status` 翻译成 settings 面板可显示
    /// 的中文文案。`Status` enum 在 Orchestrator 模块,Shell 不依赖
    /// Orchestrator,所以转字符串后再注入 Settings —— 避开循环依赖。
    static func describeOpenClawStatus(_ status: OpenClawGatewayManager.Status) -> String {
        switch status {
        case .unknown:
            return "⏳ 尚未检测"
        case .disabledByUser:
            return "⚪ 已关闭自动启动(可在系统区开启)"
        case .notInstalled:
            return "⚪ 未安装 — `brew install openclaw` 或 `npm install -g openclaw`"
        case .installedNotOnboarded(let binaryPath):
            return "⚠️ 找到 binary 但未 onboard:\(binaryPath)\n  运行 `openclaw onboard --install-daemon`"
        case .ready(let baseURL, let token):
            let tokenSuffix = token.map { _ in "(已附 token)" } ?? "(无 token)"
            return "✅ 已就绪 baseURL=\(baseURL) \(tokenSuffix)"
        case .error(let msg):
            return "❌ 错误:\(msg)"
        }
    }

    /// Task E: 关于面板版本字符串 —— 优先用 `CFBundleShortVersionString`
    /// (Bundle.main 里 Info.plist), 缺失就 fallback 到 "dev"。
    /// commit hash 走环境变量 `PETAGENT_COMMIT`(CI 注入),local 启动时为空。
    static func aboutVersionString() -> String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let commit = ProcessInfo.processInfo.environment["PETAGENT_COMMIT"]
        var parts: [String] = ["OpenPetAgent"]
        if let short, !short.isEmpty {
            parts.append("v\(short)")
        } else {
            parts.append("(dev)")
        }
        if let build, !build.isEmpty, build != short {
            parts.append("build \(build)")
        }
        if let commit, !commit.isEmpty {
            parts.append("(\(commit))")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - SoulBackendEntry → 设置面板 picker option

extension SoulBackendEntry {
    /// 把注册表 entry 映射成 Shell 层 picker option(App 注入 Shell;字段一一搬运,
    /// **零类型分支**,新增后端在 registry 填好 picker info 即自动跟上)。
    var settingsOption: SoulBackendOption {
        SoulBackendOption(
            id: id,
            displayName: displayName,
            managed: picker.isManaged,
            keyLabel: picker.keyLabel,
            keyPlaceholder: picker.keyPlaceholder,
            baseURLPlaceholder: picker.baseURLPlaceholder,
            baseURLHint: picker.baseURLHint,
            modelPlaceholder: picker.modelPlaceholder,
            managedNote: picker.managedNote
        )
    }
}
