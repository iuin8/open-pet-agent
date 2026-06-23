import AppKit

/// 统一设面板「钉住态」窗口层级 + collectionBehavior（主陪伴卡片 + 列容器共用）。
///
/// 钉住 = `floating+1` + `.stationary`：压过 pet/灵动岛/普通窗、跨 Space/Mission Control 常驻浮顶。
/// 未钉 = `.normal` + `.transient`：可被其他 app 盖住（标准切应用），切 Space 自动消失（临时态降噪）。
/// level 与 collectionBehavior 必须同步切——只翻 level 不翻 behavior 会让钉住卡含 `.transient` 被系统自动隐藏。
public enum WindowPinState {
    public static func apply(_ panel: NSPanel?, pinned: Bool) {
        guard let panel else { return }
        panel.level = pinned ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) : .normal
        panel.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
}
