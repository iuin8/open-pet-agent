import Foundation

/// P7.2:跨模块图片类型的**唯一事实源**(ACP image content block 管线 + composer 附件 + 落盘)。
/// 只携解码后的字节 + MIME 类型(Foundation-only,不绑 AppKit `NSImage`;渲染层 `NSImage(data:)`)。
///
/// - ACP wire:`{"type":"image","mimeType":"…","data":"<base64>"}`(`ACPClient.prompt` 编码)。
/// - Codable:Data 自动 base64 → `ConversationMessage` 落盘零样板(可选键,旧 JSON 解为 nil)。
/// - Orchestrator 经 `public typealias ChatImage` 再导出,Shell 只 `import Orchestrator` 即可用,
///   全链路同一名词类型,零映射样板。
public struct ChatImage: Codable, Sendable, Equatable {
    /// 解码后的图片字节(入口统一重编码 PNG;`ChatImageIngest`)。
    public let data: Data
    /// MIME 类型(统一 `image/png`;入口已重编码)。
    public let mediaType: String

    public init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }

    /// **廉价 Equatable**(照 `ImageAttachment` 模式):图片不可变 → 按 `mediaType + 字节数` 判等,
    /// **不逐字节比** `data`(几十 KB×N 全比会拖垮列表 diff / `@Published` 比对)。
    public static func == (l: ChatImage, r: ChatImage) -> Bool {
        l.mediaType == r.mediaType && l.data.count == r.data.count
    }
}
