import Context
import PetBehavior

/// 桌面态(bottom-origin 桌面)→ Shimeji `BehaviorEnvironment`(top-origin)的翻转 provider。
/// 持 cursor 半衰速度状态(Thrown 初速源),故为引用类型;host 每帧调一次。
///
/// 坐标来源差异(摸码确认):`snapshot.cursorPosition` 是 NSEvent **bottom-origin**;
/// `visibleWindows[].bounds` 是 CGWindow **top-origin**(`CollisionRect.collection` 会翻成
/// bottom,这里**不走它**,直接用 top-origin 原值喂 Shimeji)。
@MainActor
public final class DesktopEnvironmentProvider {
    private var lastCursor: BehaviorPoint?
    private var cursorDX: Double = 0
    private var cursorDY: Double = 0

    public init() {}

    /// - snapshot: 桌面快照(cursor bottom-origin / windows top-origin)。
    /// - workAreaBottomOrigin: `NSScreen.visibleFrame`(bottom-origin,排除 Dock/菜单栏)。
    /// - screenWidth/screenHeight: 主屏**全**尺寸(翻转基准 + Shimeji `screen`)。
    public func environment(
        snapshot: DesktopSnapshot,
        workAreaBottomOrigin: Rect,
        screenWidth: Double,
        screenHeight: Double
    ) -> BehaviorEnvironment {
        // cursor:bottom-origin → top-origin + 半衰速度(Shimeji Location:dx=(dx+Δx)/2)。
        let cursorTop = BehaviorPoint(x: snapshot.cursorPosition.x, y: screenHeight - snapshot.cursorPosition.y)
        if let prev = lastCursor {
            cursorDX = (cursorDX + (cursorTop.x - prev.x)) / 2
            cursorDY = (cursorDY + (cursorTop.y - prev.y)) / 2
        }
        lastCursor = cursorTop

        let screen = BehaviorArea(left: 0, top: 0, right: screenWidth, bottom: screenHeight)

        // workArea:visibleFrame bottom-origin → top-origin。
        let waTop = screenHeight - (workAreaBottomOrigin.origin.y + workAreaBottomOrigin.height)
        let waBottom = screenHeight - workAreaBottomOrigin.origin.y
        let workArea = BehaviorArea(
            left: workAreaBottomOrigin.origin.x,
            top: waTop,
            right: workAreaBottomOrigin.origin.x + workAreaBottomOrigin.width,
            bottom: waBottom
        )

        return BehaviorEnvironment(
            workArea: workArea,
            activeWindow: activeWindow(snapshot: snapshot),
            screen: screen,
            cursor: BehaviorCursor(x: cursorTop.x, y: cursorTop.y, dx: cursorDX, dy: cursorDY)
        )
    }

    /// 前台窗口(activeIE):优先匹配 `visibleApplicationName`,否则第一个可见窗;无 → `.invisible`。
    /// bounds 已是 CGWindow top-origin,直接用。
    private func activeWindow(snapshot: DesktopSnapshot) -> BehaviorArea {
        let candidate = snapshot.visibleWindows.first { $0.ownerName == snapshot.visibleApplicationName }
            ?? snapshot.visibleWindows.first
        guard let w = candidate, w.bounds.width > 0, w.bounds.height > 0 else { return .invisible }
        return BehaviorArea(
            left: w.bounds.origin.x,
            top: w.bounds.origin.y,
            right: w.bounds.origin.x + w.bounds.width,
            bottom: w.bounds.origin.y + w.bounds.height
        )
    }
}
