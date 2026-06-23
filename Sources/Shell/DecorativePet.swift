import AppKit
import Rendering

/// Phase 2 多宠同屏 —— 一只**装饰物理伙伴**的轻量窗口单元(主宠之外的额外桌宠)。
///
/// 只持:borderless 浮窗(`PetShellWindow`)+ renderer 的 `contentLayer`(经 `PetLayerHostView`)+
/// 精简拖拽(Shimeji 自管位置形象:按下/释放转 renderer 的 `handlePointerDown/Up` → 引擎 Dragged/
/// Thrown;位置每帧由引擎产帧驱动)。**不含** chat / emotion 气泡 / 雪 occluder / 右键菜单动作 ——
/// 那些是主宠(`DesktopShellController`)的职责。
///
/// 位置驱动:host(App 帧循环)每帧用配对的 renderer 算出 NSWindow frame → `setFrame`。本类不持
/// `BehaviorEnvironment`(那是 PetBehavior 类型),保持 Shell 不反依赖 PetBehavior —— 驱动逻辑留在
/// App 层(与 `ShimejiPetRenderer` 同侧)。设计见 docs/pet-library-and-multipet-design.md §5。
@MainActor
public final class DecorativePet {
    /// 形象 id(= picker 的 plugin id;spawn/despawn 按它匹配选中集)。
    public let id: String
    private let window: PetShellWindow
    private let renderer: PetRenderer

    /// 创建并上屏。`renderer` 须自管位置(`drivesOwnWindowPosition == true`,如 Shimeji 引擎形象);
    /// `spawnX` 出生屏内 x(各宠错开);窗口首帧前的占位位置,首次 `setFrame` 即被引擎产帧覆盖。
    /// - Parameters:
    ///   - onSetAsPrimary: 右键「设为主宠」→ host 把本宠升为主宠(交换:旧主宠若可同屏则降为装饰)。
    ///   - onOpenSettings / onQuit: 装饰宠精简右键菜单的「设置…」「退出」(主宠专属动作不放进装饰菜单)。
    public init(
        id: String, renderer: PetRenderer, screenFrame: NSRect, spawnX: Double,
        onSetAsPrimary: @escaping @MainActor () -> Void = {},
        onOpenSettings: @escaping @MainActor () -> Void = {},
        onQuit: @escaping @MainActor () -> Void = {}
    ) {
        self.id = id
        self.renderer = renderer
        let win = ShellWindowFactory.makePetWindow(
            descriptor: ShellWindowFactory.fallbackDescriptor(for: .pet),
            screenFrame: screenFrame,
            initialState: ShellInitialState(petPositionX: spawnX, petPositionY: 0))
        // makePetWindow 内部建的就是 PetShellWindow;转型拿 sendEvent 路由的 install。
        self.window = (win as? PetShellWindow) ?? PetShellWindow(
            contentRect: win.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = PetLayerHostView(content: renderer.contentLayer)
        // 拖拽:Shimeji 自管位置 → 按下转引擎(Dragged 跟手)、释放转引擎(Thrown 甩出);
        // 位置由引擎每帧产帧(host 调 setFrame),不走 setFrameOrigin。
        // 右键菜单:装饰宠精简菜单(设为主宠 / 设置 / 退出)。
        window.install(
            onMouseDown: { [weak renderer] in renderer?.handlePointerDown() },
            onMouseUp: { [weak renderer] _, _ in renderer?.handlePointerUp() },
            onSettings: onOpenSettings,
            onQuit: onQuit,
            onSetAsPrimary: onSetAsPrimary,
            decorativeMenu: true
        )
        renderer.resumeDisplayLink()
        window.orderFront(nil)
    }

    /// host 每帧:把引擎算出的 NSWindow frame 摆上窗口(bottom-origin 世界系)。
    public func setFrame(_ frame: NSRect) {
        window.setFrame(frame, display: false)
    }

    /// 当前窗口 frame(host 算世界位置 / 诊断用)。
    public var windowFrame: NSRect { window.frame }

    /// 窗口当前是否可见(未被完全遮挡)—— host 据此判「有没有 pet 用户看得到」来决定帧率。
    public var isWindowVisible: Bool { window.occlusionState.contains(.visible) }

    /// 下屏 + 释放(despawn / 退出)。
    public func close() {
        renderer.pauseDisplayLink()
        window.orderOut(nil)
    }
}
