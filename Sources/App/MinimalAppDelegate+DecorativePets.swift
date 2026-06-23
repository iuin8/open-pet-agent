import AppKit
import Context
import PetBehavior
import Rendering
import Shell
import Shimeji

/// Phase 2 多宠同屏 —— 装饰物理伙伴(主宠之外的额外桌宠)的 spawn / despawn / 帧驱动。
/// 设计见 docs/pet-library-and-multipet-design.md §5。主宠保持现有完整 stack;装饰伙伴是轻量
/// `DecorativePet` 窗口 + 配对 `ShimejiPetRenderer`,无 chat / emotion / 雪 occluder。
@MainActor
extension MinimalAppDelegate {

    /// 想要在屏上的装饰伙伴 id 集(UD plist `[String]`,排除主宠自身,去重保序)。
    func wantedDecorativePetIDs() -> [String] {
        let primary = userDefaults.string(forKey: Self.petPluginUserDefaultsKey) ?? "orb"
        let ids = userDefaults.stringArray(forKey: Self.decorativePetIDsKey) ?? []
        var seen = Set<String>()
        return ids.filter { $0 != primary && seen.insert($0).inserted }
    }

    /// 持久化装饰伙伴 id 集(picker 多选改完调)。
    func setDecorativePetIDs(_ ids: [String]) {
        userDefaults.set(ids, forKey: Self.decorativePetIDsKey)
        syncDecorativePets()
    }

    /// 让屏上装饰伙伴与 `wantedDecorativePetIDs()` 对齐:多的下屏、缺的上屏。出生 x 错开。
    func syncDecorativePets() {
        let wanted = wantedDecorativePetIDs()
        // despawn 不再需要的
        for entry in decorativePets where !wanted.contains(entry.pet.id) { entry.pet.close() }
        decorativePets.removeAll { !wanted.contains($0.pet.id) }
        // spawn 缺的(错开出生 x,避免全叠在屏幕中央)
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var slot = 0
        for id in wanted where !decorativePets.contains(where: { $0.pet.id == id }) {
            // 错开出生 x + 唯一 seed → 各宠独立漫步、不重叠(否则同 anchor+同 seed 完全重合)。
            let spawnX = Double(screen.width) * 0.2 + Double(slot) * 220
            let seed = UInt64(0x5EED) &+ UInt64(slot &+ 1) &* 0x9E3779B97F4A7C15
            spawnDecorativePet(id: id, screenFrame: screen, spawnX: spawnX, seed: seed)
            slot += 1
        }
    }

    /// 起一只装饰伙伴:plugin 的 packDir → **直接建** ShimejiPetRenderer(唯一 anchor + seed,
    /// 不走共享工厂的固定 anchor/seed)→ DecorativePet 上屏。无 conf/img 运行时数据(`installPath`
    /// 缺 / 非 Shimeji 形象)→ 静默跳过(MVP 装饰伙伴限自管位置的 Shimeji 引擎形象)。
    private func spawnDecorativePet(id: String, screenFrame: NSRect, spawnX: Double, seed: UInt64) {
        guard let entry = PetPluginRegistry.shared.plugin(for: id),
              let packDir = entry.installPath else { return }
        let env = makeShimejiEnvironment(snapshot: .empty)
        guard let renderer = ShimejiPetRenderer(
            packDir: packDir, anchor: BehaviorPoint(x: spawnX, y: -100), environment: env, seed: seed)
        else { return }
        let pet = DecorativePet(
            id: id, renderer: renderer, screenFrame: screenFrame, spawnX: spawnX,
            onSetAsPrimary: { [weak self] in self?.promoteToPrimary(id: id) },
            onOpenSettings: { [weak self] in self?.showSettingsWindow() },
            onQuit: { NSApp.terminate(nil) })
        renderer.applyScale(CGFloat(petScaleSetting))   // 跟随全局大小
        decorativePets.append((pet, renderer))
    }

    // MARK: - 右键「设为主宠」

    /// 装饰宠升为主宠(右键菜单)。交换语义:新宠升主宠;旧主宠若**可同屏**(Shimeji 导入形象)则
    /// 降为装饰伙伴留屏,否则随主宠替换消失(orb/Live2D 不能当装饰)。复用主宠切换链
    /// (replacePetRenderer + 同步装饰窗口),与库里选主宠一致。
    func promoteToPrimary(id newID: String) {
        let oldID = userDefaults.string(forKey: Self.petPluginUserDefaultsKey) ?? "orb"
        guard newID != oldID, let plugin = PetPluginRegistry.shared.plugin(for: newID) else { return }
        let oldCanDecorate = PetPluginRegistry.shared.plugin(for: oldID)?.identity.category == .shimejiImport
        let current = userDefaults.stringArray(forKey: Self.decorativePetIDsKey) ?? []
        let nextIDs = Self.decorativeIDsAfterPromote(
            current: current, newPrimary: newID, oldPrimary: oldID, oldCanDecorate: oldCanDecorate)
        userDefaults.set(nextIDs, forKey: Self.decorativePetIDsKey)
        userDefaults.set(newID, forKey: Self.petPluginUserDefaultsKey)
        shellController?.replacePetRenderer(with: plugin.makeRenderer(),
                                            recommendedSize: plugin.identity.recommendedSize)
        if petScaleSetting != 1 { shellController?.setPetScale(CGFloat(petScaleSetting)) }
        syncDecorativePets()   // despawn 新主宠的装饰副本 + spawn 旧主宠(若降级为装饰)
    }

    /// 升主宠后的装饰 id 集(纯逻辑,便于单测):去掉新主宠;旧主宠若可同屏则补进(交换),去重。
    nonisolated static func decorativeIDsAfterPromote(
        current: [String], newPrimary: String, oldPrimary: String, oldCanDecorate: Bool
    ) -> [String] {
        var ids = current.filter { $0 != newPrimary }
        if oldCanDecorate, oldPrimary != newPrimary, !ids.contains(oldPrimary) { ids.append(oldPrimary) }
        return ids
    }

    /// 帧循环每帧:把每只装饰伙伴各自 tick 一拍 → 摆窗。每只注入自己的 `scanTarget`(广播匹配的邻居,
    /// 供包内 `ScanMove`/Hug 用),tick 后落地它产出的配对(把目标 pet 切到 TargetBehavior)。
    func driveDecorativePets(snapshot: DesktopSnapshot) {
        guard !decorativePets.isEmpty else { return }
        let baseEnv = makeShimejiEnvironment(snapshot: snapshot)
        let all = allShimejiPets()
        for entry in decorativePets {
            var env = baseEnv
            env.scanTarget = scanTarget(forID: entry.pet.id, anchor: entry.renderer.anchor, among: all)
            if let frame = entry.renderer.advance(environment: env) {
                entry.pet.setFrame(frame)
            }
            applyOutgoingPairing(from: entry.renderer, among: all)
        }
    }

    // MARK: - 多宠互动:affordance 广播/扫描配对(Hug 系)

    /// 主宠在 pet 列表里的 sentinel id(配对回切目标用)。
    static let primaryPetID = "__primary__"
    /// 扫描注意范围(像素):广播者在此半径内才会被扫到。够大,Hug 不挑距离(faithful:Shimeji 全屏找)。
    static let scanRange: Double = 1200

    /// 屏上所有 Shimeji pet:(id, renderer)。主宠(若 Shimeji)+ 装饰宠。
    func allShimejiPets() -> [(id: String, renderer: ShimejiPetRenderer)] {
        var out: [(id: String, renderer: ShimejiPetRenderer)] = []
        if let primary = shellController?.petRenderer as? ShimejiPetRenderer {
            out.append((Self.primaryPetID, primary))
        }
        for entry in decorativePets { out.append((entry.pet.id, entry.renderer)) }
        return out
    }

    /// 为某 pet 算 `scanTarget`:在其它 pet 里找**正在广播 affordance** 的最近一只(范围内)。
    /// 谁广播由各引擎 `offeredAffordance` 报告;ScanMove 再按自身 Affordance 与之匹配(故这里带上 affordance)。
    func scanTarget(forID id: String, anchor: BehaviorPoint,
                    among all: [(id: String, renderer: ShimejiPetRenderer)]) -> BehaviorPeer? {
        var best: (peer: BehaviorPeer, dist: Double)?
        for other in all where other.id != id {
            guard let aff = other.renderer.offeredAffordance else { continue }
            let oa = other.renderer.anchor
            let dx = oa.x - anchor.x, dy = oa.y - anchor.y
            let dist = (dx * dx + dy * dy).squareRoot()
            guard dist <= Self.scanRange else { continue }
            if best == nil || dist < best!.dist {
                best = (BehaviorPeer(id: other.id, anchor: oa, affordance: aff), dist)
            }
        }
        return best?.peer
    }

    /// 落地一只 pet tick 后产出的配对:把目标 pet(by id)切到 TargetBehavior(自己已被其引擎切好)。
    func applyOutgoingPairing(from renderer: ShimejiPetRenderer,
                             among all: [(id: String, renderer: ShimejiPetRenderer)]) {
        guard let pairing = renderer.consumeOutgoingPairing() else { return }
        all.first { $0.id == pairing.targetID }?.renderer.triggerBehavior(named: pairing.behavior)
    }

    /// 建 top-origin `BehaviorEnvironment`(主宠 + 装饰伙伴共用;各引擎自持 anchor)。
    /// 从 driveShimejiPet 提取,避免两处重复构造。
    func makeShimejiEnvironment(snapshot: DesktopSnapshot) -> BehaviorEnvironment {
        let visible = currentScreenFrame()
        let fullScreen = NSScreen.main?.frame ?? visible
        return shimejiEnvironmentProvider.environment(
            snapshot: snapshot,
            workAreaBottomOrigin: Rect(
                origin: Point(x: Double(visible.minX), y: Double(visible.minY)),
                width: Double(visible.width),
                height: Double(visible.height)),
            screenWidth: Double(fullScreen.width),
            screenHeight: Double(fullScreen.height))
    }
}
