import Foundation

/// 一张随消息内联的图片(用户粘贴的截图 / assistant 返回的图)。从 transcript 的 image 内容块抽出。
///
/// **分层**:本类型在 AgentSensing(Foundation only)→ 只携**解码后的字节** `data`(不绑 AppKit `NSImage`);
/// 渲染层(Shell)再 `NSImage(data:)` 解码成图。base64 在 parser 阶段就解成 `Data`(省得到处带超长 base64 串)。
///
/// **来源格式两种**(实测真实 transcript):
/// - `{"type":"image","source":{"type":"base64","data":"…","media_type":"image/jpeg"}}`(标准 Anthropic API)
/// - `{"type":"image","file":{"base64":"…"}}`(Claude Code 变体)
public struct ImageAttachment: Sendable, Equatable, Identifiable {
    /// 消息内稳定下标(同条消息多图时给 ForEach / 点击定位)。
    public let id: Int
    /// 解码后的图片字节(JPEG/PNG…);渲染层 `NSImage(data:)`。
    public let data: Data
    /// MIME 类型(如 `image/jpeg`);缺失时默认空串。
    public let mediaType: String

    public init(id: Int, data: Data, mediaType: String) {
        self.id = id
        self.data = data
        self.mediaType = mediaType
    }

    /// **廉价 Equatable**:图片来自 transcript 不可变(同字节偏移=同图)→ 按 `id + 字节数 + 类型` 判等,
    /// **不逐字节比** `data`(80KB×N 全比会拖垮 `ConversationItem` 的 `==` / diff)。
    public static func == (l: ImageAttachment, r: ImageAttachment) -> Bool {
        l.id == r.id && l.mediaType == r.mediaType && l.data.count == r.data.count
    }
}
