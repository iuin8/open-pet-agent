import Testing
import Foundation
import PetCatalog
@testable import Shell

@Suite("PetBrowseModel —— 过滤 / 已装集 / 下载 / 错误映射")
@MainActor
struct PetBrowseModelTests {

    final class MockFetcher: AssetFetcher, @unchecked Sendable {
        var responses: [String: (Data, Int)] = [:]
        func fetch(_ url: URL, referer: String?) async throws -> (Data, Int) {
            responses[url.absoluteString] ?? (Data(), 404)
        }
    }

    private func pet(_ slug: String, kind: String, name: String? = nil) -> RemotePet {
        RemotePet(slug: slug, displayName: name ?? slug, kind: kind, submittedBy: "a",
                  spritesheetUrl: "https://petdex-assets.raillyhugo.workers.dev/\(slug).webp",
                  petJsonUrl: "https://petdex-assets.raillyhugo.workers.dev/\(slug).json")
    }

    @Test("results:按 kind 段 + name/slug 子串过滤")
    func resultsFilter() {
        let m = PetBrowseModel()
        m.pets = [pet("ferris", kind: "creature", name: "Ferris"),
                  pet("boba", kind: "character", name: "Boba"),
                  pet("crab", kind: "creature", name: "Crab")]
        m.category = "all"; m.query = ""
        #expect(m.results.count == 3)
        m.category = "creature"
        #expect(Set(m.results.map(\.slug)) == ["ferris", "crab"])
        m.category = "all"; m.query = "bob"
        #expect(m.results.map(\.slug) == ["boba"])
        m.query = "CRAB"   // 大小写不敏感
        #expect(m.results.map(\.slug) == ["crab"])
    }

    @Test("installedSlugs:扫目录子目录名")
    func installedSlugs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inst-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("ferris"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("boba"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PetBrowseModel.installedSlugs(in: dir) == ["ferris", "boba"])
        // 不存在的目录 → 空集。
        #expect(PetBrowseModel.installedSlugs(in: dir.appendingPathComponent("nope")) == [])
    }

    @Test("download:成功 → 写盘 + installed 更新 + onInstalled 回调")
    func downloadSuccess() async throws {
        let fetcher = MockFetcher()
        let p = pet("ferris", kind: "creature")
        fetcher.responses[p.petJsonUrl] = (Data(#"{"spritesheetPath":"spritesheet.webp"}"#.utf8), 200)
        fetcher.responses[p.spritesheetUrl] = (Data("SHEET".utf8), 200)
        let petsDir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: petsDir) }

        var installedCalled = false
        let m = PetBrowseModel(
            client: PetCatalogClient(fetcher: fetcher),
            installer: PetPackInstaller(fetcher: fetcher),
            petsDir: petsDir,
            onInstalled: { installedCalled = true })
        m.download(p)
        await m.lastDownloadTask?.value   // 结构化等待(免轮询,review MEDIUM-3)
        #expect(m.installed.contains("ferris"))
        #expect(installedCalled)
        #expect(FileManager.default.fileExists(atPath: petsDir.appendingPathComponent("ferris/spritesheet.webp").path))
        #expect(m.downloadError == nil)
    }

    @Test("copyToCompat:把包目录拷到兼容根(覆盖同名)")
    func copyToCompat() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cw-\(UUID())", isDirectory: true)
        let pack = work.appendingPathComponent("ferris", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data("SHEET".utf8).write(to: pack.appendingPathComponent("spritesheet.webp"))
        let compat = work.appendingPathComponent("compat", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }

        PetBrowseModel.copyToCompat(pack, compatRoot: compat)
        #expect(FileManager.default.fileExists(atPath: compat.appendingPathComponent("ferris/spritesheet.webp").path))
        // 再拷一次(覆盖)不崩。
        PetBrowseModel.copyToCompat(pack, compatRoot: compat)
        #expect(FileManager.default.fileExists(atPath: compat.appendingPathComponent("ferris/spritesheet.webp").path))
    }

    @Test("errorText:PetCatalogError → 中文")
    func errorTextMapping() {
        let p = pet("x", kind: "object", name: "猫")
        #expect(PetBrowseModel.errorText(PetCatalogError.badStatus(429), pet: p).contains("限流"))
        #expect(PetBrowseModel.errorText(PetCatalogError.untrustedHost("evil.com"), pet: p).contains("不可信"))
        #expect(PetBrowseModel.errorText(PetCatalogError.badStatus(500), pet: p).contains("500"))
    }
}
