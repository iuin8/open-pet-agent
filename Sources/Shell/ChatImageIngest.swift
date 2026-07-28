import AppKit
import Orchestrator

/// P7.2:粘贴/拖拽图片 → `ChatImage`(统一重编码 PNG,>5MB 拒绝)。
///
/// 两个入口共用:
/// - **粘贴**(`ChatComposerTextView.paste:`):pasteboard 有图 → 本类;无图 → 纯文本粘贴。
/// - **拖拽**(performDragOperation):Finder 图片文件 URL / 内联图像数据。
///
/// 超限/解码失败:静默跳过 + 打日志(不带 transient 提示,简单可靠;crush 输入侧同思路)。
enum ChatImageIngest {
    /// 单图字节上限(ACP base64 后 ~1.33×,5MB 原图 ≈ 6.7MB wire;防巨型截图卡死 agent)。
    static let maxBytes = 5_000_000

    /// 支持的图片文件扩展名(拖拽/粘贴文件 URL 过滤;heic 也重编码 PNG)。
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff"]

    /// pasteboard 是否有可读图片(文件 URL 扩展名 / 内联图像数据)—— drag 悬停高亮判定用。
    static func canReadImages(from pasteboard: NSPasteboard) -> Bool {
        !imageFileURLs(in: pasteboard).isEmpty || !inlineImages(in: pasteboard).isEmpty
    }

    /// 读 pasteboard 全部图片 → ChatImage(PNG 重编码;超限/解码失败跳过)。
    /// 无图片 → 空数组(调用方走纯文本粘贴路径)。
    static func images(from pasteboard: NSPasteboard) -> [ChatImage] {
        var sources: [NSImage] = []
        // 1. 图片文件 URL(Finder 拖入 / 复制的图片文件)
        for url in imageFileURLs(in: pasteboard) {
            if let image = NSImage(contentsOf: url) { sources.append(image) }
        }
        // 2. 内联图像数据(截图 / 浏览器复制图片;无文件 URL 时)
        if sources.isEmpty {
            sources.append(contentsOf: inlineImages(in: pasteboard))
        }
        return sources.compactMap { chatImage(from: $0) }
    }

    /// pasteboard 里的图片文件 URL(扩展名过滤)。
    private static func imageFileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// pasteboard 里的内联图像(截图 / 浏览器复制图片的 TIFF/PNG 数据)。
    private static func inlineImages(in pasteboard: NSPasteboard) -> [NSImage] {
        (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) ?? []) as? [NSImage] ?? []
    }

    /// NSImage → PNG `ChatImage`(>5MB 拒绝)。
    private static func chatImage(from image: NSImage) -> ChatImage? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("[ChatImageIngest] 图片 PNG 重编码失败,已跳过")
            return nil
        }
        guard png.count <= maxBytes else {
            print("[ChatImageIngest] 图片超过 5MB(\(png.count / 1_000_000)MB),已跳过")
            return nil
        }
        return ChatImage(data: png, mediaType: "image/png")
    }
}
