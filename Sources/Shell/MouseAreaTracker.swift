import AppKit

/// 全局鼠标 X 区域追踪 —— 让桌宠"看着"光标方向(左/中/右)。
///
/// 用 `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` 全屏监听,
/// 不需要任何 entitlement。每次鼠标移动计算 X 在屏幕宽度的比例,分成 3 档:
///   - x < 40% → `.left`
///   - x > 60% → `.right`
///   - 其他    → `.center`
///
/// 仅在 area **变化**时触发 `onAreaChanged` callback,所以接收方不需要节流。
///
/// 与 HermesPet (https://github.com/basionwang-bot/HermesPet) `MouseTrackingController` 的区别:
/// - 走 closure callback 而非 NotificationCenter(OpenPetAgent 全项目 callback 风格,
///   见 `BondedSession.onChoiceSelected` / `PetChatAnimator` 等)
/// - 多屏处理简化:用 `NSScreen.main` 作为参考屏,鼠标在其他屏视为 `.center`
///   (灵动岛刘海屏检测留到 N1 灵动岛 phase 一起做)
@MainActor
public final class MouseAreaTracker {

    public enum MouseArea: String, Equatable, Sendable {
        case left, center, right
    }

    // MARK: - Public

    /// area 变化时调用。同 area 反复触发不调(tracker 内部已去重)。
    public var onAreaChanged: ((MouseArea) -> Void)?

    /// 当前缓存的 area(测试访问器)。
    public private(set) var currentArea: MouseArea = .center

    /// 是否已 `start()`。
    public var isRunning: Bool { monitor != nil }

    // MARK: - Stored

    private var monitor: Any?

    /// 注入的"鼠标位置 + 参考屏" provider,**测试用** —— 默认走 NSEvent.mouseLocation
    /// + NSScreen.main。测试里换成可控的 fixture 验证 area 切换逻辑。
    private let mouseLocationProvider: @MainActor () -> (location: NSPoint, screenFrame: NSRect?)

    // MARK: - Init

    public init(
        mouseLocationProvider: @escaping @MainActor () -> (location: NSPoint, screenFrame: NSRect?) = {
            (NSEvent.mouseLocation, NSScreen.main?.frame)
        }
    ) {
        self.mouseLocationProvider = mouseLocationProvider
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Lifecycle

    /// 启动 global monitor。已 start 时再调是 no-op(幂等)。
    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            // global monitor closure 在主线程触发(macOS 14+),保险起见显式 hop。
            Task { @MainActor in
                self?.evaluateAndNotify()
            }
        }
    }

    /// 停止 global monitor 并清空 cached area。
    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    // MARK: - Internal (test hook)

    /// 测试用:不依赖 NSEvent monitor,直接调一次 area 评估 + callback 触发。
    /// 生产代码由 monitor 闭包间接触发同一路径。
    internal func evaluateAndNotify() {
        let (location, screenFrame) = mouseLocationProvider()
        let area = Self.classify(location: location, screenFrame: screenFrame)
        guard area != currentArea else { return }
        currentArea = area
        onAreaChanged?(area)
    }

    // MARK: - Pure classification (test-friendly)

    /// 把鼠标位置 + 屏幕 frame 分类成 3 档 area。纯函数,无副作用,
    /// 可单测覆盖各种边界 case。`screenFrame == nil` 或鼠标在屏外 → `.center`。
    public static func classify(location: NSPoint, screenFrame: NSRect?) -> MouseArea {
        guard let frame = screenFrame else { return .center }
        if location.x < frame.minX || location.x > frame.maxX {
            return .center
        }
        let relativeX = (location.x - frame.minX) / frame.width
        if relativeX < 0.40 { return .left }
        if relativeX > 0.60 { return .right }
        return .center
    }
}
