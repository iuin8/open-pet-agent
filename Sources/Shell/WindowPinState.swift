import AppKit

/// 统一设面板「钉住态」窗口层级 + collectionBehavior（主陪伴卡片 + 列容器共用）。
///
/// 钉住 = `.floating` + `.stationary`：跨 Space/Mission Control 常驻，但不压过菜单栏/status item 自定义弹窗。
/// 未钉 = `.normal` + `.transient`：可被其他 app 盖住（标准切应用），切 Space 自动消失（临时态降噪）。
/// level 与 collectionBehavior 必须同步切——只翻 behavior 不翻 level 会让取消钉住后仍浮在普通 app 上。
public enum WindowPinState {
    public static func apply(_ panel: NSPanel?, pinned: Bool) {
        guard let panel else { return }
        panel.level = pinned ? .floating : .normal
        panel.collectionBehavior = pinned
            ? ShellWindowPolicy.activeCompanionBehavior
            : ShellWindowPolicy.transientCompanionBehavior
    }
}
