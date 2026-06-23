import AppKit

@MainActor
public final class PetWindowDragAdapter: NSObject, NSWindowDelegate {
    private var onWindowDidMove: @MainActor (NSPoint) -> Void
    private var onDragDidEnd: @MainActor (NSPoint) -> Void
    /// 拖拽刚开始(首次移动,false→true 跃迁)时触发一次 —— 给「抓起」惊跳动画(item1)。
    private var onDragDidStart: @MainActor () -> Void = {}
    private var hasPendingDragRelease = false
    private var shouldSuppressNextMouseUp = false
    /// True 仅在用户真按下 pet 拖拽期间(windowMouseDown → mouseUp)。程序化 setFrameOrigin
    /// (漫步/爬墙/跟随)会触发 windowDidMove **通知仍照发**(临时 nil delegate 拦不住异步通知,
    /// 见 MinimalAppDelegate+Launch 注释),若不 gate 会把程序化移动误当用户拖拽 → 回写
    /// currentRenderState + bump interactionVersion → 把漫步算出的位置 snap 回原地(根因#2)。
    /// 仅用户交互中才处理 windowDidMove。
    private var isUserInteracting = false

    /// True while the user is in the middle of a window drag (between
    /// `windowDragDidMove` and `windowMouseUp` / `windowDragDidEnd`). Used by
    /// `DesktopShellController.applyRuntimePetVelocity` to gate physics-driven
    /// squash so it doesn't fight the drag-velocity feed coming from
    /// `handlePetDragDidMove`. Drag-end (or suppressed mouse-up) clears this
    /// back to `false` along with `hasPendingDragRelease`.
    public var isCurrentlyDragging: Bool { hasPendingDragRelease }

    public init(
        onWindowDidMove: @escaping @MainActor (NSPoint) -> Void = { _ in },
        onDragDidEnd: @escaping @MainActor (NSPoint) -> Void = { _ in }
    ) {
        self.onWindowDidMove = onWindowDidMove
        self.onDragDidEnd = onDragDidEnd
    }

    public func install(
        onWindowDidMove: @escaping @MainActor (NSPoint) -> Void,
        onDragDidEnd: @escaping @MainActor (NSPoint) -> Void,
        onDragDidStart: @escaping @MainActor () -> Void = {}
    ) {
        self.onWindowDidMove = onWindowDidMove
        self.onDragDidEnd = onDragDidEnd
        self.onDragDidStart = onDragDidStart
    }

    public func windowDidMove(_ notification: Notification) {
        guard isUserInteracting else { return }   // 忽略程序化移动(漫步/跟随),只认用户拖拽
        let position = (notification.object as? NSWindow)?.frame.origin ?? .zero
        windowDragDidMove(to: position)
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        let position = (notification.object as? NSWindow)?.frame.origin ?? .zero
        windowDragDidEnd(at: position)
    }

    public func windowMouseDown() {
        shouldSuppressNextMouseUp = false
        isUserInteracting = true   // 用户按下 → 之后的 windowDidMove 才算真拖拽
    }

    public func windowDragDidMove(to position: NSPoint) {
        if hasPendingDragRelease == false { onDragDidStart() }   // 首次移动 = 抓起,触发惊跳一次
        hasPendingDragRelease = true
        shouldSuppressNextMouseUp = false
        onWindowDidMove(position)
    }

    public func windowMouseUp(afterDraggingAt position: NSPoint) -> Bool {
        isUserInteracting = false
        guard shouldSuppressNextMouseUp == false else {
            shouldSuppressNextMouseUp = false
            return true
        }

        guard hasPendingDragRelease else {
            return false
        }

        hasPendingDragRelease = false
        onDragDidEnd(position)
        return true
    }

    public func windowDragDidEnd(at position: NSPoint) {
        hasPendingDragRelease = false
        shouldSuppressNextMouseUp = true
        isUserInteracting = false
        onDragDidEnd(position)
    }
}
