import AppKit
import Combine
import Orchestrator
import Rendering
import RuntimeBridge
import ShimejiImport
import Weather

/// SwiftUI 设置面板共享的状态对象。所有表单字段都集中在此,SettingsRootView
/// + 各 Section 通过 `@ObservedObject` 双向绑定。
///
/// **macOS 13 兼容性**: 用 `ObservableObject + @Published` 而非
/// `@Observable`(后者需 macOS 14+)。Package.swift `platforms: [.macOS(.v13)]`
/// 必须保持兼容。
///
/// `SettingsWindowController` 在 init 时填充全部初始值,save 时直接从这里读
/// 最终值,触发 callback。
/// 设置面板 picker 一项 —— 比原 `(id, displayName)` 元组多带 **来源分类**(分组用)
/// + **缩略图**(idle 首帧,sprite 包有、内置 SDF 为 nil 用占位图标)。
@MainActor
struct PetPickerItem: Identifiable {
    let id: String
    let displayName: String
    let category: PetCategory
    let thumbnail: NSImage?
    /// 包归属(多角色包二级分组用);`nil` = 无包归属(单宠物 / 内置 / 旧导入包),独立显示。
    let packId: String?
    let packName: String?
    /// 可删除(磁盘发现的包,`installPath != nil`)。内置 SDF 形象不可删。
    let canDelete: Bool

    init(id: String, displayName: String, category: PetCategory, thumbnail: NSImage?,
         packId: String? = nil, packName: String? = nil, canDelete: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.thumbnail = thumbnail
        self.packId = packId
        self.packName = packName
        self.canDelete = canDelete
    }

    init(entry: PetPluginEntry) {
        self.init(id: entry.identity.id, displayName: entry.identity.displayName,
                  category: entry.identity.category, thumbnail: entry.thumbnail,
                  packId: entry.identity.packId, packName: entry.identity.packName,
                  canDelete: entry.installPath != nil)
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    // MARK: - LLM 后端

    /// 0=OpenAI 兼容 / 1=Anthropic。
    @Published var selectedProviderIndex: Int
    @Published var apiKey: String
    @Published var baseURL: String
    @Published var model: String

    /// 由 controller 异步注入(`OpenClawGatewayManager.shared.status` → 中文描述)。
    @Published var openClawStatusDescription: String

    // MARK: - 桌宠

    @Published var selectedPetPluginID: String
    /// PF6 全局桌宠大小因子(0.5–2.0,1=原始)。拖滑杆 onChange → preview 即时生效;save 持久化。
    @Published var petScale: Double
    /// Phase 2 多宠同屏:当前激活为「同屏装饰伙伴」的宠物 id 集(已排除主宠)。库 sheet 的「同屏」
    /// toggle 即时生效(modeless,无回滚)—— 改 → `onToggleDecorativePet(id, on)` 回调链 → App
    /// 写 UD + spawn/despawn。init 从 App 的 `wantedDecorativePetIDs()` 注入当前同屏集。
    @Published var activeDecorativeIDs: Set<String>
    /// notchAvailable=false 时 toggle 强制关 + 禁用。
    @Published var islandEnabled: Bool
    @Published var islandHidePetOnSwitch: Bool
    let notchAvailable: Bool

    // MARK: - 工具模式

    @Published var toolModeEnabled: Bool
    /// raw string: "claudeCode" / "codex" / "openCode"
    @Published var toolEngineKind: String
    /// 由 controller 异步注入(`CLIAvailability.locate` 探测)。
    @Published var toolEngineCLIPath: String?

    // MARK: - 系统

    @Published var openClawAutoStart: Bool
    @Published var openClawAllowEndpointEnable: Bool

    /// 开机自启开关。反映 SMAppService 当前状态(权威源,无 UD)。
    @Published var launchAtLogin: Bool

    /// 开关改动即时提交 → 由 App 注入(register/unregister + 失败回退)。
    var onCommitLaunchAtLogin: (Bool) -> Void = { _ in }

    /// 「在菜单栏显示图标」开关。默认 false。UD key: "menuBarIconVisible"。
    @Published var menuBarIconVisible: Bool

    /// 开关改动即时提交 → 由 App 注入(写 UD + MenuBarController.setStatusItemVisible)。
    var onCommitMenuBarIconVisible: (Bool) -> Void = { _ in }

    // MARK: - 感知与交互(从菜单迁入,set-once 进阶开关)

    /// 感知外部编码会话(Claude Code / Codex)。默认 true。UD key: "agentSensingEnabled"。
    @Published var agentSensingEnabled: Bool
    var onCommitAgentSensing: (Bool) -> Void = { _ in }

    /// 在卡片上回答权限/问题(装/卸 http hook + 起/停 server)。默认 false。
    @Published var permissionAnsweringEnabled: Bool
    var onCommitPermissionAnswering: (Bool) -> Void = { _ in }

    /// 交互时冻结 pet(卡片/右键菜单/悬停时不漫步)。默认 true。
    @Published var freezeWhenInteracting: Bool
    var onCommitFreezeWhenInteracting: (Bool) -> Void = { _ in }

    /// 「防休眠」模式 raw —— "off" / "displayAwake" / "systemAwake" / "lidClosedAwake"。默认 "off"。
    /// UserDefaults key: "screenAwakeMode"。改动即时提交(modeless)。
    @Published var screenAwakeModeRaw: String

    /// 防休眠模式 Picker 选项(off 在最前)。raw 与 App 层 `ScreenAwakeMode` 对齐
    /// (Shell 不依赖 App,故用 raw string,与 thermalOverride 同款)。
    let screenAwakeModeOptions: [(id: String, displayName: String)] = [
        ("off", "关闭(正常休眠)"),
        ("displayAwake", "保持屏幕常亮(屏幕不变暗)"),
        ("systemAwake", "仅防系统休眠(屏幕可息屏,挂机联网)"),
        ("lidClosedAwake", "合盖也保持唤醒(无需外接屏 · 需密码)")
    ]

    /// 模式改动即时提交 → 由 App 注入(写 UD + ScreenAwakeController.apply;lidClosedAwake 弹确认+提权)。
    var onCommitScreenAwakeMode: (String) -> Void = { _ in }

    /// 「定时自动关」raw —— ScreenAwakeAutoOff。默认 "never"。UD key: "screenAwakeAutoOff"。
    @Published var screenAwakeAutoOffRaw: String

    /// 定时自动关 Picker 选项(never 在最前)。raw 与 App 层 `ScreenAwakeAutoOff` 对齐。
    let screenAwakeAutoOffOptions: [(id: String, displayName: String)] = [
        ("never", "不自动关"),
        ("min30", "30 分钟后"),
        ("hour1", "1 小时后"),
        ("hour2", "2 小时后"),
        ("hour4", "4 小时后"),
        ("hour8", "8 小时后")
    ]

    /// 自动关时长改动即时提交 → 由 App 注入(写 UD + 重排定时器)。
    var onCommitScreenAwakeAutoOff: (String) -> Void = { _ in }

    /// 「低电量模式时自动关闭防休眠」开关。默认 true。UD key: "screenAwakeDisableOnLowPower"。
    @Published var screenAwakeDisableOnLowPower: Bool

    /// 开关改动即时提交 → 由 App 注入(写 UD + 更新 controller)。
    var onCommitScreenAwakeDisableOnLowPower: (Bool) -> Void = { _ in }

    // MARK: - 系统权限

    /// 四项权限当前状态。初始为空;`refreshPermissions(using:)` 调用后填充。
    @Published var permissionStatuses: [SystemPermission: PermissionStatus] = [:]
    /// 点「授权 / 打开系统设置」→ 由 App 注入(probe.request)。
    var onRequestPermission: (SystemPermission) -> Void = { _ in }
    /// onAppear / 窗口重新激活 → 由 App 注入(刷新四态)。
    var onRefreshPermissions: () -> Void = {}

    /// 用 probe 灌一次四态(App 注入的 onRefreshPermissions 内部调本方法)。
    func refreshPermissions(using probe: SystemPermissionProbe) {
        var next: [SystemPermission: PermissionStatus] = [:]
        for perm in SystemPermission.allCases { next[perm] = probe.status(for: perm) }
        permissionStatuses = next
    }

    // MARK: - 天气

    /// 是否自动跟随当前位置获取天气坐标。
    /// 默认 false — 维持「手选城市」路径,零回归。
    /// UserDefaults key: "weather.autoFollowLocation"。
    @Published var autoFollowLocation: Bool

    /// 开关改动即时提交 → 由 App 注入(写 UD + 请求 CL 授权/更新坐标或回退城市坐标)。
    var onCommitAutoFollowLocation: (Bool) -> Void = { _ in }

    /// 自动跟随时的「真实当前位置」展示文案(逆地理编码城市名 + 真实坐标),由 App 取位后推入。
    /// `nil` = 未在自动跟随 / 定位中。让用户感知定位是否准确(而非显示手选城市的旧坐标)。
    @Published var autoFollowLocationLabel: String?

    /// 当前选中的城市 id (CityCatalog.userDefaultsKey)。
    @Published var selectedCityID: String

    /// 全部内置城市,SwiftUI Picker 列出 displayName。
    let cities: [CityEntry] = CityCatalog.all

    /// 当前选中 city,便于 SwiftUI 显示坐标。
    var selectedCity: CityEntry { CityCatalog.city(forID: selectedCityID) }

    /// 天气模式 raw — "off"(关闭天气效果) / "auto" / "sunny" / "cloudy" / "rainy" / "snowy" / "windy"。
    /// "off" = 关效果(取代旧独立总开关,单选第一项);"auto" = 开效果且跟随真实天气;其余 = 强制对应天气。
    @Published var forcedConditionRaw: String

    /// 由 controller 异步注入(WeatherStateManager.currentSnapshot 文字化)。
    @Published var currentWeatherDescription: String

    /// SwiftUI Picker 用的选项列表。off 在最前(关效果),auto 次之。
    /// 跟 MenuBarController / PetShellWindow.forcedConditionOptions 顺序对齐。
    let forcedConditionOptions: [(id: String, displayName: String)] = [
        ("off", "关闭天气效果"),
        ("auto", "自动(跟随真实天气)"),
        ("sunny", "强制晴天"),
        ("cloudy", "强制多云"),
        ("rainy", "强制下雨"),
        ("snowy", "强制下雪"),
        ("windy", "强制大风")
    ]

    // MARK: - 主动协助

    /// 主动协助全部可调参数。设置面板 Picker + Toggle + Slider 绑定其字段，改动即时 preview。
    @Published var proactiveSettings: ProactiveSettings

    // MARK: - 调试（falling-sand 实时调参）

    /// falling-sand 可调物理参数。调试面板滑块绑定其字段，改动即时 preview。
    @Published var fallingSandTuning: FallingSandTuning

    /// 弹力球抛射回弹可调参数(重力/弹性/阻力/落定…)。调试面板滑块绑定其字段，改动即时 preview。
    @Published var ballisticTuning: BallisticTuning

    /// 温度模式覆盖档 raw — "auto" / "winter" / "spring" / "sauna"（迁移自状态栏菜单）。
    /// "auto" = 跟随天气；具体档 = 覆盖物理沙盒 ambient 温度、无视天气。
    @Published var thermalOverrideRaw: String

    /// SwiftUI Picker 用的温度档选项（auto 在最前）。
    let thermalOverrideOptions: [(id: String, displayName: String)] = ThermalOverrideMode.options

    // MARK: - 关于(只读)

    let aboutVersion: String

    // MARK: - 静态数据(picker option 列表)

    /// LLM provider 名称(index → display)。
    let providerNames: [String] = [
        "OpenAI 兼容 (OpenAI / DeepSeek / Ollama…)",
        "Anthropic Claude"
    ]

    /// 桌宠 plugin 列表。**@Published**(非 let):Shimeji 导入 / 一键安装后调
    /// `refreshPetPlugins` 热刷新,picker 立即出现新宠(填补「装后列表不更新」缺口)。
    @Published var petPlugins: [PetPickerItem]

    /// 按来源分类分组(内置 / Codex 社区 / Shimeji 导入 / Live2D),空分类跳过。
    /// 组内保持注册顺序,组间按 `PetCategory.sortOrder`。SettingsPetSection 据此分组渲染。
    var groupedPlugins: [(category: PetCategory, items: [PetPickerItem])] {
        let grouped = Dictionary(grouping: petPlugins, by: \.category)
        return PetCategory.allCases.compactMap { cat in grouped[cat].map { (cat, $0) } }
    }

    /// picker 搜索词(增量过滤 displayName / id)。空 = 不过滤。
    @Published var petSearchQuery: String = ""

    /// 当前选中的宠物条目(设置页「当前桌宠」卡片用)。找不到 → nil。
    var selectedPetItem: PetPickerItem? {
        petPlugins.first { $0.id == selectedPetPluginID }
    }

    /// 包分组:同 `packId` 的宠物聚成一组(多角色包),无 packId 的各自独立。
    /// SwiftUI `ForEach` 用,`id` 稳定(packId 或单宠 id)。
    struct PetPackGroup: Identifiable {
        let id: String
        let packName: String?
        let items: [PetPickerItem]
        /// 多于 1 只且有包名 → UI 显示可折叠包头;否则平铺(单宠不套壳)。
        var showsPackHeader: Bool { items.count > 1 && packName != nil }
    }

    /// **二级分组**(category → pack):先按 `petSearchQuery` 过滤,再按 category 分组,
    /// 组内按 `packId` 聚包(无 packId 各自独立)。包内保持 `petPlugins` 原序,包之间按
    /// 包内首项的排序位置。SettingsPetSection 三层渲染:category header → pack(可折叠)→ 行。
    var groupedByPack: [(category: PetCategory, packs: [PetPackGroup])] {
        let q = petSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = q.isEmpty ? petPlugins : petPlugins.filter {
            $0.displayName.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
        let byCategory = Dictionary(grouping: filtered, by: \.category)
        return PetCategory.allCases.compactMap { cat in
            guard let items = byCategory[cat], !items.isEmpty else { return nil }
            return (cat, Self.packGroups(items))
        }
    }

    /// 把一个 category 内的 items 聚成包组:同 packId 合并(保首见序),无 packId 各自独立。
    private static func packGroups(_ items: [PetPickerItem]) -> [PetPackGroup] {
        var groups: [PetPackGroup] = []
        var packIndex: [String: Int] = [:]   // packId → groups 下标
        for item in items {
            if let pid = item.packId {
                if let idx = packIndex[pid] {
                    let g = groups[idx]
                    groups[idx] = PetPackGroup(id: g.id, packName: g.packName, items: g.items + [item])
                } else {
                    packIndex[pid] = groups.count
                    groups.append(PetPackGroup(id: pid, packName: item.packName, items: [item]))
                }
            } else {
                groups.append(PetPackGroup(id: item.id, packName: nil, items: [item]))
            }
        }
        return groups
    }

    /// Shimeji 导入状态 —— 转换中显示进度、失败显示错误 banner(SettingsPetSection 绑定)。
    @Published var importInProgress = false
    @Published var importError: String?

    /// 兼容目录(`~/.codex/pets/`)加载开关。改 → 写 PetLibrary + 重建 picker(即时增减兼容宠)。
    @Published var loadCompatLibrary: Bool = PetLibrary.loadCompatEnabled
    /// Codex 宠在线装时同时写一份到兼容目录(跨 Codex 工具共享)。改 → 写 PetLibrary(下次安装生效)。
    @Published var dualWriteCompat: Bool = PetLibrary.dualWriteCompatEnabled

    /// Tool engine kind 列表。raw string 与 ToolEngineKind enum 对齐。
    let toolEngineKinds: [(id: String, displayName: String)] = [
        ("claudeCode", "Claude Code"),
        ("codex", "Codex"),
        ("openCode", "opencode")
    ]

    // MARK: - 计算属性 — placeholder 跟 provider 联动

    var isAnthropic: Bool { selectedProviderIndex == 1 }

    var apiKeyLabel: String { isAnthropic ? "Anthropic Key" : "OpenAI Key" }
    var apiKeyPlaceholder: String { isAnthropic ? "sk-ant-..." : "sk-..." }

    var baseURLPlaceholder: String {
        isAnthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1"
    }

    var baseURLHint: String {
        isAnthropic
            ? "留空使用默认 Anthropic endpoint"
            : "留空使用默认 OpenAI endpoint"
    }

    var modelPlaceholder: String {
        isAnthropic ? "claude-sonnet-4-5" : "gpt-4o-mini"
    }

    var modelHint: String {
        "留空使用所选 provider 的默认 model"
    }

    var toolEngineCLIDisplay: String {
        toolEngineCLIPath.map { "CLI: \($0)" } ?? "CLI: 未安装"
    }

    var islandToggleTitle: String {
        notchAvailable ? "启用灵动岛(刘海机型)" : "灵动岛(未检测到刘海)"
    }

    var islandHidePetTitle: String {
        "灵动岛切桌面时隐藏桌宠(避免遮挡闪烁)"
    }

    /// 已勾选灵动岛 toggle 时才视为开启 — notchAvailable=false 强制返回 false。
    var effectiveIslandOn: Bool {
        notchAvailable ? islandEnabled : false
    }

    // MARK: - Init

    init(
        selectedProviderIndex: Int,
        apiKey: String,
        baseURL: String,
        model: String,
        availablePetPlugins: [PetPluginEntry],
        selectedPetPluginID: String,
        petScale: Double = 1,
        activeDecorativeIDs: Set<String> = [],
        islandEnabled: Bool,
        notchAvailable: Bool,
        islandHidePetOnSwitch: Bool,
        toolModeEnabled: Bool,
        toolEngineKind: String,
        toolEngineCLIPath: String?,
        openClawStatusDescription: String,
        openClawAutoStart: Bool,
        openClawAllowEndpointEnable: Bool,
        launchAtLogin: Bool = false,
        menuBarIconVisible: Bool = false,
        agentSensingEnabled: Bool = true,
        permissionAnsweringEnabled: Bool = false,
        freezeWhenInteracting: Bool = true,
        screenAwakeModeRaw: String = "off",
        screenAwakeAutoOffRaw: String = "never",
        screenAwakeDisableOnLowPower: Bool = true,
        autoFollowLocation: Bool = false,
        selectedCityID: String = CityCatalog.default.id,
        forcedConditionRaw: String = "auto",
        thermalOverrideRaw: String = "auto",
        fallingSandTuning: FallingSandTuning = FallingSandTuning(),
        ballisticTuning: BallisticTuning = BallisticTuning(),
        proactiveSettings: ProactiveSettings = .default,
        currentWeatherDescription: String = "⏳ 等待首次刷新…",
        aboutVersion: String
    ) {
        self.autoFollowLocation = autoFollowLocation
        self.selectedCityID = selectedCityID
        self.forcedConditionRaw = forcedConditionRaw
        self.thermalOverrideRaw = thermalOverrideRaw
        self.fallingSandTuning = fallingSandTuning
        self.ballisticTuning = ballisticTuning
        self.proactiveSettings = proactiveSettings
        self.currentWeatherDescription = currentWeatherDescription
        self.selectedProviderIndex = selectedProviderIndex
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.petPlugins = Self.sortedPickerItems(availablePetPlugins)
        // 未知 id 时回退到第一个 plugin(跟 NSPopUpButton 默认 index 0 一致)。
        if availablePetPlugins.contains(where: { $0.identity.id == selectedPetPluginID }) {
            self.selectedPetPluginID = selectedPetPluginID
        } else if let first = availablePetPlugins.first {
            self.selectedPetPluginID = first.identity.id
        } else {
            self.selectedPetPluginID = selectedPetPluginID
        }
        self.petScale = petScale
        self.activeDecorativeIDs = activeDecorativeIDs
        // 没刘海时强制关 toggle, 跟原 AppKit 行为一致(islandToggle.state=.off)。
        self.islandEnabled = notchAvailable ? islandEnabled : false
        self.notchAvailable = notchAvailable
        self.islandHidePetOnSwitch = islandHidePetOnSwitch
        self.toolModeEnabled = toolModeEnabled
        self.toolEngineKind = toolEngineKind
        self.toolEngineCLIPath = toolEngineCLIPath
        self.openClawStatusDescription = openClawStatusDescription
        self.openClawAutoStart = openClawAutoStart
        self.openClawAllowEndpointEnable = openClawAllowEndpointEnable
        self.launchAtLogin = launchAtLogin
        self.menuBarIconVisible = menuBarIconVisible
        self.agentSensingEnabled = agentSensingEnabled
        self.permissionAnsweringEnabled = permissionAnsweringEnabled
        self.freezeWhenInteracting = freezeWhenInteracting
        self.screenAwakeModeRaw = screenAwakeModeRaw
        self.screenAwakeAutoOffRaw = screenAwakeAutoOffRaw
        self.screenAwakeDisableOnLowPower = screenAwakeDisableOnLowPower
        self.aboutVersion = aboutVersion
    }

    // MARK: - 操作

    /// 选 plugin by id — 找不到就忽略(与 NSPopUpButton 行为一致)。
    /// 主宠改了 → 把新主宠从同屏装饰集移除(主宠不能同时是自己的装饰伙伴),
    /// 触发 `onToggleDecorativePet(id, false)` 让 App 收掉那只可能的装饰副本。
    func selectPetPlugin(_ id: String) {
        guard petPlugins.contains(where: { $0.id == id }) else { return }
        guard id != selectedPetPluginID else { return }   // 同 id 不重复切(防点已选项重建)
        selectedPetPluginID = id
        if activeDecorativeIDs.remove(id) != nil {
            onToggleDecorativePet(id, false)
        }
        onSelectPet(id)   // modeless:选中即时切主宠(持久化 + replaceRenderer),不再等「保存」
    }

    /// 切某宠的「同屏」装饰伙伴状态(库 sheet 的同屏 toggle)。即时生效 + 回调持久化(modeless,无回滚)。
    /// 仅可同屏形象(`canBeDecorative`:非主宠的 Shimeji)可切 —— 自保护,UI gate 之外再守一层,
    /// 防止误把内置 / Live2D 写进装饰集(spawn 时会被静默跳过留下幽灵 id)。
    func toggleDecorativePet(_ id: String) {
        guard let item = petPlugins.first(where: { $0.id == id }), canBeDecorative(item) else { return }
        let on: Bool
        if activeDecorativeIDs.contains(id) {
            activeDecorativeIDs.remove(id)
            on = false
        } else {
            activeDecorativeIDs.insert(id)
            on = true
        }
        onToggleDecorativePet(id, on)
    }

    /// 某宠是否可作「同屏装饰伙伴」:仅 Shimeji 导入形象(自管窗口位置 + 引擎),且非当前主宠。
    /// 其余形象(内置 SDF / Codex sprite / Live2D)装饰伙伴运行时暂不支持 → 不显示同屏 toggle。
    func canBeDecorative(_ item: PetPickerItem) -> Bool {
        item.category == .shimejiImport && item.id != selectedPetPluginID
    }

    // MARK: - 整包同屏(S5)

    /// 整包同屏的三态:`empty`=包内无成员激活 / `partial`=部分激活 / `all`=全部可同屏成员都激活。
    /// (用 `empty` 而非 `none` —— 避免与返回类型 `PackDecorativeState?` 的 `Optional.none` 撞名。)
    enum PackDecorativeState { case empty, partial, all }

    /// 包内**可同屏**(`canBeDecorative`)的成员 id —— 排除主宠 + 非 Shimeji 成员。
    func decorativeMembers(of pack: PetPackGroup) -> [String] {
        pack.items.filter { canBeDecorative($0) }.map(\.id)
    }

    /// 包整体同屏态;**无可同屏成员 → nil**(UI 不显示「全部同屏」整包 toggle,如整包成员都已是主宠/非 Shimeji)。
    func packDecorativeState(_ pack: PetPackGroup) -> PackDecorativeState? {
        let members = decorativeMembers(of: pack)
        guard !members.isEmpty else { return nil }
        let active = members.filter { activeDecorativeIDs.contains($0) }.count
        if active == 0 { return .empty }
        return active == members.count ? .all : .partial
    }

    /// 整包同屏 toggle(库 sheet 包头「全部同屏」)：全员已激活 → 全下屏;否则 → 全上屏(只动可同屏成员)。
    /// **一次批量回调**(非逐只)→ App 单次 `setDecorativePetIDs` + 单次 spawn/despawn 对齐,免中间态闪烁。
    func toggleWholePack(_ pack: PetPackGroup) {
        let members = decorativeMembers(of: pack)
        guard !members.isEmpty else { return }
        let turnOn = !members.allSatisfy { activeDecorativeIDs.contains($0) }
        if turnOn {
            members.forEach { activeDecorativeIDs.insert($0) }
        } else {
            members.forEach { activeDecorativeIDs.remove($0) }
        }
        onToggleDecorativePack(members, turnOn)
    }

    /// 热刷新 picker 列表(Shimeji 导入 / 一键安装后 re-discover 调)。@Published 触发
    /// SettingsPetSection 立即重渲染。`selectIfNew` 非空 + 在新列表里 → 顺带选中(刚装的宠)。
    func refreshPetPlugins(_ entries: [PetPluginEntry], selectIfNew: String? = nil) {
        petPlugins = Self.sortedPickerItems(entries)
        if let sel = selectIfNew, petPlugins.contains(where: { $0.id == sel }) {
            selectedPetPluginID = sel
        } else if !petPlugins.contains(where: { $0.id == selectedPetPluginID }), let first = petPlugins.first {
            // 当前选中已不在列表(如关兼容目录后那只 compat 宠消失)→ 回退首项,
            // 避免 stale id 被保存 + 渲染到已隐藏宠(review HIGH-2)。
            selectedPetPluginID = first.id
        }
    }

    /// 重建 picker 列表:re-discover sprite 包(自有库 + 兼容目录,respect 开关)+ Live2D
    /// 模型包(自有 live2d/ 子目录)+ register + 内置形象(从 registry 取 .builtin)合并刷新。
    /// 用 discover() 结果而非 registry.all,确保关兼容开关后兼容宠从 picker 消失(registry
    /// 累积不删,但列表只含当前 discover + 内置)。Shimeji/Live2D 导入 / Codex 在线装 /
    /// 切兼容开关后调。
    func rebuildPetList(selectIfNew: String? = nil) {
        let discovered = CodexSpritePackLoader.discover()
        let live2d = Live2DModelPackLoader.discover()
        for entry in discovered + live2d { PetPluginRegistry.shared.register(entry) }
        let builtins = PetPluginRegistry.shared.all.filter { $0.identity.category == .builtin }
        refreshPetPlugins(builtins + discovered + live2d, selectIfNew: selectIfNew)
    }

    /// 删除一只宠物:删磁盘包目录 + 注销 registry + 重建 picker(选中若被删 → 自动回退首项)。
    /// 仅磁盘发现的宠物(`installPath != nil`)可删;内置形象无 installPath → 静默忽略。
    func deletePet(_ id: String) {
        guard let entry = PetPluginRegistry.shared.plugin(for: id), let path = entry.installPath else { return }
        do {
            try PetLibrary.removePack(at: path)
        } catch {
            importError = "删除失败:\(error)"
            return
        }
        PetPluginRegistry.shared.remove(id: id)
        rebuildPetList()   // re-discover 不含已删目录 → 从列表消失;refreshPetPlugins 处理选中回退
    }

    /// 切兼容目录(`~/.codex/pets/`)加载开关 → 写 PetLibrary + 重建 picker(即时增减兼容宠)。
    func setLoadCompatLibrary(_ on: Bool) {
        guard on != PetLibrary.loadCompatEnabled else { return }
        PetLibrary.loadCompatEnabled = on
        loadCompatLibrary = on
        rebuildPetList()
    }

    /// 切「Codex 宠同时装兼容目录」开关 → 写 PetLibrary(下次在线安装时生效)。
    func setDualWriteCompat(_ on: Bool) {
        PetLibrary.dualWriteCompatEnabled = on
        dualWriteCompat = on
    }

    /// entries → PetPickerItem 并**稳定排序**(组间 category.sortOrder,组内 displayName)。
    /// `PetPluginRegistry.all` 返回 dict values(无序)→ 不排序则 picker 每次渲染抖动。
    private static func sortedPickerItems(_ entries: [PetPluginEntry]) -> [PetPickerItem] {
        entries.map(PetPickerItem.init(entry:)).sorted { lhs, rhs in
            lhs.category.sortOrder != rhs.category.sortOrder
                ? lhs.category.sortOrder < rhs.category.sortOrder
                : lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// 导入 Shimeji 包(.zip 或目录)→ 转换 → 装进 `~/.codex/pets/` → re-discover + register →
    /// 热刷新 picker + 选中新宠。转换(解压 + 图像 IO,阻塞)在后台线程,完成回主线程刷新。
    /// 由 SettingsPetSection 的「导入」按钮 / 拖入触发。
    func importShimeji(from url: URL) {
        guard !importInProgress else { return }
        importInProgress = true
        importError = nil
        let dest = PetLibrary.installDir(for: .shimeji)   // ~/.petagent/pets/shimeji/
        Task { [weak self] in
            defer { self?.importInProgress = false }   // 所有路径(成功/失败/self 释放)都复位,防按钮卡死
            do {
                let outDirs = try await Task.detached(priority: .userInitiated) {
                    try ShimejiPackConverter.convertZipOrDir(at: url, outputParentDir: dest)
                }.value
                guard let self else { return }
                // 回主线程:重建 picker(re-discover 自有+兼容 + register + 刷新)+ 选中新宠。
                // 多角色包 → N 个 outDir;自动选中首个(按 slug 排序),其余出现在列表供用户点选。
                // newID 与 convert 的 slug 来源(outDir 名)对齐;若 convert 日后改 slug 来源此处需同步。
                let newID = outDirs.first.map { CodexSpritePackLoader.idPrefix + $0.lastPathComponent }
                self.rebuildPetList(selectIfNew: newID)
            } catch {
                self?.importError = Self.importErrorText(error)
            }
        }
    }

    /// 拖入路由:含 `*.model3.json` → 当 Live2D 模型装;否则按 Shimeji 处理(若也非
    /// shimeji 包,importShimeji 会给出清晰错误)。单一拖入区智能分流,用户无需先选类型。
    func importDropped(from url: URL) {
        if Live2DModelInstaller.containsModel3(at: url) {
            importLive2DModel(from: url)
        } else {
            importShimeji(from: url)
        }
    }

    /// 导入 Live2D 模型包(.zip 或目录)→ 整包拷进 `~/.petagent/pets/live2d/` → re-discover +
    /// register → 热刷新 picker + 选中新模型。拷贝(可能含解压,阻塞)在后台线程,完成回主线程刷新。
    /// 由 SettingsPetSection 的「导入 Live2D 模型」按钮 / 拖入触发。D-1 阶段装好即出现在 picker
    /// 「Live2D」分组,选中后渲染为 placeholder(真渲染待 D-2)。
    func importLive2DModel(from url: URL) {
        guard !importInProgress else { return }
        importInProgress = true
        importError = nil
        let dest = PetLibrary.installDir(for: .live2d)   // ~/.petagent/pets/live2d/
        Task { [weak self] in
            defer { self?.importInProgress = false }   // 所有路径都复位,防按钮卡死
            do {
                let outDir = try await Task.detached(priority: .userInitiated) {
                    try Live2DModelInstaller.install(from: url, into: dest)
                }.value
                guard let self else { return }
                let newID = Live2DModelPackLoader.idPrefix + outDir.lastPathComponent
                // 导入后离屏渲一帧生成缩略图缓存 → rebuild 即显示预览图(否则新模型只有占位图标)。
                Live2DModelPackLoader.generateThumbnail(forPackDir: outDir)
                self.rebuildPetList(selectIfNew: newID)
            } catch {
                self?.importError = Self.live2DImportErrorText(error)
            }
        }
    }

    /// Live2DModelInstaller.InstallError → 用户可读中文。
    private static func live2DImportErrorText(_ error: Error) -> String {
        guard let e = error as? Live2DModelInstaller.InstallError else {
            return "导入失败:\(error.localizedDescription)"
        }
        switch e {
        case .noModelFound: return "没找到 *.model3.json(确认是 Live2D Cubism 模型包)"
        case .unzipFailed: return "解压失败(.zip 可能损坏或含非法路径)"
        case .copyFailed: return "拷贝 / 写入失败"
        }
    }

    /// ConvertError → 用户可读中文。
    private static func importErrorText(_ error: Error) -> String {
        guard let e = error as? ShimejiPackConverter.ConvertError else {
            return "导入失败:\(error.localizedDescription)"
        }
        switch e {
        case .noFramesFound: return "没找到 shimeN.png(确认是 Shimeji 包:含 img/<角色>/shime1.png)"
        case .unzipFailed: return "解压失败(.zip 可能损坏)"
        case .packFailed, .writeFailed: return "转换 / 写入失败"
        }
    }

    /// 选 tool engine kind by raw — 找不到就忽略。
    func selectToolEngineKind(_ raw: String) {
        guard toolEngineKinds.contains(where: { $0.id == raw }) else { return }
        toolEngineKind = raw
    }

    /// 选城市 by id — 找不到就忽略。
    func selectCity(_ id: String) {
        guard cities.contains(where: { $0.id == id }) else { return }
        selectedCityID = id
    }

    /// Preview callback — 用户在 Picker 改了城市 / 强制天气,
    /// **立刻拉新天气数据看效果, 但不持久化到 UserDefaults**。
    /// 配合保存(确认)/ 取消(回滚)三态:
    ///   - Picker change → onCityPreview / onForcedConditionPreview (拉数据)
    ///   - 点保存       → onSaveCity / onSaveForcedCondition (写 UD)
    ///   - 点取消       → controller 用 originalCity / originalForcedCondition
    ///                    再次 onCityPreview 回滚到原数据
    /// SettingsWeatherSection.onChange 触发 onXxxPreview。
    var onCityPreview: (String) -> Void = { _ in }
    var onForcedConditionPreview: (String) -> Void = { _ in }
    /// 温度档 preview — 切档立刻覆盖 ambient 看效果，不写 UD（保存才持久化）。
    var onThermalOverridePreview: (String) -> Void = { _ in }
    /// 调试调参 preview — 拖滑块立刻应用到 driver 看效果，不写 UD。
    var onFallingSandTuningPreview: (FallingSandTuning) -> Void = { _ in }
    /// 弹力球抛射调参 preview — 拖滑块立刻应用到 PetMotionController.tuning 看效果。
    var onBallisticTuningPreview: (BallisticTuning) -> Void = { _ in }
    /// 主动协助 preview — 改设置立刻热更新引擎看效果，不写 UD。
    var onProactiveSettingsPreview: (ProactiveSettings) -> Void = { _ in }
    /// PF6 桌宠大小 preview — 拖滑杆立刻缩放桌宠看效果，不写 UD。
    var onPetScalePreview: (Double) -> Void = { _ in }
    /// 多宠同屏 toggle — 勾/取消「同屏」即时 spawn/despawn 装饰伙伴 + 持久化 UD(modeless,无回滚)。
    var onToggleDecorativePet: (String, Bool) -> Void = { _, _ in }
    /// 整包同屏 toggle(S5)— 一批成员 id 一次性上/下屏 + 持久化(批量,免逐只 N 次 sync)。
    var onToggleDecorativePack: ([String], Bool) -> Void = { _, _ in }

    // MARK: - Modeless 即时提交回调(controller 接到 App 的「持久化 + 应用」闭包)
    // 全面 modeless(去掉「保存」按钮):每个控件改动即时生效并持久化,文本框(LLM)在
    // 回车 / 关窗时提交(避免每键击都热重载 provider)。

    /// 选中主宠即时切换(持久化 pet.plugin.id + replacePetRenderer + syncDecorativePets)。
    var onSelectPet: (String) -> Void = { _ in }
    var onCommitIsland: (Bool) -> Void = { _ in }
    var onCommitIslandHidePet: (Bool) -> Void = { _ in }
    var onCommitToolMode: (Bool) -> Void = { _ in }
    var onCommitToolEngine: (String) -> Void = { _ in }
    var onCommitOpenClawAutoStart: (Bool) -> Void = { _ in }
    var onCommitOpenClawAllowEndpoint: (Bool) -> Void = { _ in }
    /// LLM(provider/key/baseURL/model)提交 —— 文本框 onSubmit / 关窗时调。
    var onCommitLLM: () -> Void = {}

    /// 重置调参为工厂默认（调试面板「重置默认」按钮）。即时 preview。
    func resetFallingSandTuning() {
        fallingSandTuning = FallingSandTuning()
        onFallingSandTuningPreview(fallingSandTuning)
    }

    /// 重置弹力球抛射调参为工厂默认。即时 preview。
    func resetBallisticTuning() {
        ballisticTuning = BallisticTuning()
        onBallisticTuningPreview(ballisticTuning)
    }

    /// 重置主动协助设置为工厂默认（「重置默认」按钮）。即时 preview(modeless,无回滚)。
    func resetProactiveSettings() {
        proactiveSettings = .default
        onProactiveSettingsPreview(proactiveSettings)
    }
}
