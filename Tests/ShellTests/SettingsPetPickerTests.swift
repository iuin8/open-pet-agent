import Testing
import AppKit
import Rendering
@testable import Shell

@Suite("SettingsViewModel 桌宠 picker 分组 + 热刷新")
@MainActor
struct SettingsPetPickerTests {

    private func entry(_ id: String, _ name: String, _ cat: PetCategory,
                       packId: String? = nil, packName: String? = nil) -> PetPluginEntry {
        PetPluginEntry(
            identity: PetIdentity(id: id, displayName: name, recommendedSize: .zero, category: cat,
                                  packId: packId, packName: packName),
            makeRenderer: { nil })
    }

    private func makeVM(_ entries: [PetPluginEntry], selected: String) -> SettingsViewModel {
        SettingsViewModel(
            selectedProviderIndex: 0, apiKey: "", baseURL: "", model: "",
            availablePetPlugins: entries, selectedPetPluginID: selected,
            islandEnabled: false, notchAvailable: false, islandHidePetOnSwitch: false,
            agentModeEnabled: false, agentEngineKind: "claudeCode", agentEngineCLIPath: nil,
            openClawStatusDescription: "", openClawAutoStart: false, openClawAllowEndpointEnable: false,
            aboutVersion: "test")
    }

    @Test("groupedPlugins 按来源分组 + 组间 sortOrder + 组内保序 + 空组跳过")
    func groupsByCategory() {
        let vm = makeVM([
            entry("orb", "弹力球", .builtin),
            entry("codex:ferris", "Ferris", .codexCommunity),
            entry("codex:neko", "猫", .shimejiImport),
            entry("slime", "史莱姆", .builtin),
        ], selected: "orb")

        let groups = vm.groupedPlugins
        // 组间顺序:builtin(0) → codexCommunity(1) → shimejiImport(2);live2d 空跳过。
        #expect(groups.map(\.category) == [.builtin, .codexCommunity, .shimejiImport])
        // 组内保持注册顺序(orb 在 slime 前)。
        #expect(groups[0].items.map(\.id) == ["orb", "slime"])
        #expect(groups[1].items.map(\.id) == ["codex:ferris"])
        #expect(groups[2].items.map(\.id) == ["codex:neko"])
    }

    @Test("PetPickerItem 从 entry 带出 category + displayName")
    func pickerItemCarriesCategory() {
        let vm = makeVM([entry("codex:x", "X", .shimejiImport)], selected: "codex:x")
        let item = try? #require(vm.petPlugins.first)
        #expect(item?.category == .shimejiImport)
        #expect(item?.displayName == "X")
    }

    @Test("refreshPetPlugins 热刷新列表 + selectIfNew 选中新装的宠")
    func refreshesAndSelects() {
        let vm = makeVM([entry("orb", "弹力球", .builtin)], selected: "orb")
        #expect(vm.petPlugins.count == 1)

        vm.refreshPetPlugins([
            entry("orb", "弹力球", .builtin),
            entry("codex:newpet", "新宠", .shimejiImport),
        ], selectIfNew: "codex:newpet")

        #expect(vm.petPlugins.count == 2)
        #expect(vm.selectedPetPluginID == "codex:newpet")   // 顺带选中刚装的
        #expect(vm.groupedPlugins.contains { $0.category == .shimejiImport })
    }

    @Test("refreshPetPlugins selectIfNew 不在列表 → 不改选中")
    func refreshKeepsSelectionWhenNewMissing() {
        let vm = makeVM([entry("orb", "弹力球", .builtin)], selected: "orb")
        vm.refreshPetPlugins([entry("orb", "弹力球", .builtin)], selectIfNew: "codex:ghost")
        #expect(vm.selectedPetPluginID == "orb")
    }

    // MARK: - groupedByPack(二级包分组)

    @Test("groupedByPack 同 packId 聚成一组 + 无 packId 各自独立")
    func groupsByPack() {
        let vm = makeVM([
            entry("codex:blue", "Blue", .shimejiImport, packId: "alan", packName: "Alan 包"),
            entry("codex:red", "Red", .shimejiImport, packId: "alan", packName: "Alan 包"),
            entry("codex:solo", "独行侠", .shimejiImport),   // 无 packId
        ], selected: "codex:blue")

        let shimeji = try? #require(vm.groupedByPack.first { $0.category == .shimejiImport })
        let packs = shimeji?.packs ?? []
        // alan 包(blue+red)聚成一组,有包头;solo 独立成组,无包头。
        let alanPack = packs.first { $0.id == "alan" }
        #expect(alanPack?.items.map(\.id) == ["codex:blue", "codex:red"])
        #expect(alanPack?.showsPackHeader == true)
        let soloPack = packs.first { $0.items.first?.id == "codex:solo" }
        #expect(soloPack?.showsPackHeader == false)
        #expect(soloPack?.packName == nil)
    }

    @Test("单只 packId 包不显示包头(不套折叠壳)")
    func singletonPackNoHeader() {
        let vm = makeVM([
            entry("codex:lone", "孤宠", .shimejiImport, packId: "p1", packName: "包1"),
        ], selected: "codex:lone")
        let pack = vm.groupedByPack.first?.packs.first
        #expect(pack?.showsPackHeader == false)   // 包内仅 1 只 → 平铺
    }

    @Test("petSearchQuery 增量过滤 displayName / id")
    func searchFilters() {
        let vm = makeVM([
            entry("orb", "弹力球", .builtin),
            entry("codex:ferris", "Ferris 螃蟹", .codexCommunity),
            entry("codex:neko", "小猫", .shimejiImport),
        ], selected: "orb")

        vm.petSearchQuery = "猫"
        let ids = vm.groupedByPack.flatMap { $0.packs.flatMap { $0.items.map(\.id) } }
        #expect(ids == ["codex:neko"])

        vm.petSearchQuery = "ferris"   // 按 id 匹配(大小写不敏感)
        let ids2 = vm.groupedByPack.flatMap { $0.packs.flatMap { $0.items.map(\.id) } }
        #expect(ids2 == ["codex:ferris"])

        vm.petSearchQuery = ""   // 清空 → 全部
        #expect(vm.groupedByPack.flatMap { $0.packs }.flatMap { $0.items }.count == 3)
    }

    // MARK: - S5 整包同屏

    /// 拿 shimeji 分组里的某个 packId 包(测试用)。
    private func pack(_ vm: SettingsViewModel, _ packId: String) -> SettingsViewModel.PetPackGroup? {
        vm.groupedByPack.lazy.flatMap(\.packs).first { $0.id == packId }
    }

    @Test("整包同屏:packDecorativeState 三态(empty/partial/all)")
    func packDecorativeStateThreeWay() {
        let vm = makeVM([
            entry("orb", "弹力球", .builtin),
            entry("codex:blue", "Blue", .shimejiImport, packId: "alan", packName: "Alan 包"),
            entry("codex:red", "Red", .shimejiImport, packId: "alan", packName: "Alan 包"),
        ], selected: "orb")
        let alan = try! #require(pack(vm, "alan"))

        #expect(vm.packDecorativeState(alan) == .empty)          // 一只没激活
        vm.activeDecorativeIDs = ["codex:blue"]
        #expect(vm.packDecorativeState(alan) == .partial)        // 激活一半
        vm.activeDecorativeIDs = ["codex:blue", "codex:red"]
        #expect(vm.packDecorativeState(alan) == .all)            // 全激活
    }

    @Test("整包同屏:主宠成员被排除,decorativeMembers 只含可同屏成员")
    func packDecorativeMembersExcludePrimary() {
        let vm = makeVM([
            entry("codex:blue", "Blue", .shimejiImport, packId: "alan", packName: "Alan 包"),
            entry("codex:red", "Red", .shimejiImport, packId: "alan", packName: "Alan 包"),
        ], selected: "codex:blue")   // blue 是主宠
        let alan = try! #require(pack(vm, "alan"))
        #expect(vm.decorativeMembers(of: alan) == ["codex:red"])   // 主宠 blue 排除
        vm.activeDecorativeIDs = ["codex:red"]
        #expect(vm.packDecorativeState(alan) == .all)              // 唯一可同屏成员激活 = 全
    }

    @Test("整包同屏:toggleWholePack 全上屏 → 批量回调全员 + 同步 activeDecorativeIDs")
    func toggleWholePackTurnsAllOn() {
        let vm = makeVM([
            entry("orb", "弹力球", .builtin),
            entry("codex:blue", "Blue", .shimejiImport, packId: "alan", packName: "Alan 包"),
            entry("codex:red", "Red", .shimejiImport, packId: "alan", packName: "Alan 包"),
        ], selected: "orb")
        var events: [(ids: [String], on: Bool)] = []
        vm.onToggleDecorativePack = { events.append((ids: $0, on: $1)) }
        let alan = try! #require(pack(vm, "alan"))

        vm.toggleWholePack(alan)   // 空 → 全上屏
        #expect(events.count == 1)
        #expect(Set(events[0].ids) == ["codex:blue", "codex:red"])
        #expect(events[0].on == true)
        #expect(vm.activeDecorativeIDs == ["codex:blue", "codex:red"])
    }

    @Test("整包同屏:全激活时 toggleWholePack → 全下屏")
    func toggleWholePackTurnsAllOff() {
        let vm = makeVM([
            entry("orb", "弹力球", .builtin),
            entry("codex:blue", "Blue", .shimejiImport, packId: "alan", packName: "Alan 包"),
            entry("codex:red", "Red", .shimejiImport, packId: "alan", packName: "Alan 包"),
        ], selected: "orb")
        vm.activeDecorativeIDs = ["codex:blue", "codex:red"]
        var events: [(ids: [String], on: Bool)] = []
        vm.onToggleDecorativePack = { events.append((ids: $0, on: $1)) }
        let alan = try! #require(pack(vm, "alan"))

        vm.toggleWholePack(alan)   // 全激活 → 全下屏
        #expect(events.last?.on == false)
        #expect(vm.activeDecorativeIDs.isEmpty)
    }

    @Test("整包同屏:部分激活时 toggleWholePack → 补齐到全(turnOn)")
    func toggleWholePackPartialFillsToAll() {
        let vm = makeVM([
            entry("codex:blue", "Blue", .shimejiImport, packId: "alan", packName: "Alan 包"),
            entry("codex:red", "Red", .shimejiImport, packId: "alan", packName: "Alan 包"),
        ], selected: "orb")
        vm.activeDecorativeIDs = ["codex:blue"]   // 部分
        var events: [(ids: [String], on: Bool)] = []
        vm.onToggleDecorativePack = { events.append((ids: $0, on: $1)) }
        let alan = try! #require(pack(vm, "alan"))

        vm.toggleWholePack(alan)   // 部分 → 补齐全上屏
        #expect(events.last?.on == true)
        #expect(vm.activeDecorativeIDs == ["codex:blue", "codex:red"])
    }

    @Test("整包同屏:全员都是非 Shimeji / 都是主宠 → 无可同屏成员 → state nil 不显示整包 toggle")
    func packNoEligibleMembersNoToggle() {
        // 单只 packId 包不显示包头本就不会进整包 toggle;这里验「有包头但成员不可同屏」→ nil。
        let vm = makeVM([
            entry("codex:a", "A", .codexCommunity, packId: "p", packName: "P 包"),   // 非 shimeji
            entry("codex:b", "B", .codexCommunity, packId: "p", packName: "P 包"),
        ], selected: "orb")
        let p = try! #require(pack(vm, "p"))
        #expect(vm.decorativeMembers(of: p).isEmpty)
        #expect(vm.packDecorativeState(p) == nil)   // → UI 不显示「全部同屏」
    }
}
