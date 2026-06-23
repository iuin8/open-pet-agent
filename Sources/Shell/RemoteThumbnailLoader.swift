import AppKit
import Combine
import PetCatalog
import Rendering

/// PF3 Codex 在线画廊的 per-row 缩略图加载器(蓝本 agentpet FirstFrameThumb)。按 spritesheet
/// URL 下载首帧裁出小图、缓存,并发限流(≤3)避免 CDN 429 + 带宽爆。仅可信 host(allowlist)。
/// 失败静默(行回退 kind 占位图标)。`@Published cache` → 加载完成 View 自动重渲染对应行。
@MainActor
final class RemoteThumbnailLoader: ObservableObject {
    @Published private(set) var cache: [String: NSImage] = [:]

    private var inFlight: Set<String> = []
    private var activeCount = 0
    private let maxConcurrent = 3
    private let fetcher: AssetFetcher

    init(fetcher: AssetFetcher = URLSessionAssetFetcher()) { self.fetcher = fetcher }

    /// 已缓存的缩略图(没有则 nil → View 显占位)。
    func thumbnail(for urlString: String) -> NSImage? { cache[urlString] }

    /// 触发加载(已缓存 / 在途 / 非可信 host / URL 非法 → 跳过)。并发满则排队等空位。
    func load(_ urlString: String) {
        guard cache[urlString] == nil, !inFlight.contains(urlString),
              let url = URL(string: urlString), TrustedAssetHosts.isTrusted(url) else { return }
        inFlight.insert(urlString)
        Task { [weak self] in
            guard let self else { return }
            // 等并发空位(限 maxConcurrent,防 CDN 429 / 带宽爆)。
            while self.activeCount >= self.maxConcurrent { try? await Task.sleep(nanoseconds: 80_000_000) }
            self.activeCount += 1
            defer { self.activeCount -= 1; self.inFlight.remove(urlString) }
            guard let (data, code) = try? await self.fetcher.fetch(url, referer: PetCatalogClient.assetReferer),
                  (200..<300).contains(code),
                  let img = CodexSpritePackLoader.firstFrameThumbnail(data: data) else { return }
            self.cache[urlString] = img
        }
    }
}
