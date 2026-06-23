import Testing
import AppKit
import PetCatalog
import Rendering
@testable import Shell

@Suite("RemoteThumbnailLoader —— 远程首帧缩略图(缓存 / allowlist / 失败回退)")
@MainActor
struct RemoteThumbnailLoaderTests {

    final class MockFetcher: AssetFetcher, @unchecked Sendable {
        var responses: [String: (Data, Int)] = [:]
        var fetchCount = 0
        func fetch(_ url: URL, referer: String?) async throws -> (Data, Int) {
            fetchCount += 1
            return responses[url.absoluteString] ?? (Data(), 404)
        }
    }

    /// 造一张 8×9 spritesheet PNG 的字节(供 firstFrameThumbnail(data:) 裁)。
    private func sheetPNG() throws -> Data {
        let w = 8 * 12, h = 9 * 13
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.systemTeal.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let rep = NSBitmapImageRep(cgImage: try #require(ctx.makeImage()))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private let trusted = "https://petdex-assets.raillyhugo.workers.dev/sheet.png"

    @Test("firstFrameThumbnail(data:) 从 8×9 PNG 字节裁首帧")
    func dataThumbnail() throws {
        let img = try #require(CodexSpritePackLoader.firstFrameThumbnail(data: try sheetPNG(), maxDim: 44))
        #expect(img.size.width > 0 && img.size.height > 0)
    }

    @Test("load:可信 host 下载 → 缓存;再 load 命中缓存不重复 fetch")
    func loadCachesAndDedupes() async throws {
        let mock = MockFetcher()
        mock.responses[trusted] = (try sheetPNG(), 200)
        let loader = RemoteThumbnailLoader(fetcher: mock)
        loader.load(trusted)
        for _ in 0..<40 where loader.thumbnail(for: trusted) == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(loader.thumbnail(for: trusted) != nil)
        #expect(mock.fetchCount == 1)
        loader.load(trusted)   // 已缓存 → 不再 fetch
        #expect(mock.fetchCount == 1)
    }

    @Test("load:非可信 host 直接跳过(不 fetch)")
    func loadRejectsUntrusted() {
        let mock = MockFetcher()
        let loader = RemoteThumbnailLoader(fetcher: mock)
        loader.load("https://evil.example.com/sheet.png")
        #expect(mock.fetchCount == 0)
        #expect(loader.thumbnail(for: "https://evil.example.com/sheet.png") == nil)
    }

    @Test("load:非 2xx → 不缓存(回退占位)")
    func loadBadStatusNoCache() async throws {
        let mock = MockFetcher()
        mock.responses[trusted] = (Data(), 503)
        let loader = RemoteThumbnailLoader(fetcher: mock)
        loader.load(trusted)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(loader.thumbnail(for: trusted) == nil)
    }
}
