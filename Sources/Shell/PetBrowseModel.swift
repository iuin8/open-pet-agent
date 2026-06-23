import AppKit
import Combine
import PetCatalog
import Rendering

/// PF3 Codex 在线桌宠浏览/安装的视图模型(蓝本 agentpet PetBrowser)。拉 petdex manifest →
/// 按 kind/query 过滤 → 一键下载装进 `~/.codex/pets/` → 回调 `onInstalled` 让设置面板热刷新
/// picker。网络/安装经 `PetCatalog`(可注入 mock 全测)。`installed` 扫已装目录得出 → 已装显示
/// 「已装」而非「获取」。**安装 ≠ 选中**(两步,符合 VS Code/Obsidian 习惯):装只入库,用户回
/// picker 自己选。
@MainActor
final class PetBrowseModel: ObservableObject {
    @Published var pets: [RemotePet] = []
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var query = ""
    @Published var category = PetCatalogKind.all
    @Published var downloading: Set<String> = []
    @Published var installed: Set<String> = []
    /// 单次下载失败 banner(不隐藏列表)。
    @Published var downloadError: String?

    private let client: PetCatalogClient
    private let installer: PetPackInstaller
    private let petsDir: URL
    private let onInstalled: @MainActor () -> Void

    /// 默认装到自有库 `~/.petagent/pets/codex/`(被 CodexSpritePackLoader.discover() 发现)。
    nonisolated static var defaultPetsDir: URL { PetLibrary.installDir(for: .codex) }

    init(
        client: PetCatalogClient = PetCatalogClient(),
        installer: PetPackInstaller = PetPackInstaller(),
        petsDir: URL = PetBrowseModel.defaultPetsDir,
        onInstalled: @escaping @MainActor () -> Void = {}
    ) {
        self.client = client
        self.installer = installer
        self.petsDir = petsDir
        self.onInstalled = onInstalled
    }

    /// 按分类 + 搜索词过滤(agentpet 同款:kind 段 + name/slug 子串)。
    var results: [RemotePet] {
        var list = pets
        if category != PetCatalogKind.all { list = list.filter { $0.kind == category } }
        guard !query.isEmpty else { return list }
        let q = query.lowercased()
        return list.filter { $0.name.lowercased().contains(q) || $0.slug.lowercased().contains(q) }
    }

    /// 首次出现时拉 manifest;同时刷新「已装」集合(扫 petsDir 目录名)。petdex 维护/断网 → loadError。
    func loadIfNeeded() {
        installed = Self.installedSlugs(in: petsDir)
        guard pets.isEmpty, !isLoading else { return }
        isLoading = true
        loadError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                self.pets = try await self.client.fetchManifest()
            } catch {
                self.loadError = "拉取桌宠库失败(可能在维护或断网),稍后重试。"
            }
            self.isLoading = false
        }
    }

    /// 最近一次下载 Task —— 测试可 await(免轮询)。
    private(set) var lastDownloadTask: Task<Void, Never>?

    /// 一键下载安装(下载/拷贝在后台,完成回主线程更新 + 触发 picker 热刷新)。
    /// `dualWriteCompatEnabled` 开 → 同时拷一份到 `~/.codex/pets/`(跨 Codex 工具共享)。
    func download(_ pet: RemotePet) {
        guard !downloading.contains(pet.slug) else { return }
        downloadError = nil
        downloading.insert(pet.slug)
        let installer = self.installer
        let dest = self.petsDir
        let dualWrite = PetLibrary.dualWriteCompatEnabled
        let compatRoot = PetLibrary.compatRoot
        lastDownloadTask = Task { [weak self] in
            do {
                let installedDir = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                    let dir = try await installer.install(pet, into: dest)
                    if dualWrite { Self.copyToCompat(dir, compatRoot: compatRoot) }   // 跨工具共享(可选)
                    return dir
                }.value
                _ = installedDir
                // 全程 self?.(self 释放 = 对象已亡,无泄漏;不留 guard-return 跳过复位的陷阱)。
                self?.installed.insert(pet.slug)
                self?.downloading.remove(pet.slug)
                self?.onInstalled()   // → 设置面板 re-discover + 热刷新 picker
            } catch {
                self?.downloading.remove(pet.slug)
                self?.downloadError = Self.errorText(error, pet: pet)
            }
        }
    }

    /// 把装好的包目录拷一份到兼容根(覆盖同名)。失败静默(可选共享,不阻断主安装)。
    nonisolated static func copyToCompat(_ packDir: URL, compatRoot: URL) {
        let fm = FileManager.default
        let dest = compatRoot.appendingPathComponent(packDir.lastPathComponent, isDirectory: true)
        try? fm.createDirectory(at: compatRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: packDir, to: dest)
    }

    // MARK: - helpers

    /// 扫 petsDir 子目录名作已装 slug 集合。
    static func installedSlugs(in dir: URL) -> Set<String> {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return Set(children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.map(\.lastPathComponent))
    }

    /// PetCatalogError → 用户可读中文。
    static func errorText(_ error: Error, pet: RemotePet) -> String {
        guard let e = error as? PetCatalogError else { return "「\(pet.name)」下载失败:\(error.localizedDescription)" }
        switch e {
        case .badStatus(let code) where code == 429: return "下载被限流,稍等片刻再点「获取」。"
        case .badStatus(let code): return "「\(pet.name)」下载失败(HTTP \(code))。"
        case .untrustedHost(let host): return "「\(pet.name)」资产来源不可信(\(host)),已拒绝。"
        case .decodeFailed: return "「\(pet.name)」数据解析失败。"
        case .badURL: return "「\(pet.name)」资产地址非法。"
        }
    }
}
