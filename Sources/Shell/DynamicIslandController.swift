import AppKit
import SwiftUI
import Weather

/// N1 灵动岛骨架——与刘海融合的桌宠胶囊控制器。
///
/// 设计目标:在带刘海的 macOS 机型(MacBook Pro 14"/16"、iMac 24" notch)上,
/// 让一颗紧贴物理屏顶、横向与**真实刘海中心**对齐的纯黑胶囊和系统刘海融为
/// 一体;用户点击胶囊即可召唤 Bonded 输入气泡跟 pet 对话(由 `onTapped`
/// 回调驱动)。
///
/// 本文件**只实现 N1 骨架**——固定形态、点击触发回调。形态变化(伸长、
/// 长缩、状态切换)、permission card、pet 状态展示都属于后续 phase,
/// 故意不放进来,以严格遵守下方两条决策。
///
/// **关键决策 #1: NSWindow 永远不能 setFrame()**
///
/// 任何让灵动岛 NSWindow `setFrame(_:display:)` 改 width/height 的方案在
/// macOS 26 上 100% 必崩——`NSHostingView.updateAnimatedWindowSize` 会反推
/// setFrame,触发嵌套 layout → SIGABRT。因此本控制器的 panel frame 在
/// **init 时一次性算出并冻结**,后续永不修改。形态变化必须在 panel 内部
/// 用 sublayer 实现,不能动 panel frame 本身。
///
/// **真刘海几何反推**(替换原 hard-code 280×40):
/// macOS 12+ 在带刘海机型上把刘海几何暴露在 `NSScreen` 上——
/// `safeAreaInsets.top` 是刘海高度,`auxiliaryTopLeftArea` /
/// `auxiliaryTopRightArea` 分别是刘海左右两侧的菜单栏可用区域。用这两块
/// 「耳朵」的 `maxX` / `minX` 就能反推出物理刘海的左右边界与中心 X。
/// 不同 MBP(14"/16")、不同外接屏几何不同, hard-code 一个 280×40 会让胶囊
/// 在 16" 上比刘海窄、在外接屏上根本不在刘海下面。无刘海或字段缺失时
/// fallback 到 180×32 + 屏幕中线。
///
/// 另外:macOS 26 默认会把 panel 约束到 `screen.visibleFrame`(避开 menu
/// bar),即使 `level = .statusBar` 也被约束。我们用一个自定义子类
/// `EmbeddableIslandPanel` override `constrainFrameRect(_:to:)` 直接返回原
/// `frameRect`,让 panel 顶贴**物理屏顶**(盖住刘海两侧)。
///
/// **关键决策 #2: Hit-test 走 NSEvent monitor,不走 panel 自己的事件**
///
/// SwiftUI / AppKit 在 macOS 26 上 `.onHover` / window hit-test 都不读
/// `contentShape`——鼠标在 NSWindow 整个区域任意位置都会触发 hover,
/// 包括视觉透明区。如果想要"只在胶囊本体上响应"的精确点击,必须自己做
/// hit-test。
///
/// → `panel.ignoresMouseEvents = true` + `acceptsMouseMovedEvents = false`,
///   整个 panel **不收任何事件**(透明给底下的桌面)。
/// → 用 `NSEvent.addLocalMonitorForEvents` + `addGlobalMonitorForEvents`
///   监听 `.leftMouseDown`,在屏幕坐标系内自检 `NSEvent.mouseLocation` 是否
///   落在 `hitRect` 内,命中则触发 `onTapped`。
///
/// MVP 阶段没有形态变化、没有 hover 状态,所以 `hitRect` 始终等于
/// `pillWindow.frame`。后续 phase 引入 hover/active 状态时,可以让
/// `hitRect` 跟随当前形态动态切换。
@MainActor
public final class DynamicIslandController {

    // MARK: - 形态参数(替换原 hard-code 280×40)

    /// idle 态露在刘海下方的高度(borrowed from HermesPet `idleDrop=4`)。
    /// 整体 panel 高 = notchHeight + idleDrop, 这样两侧"耳朵"跟刘海在 Y 轴
    /// 上几乎平齐, 视觉上像从刘海延伸出来, 而不是"挂在刘海下方的胶囊"。
    public static let idleDrop: CGFloat = 4

    /// idle 态两侧"耳朵"总宽度(每侧各占 idleExtraWidth/2)。
    /// 整体 panel 宽 = notchWidth + idleExtraWidth, 贴合真实刘海宽 +
    /// 两侧探出形成"耳朵"形态。
    public static let idleExtraWidth: CGFloat = 80

    /// 无刘海(safeAreaInsets.top == 0 / 缺 auxiliary 字段 / macOS < 12)
    /// 时的 fallback 几何。180×32 是 MBP 14" 物理刘海的近似值, 在无 notch
    /// 屏上至少给出一个"看起来像灵动岛"的胶囊形态。
    public static let fallbackNotchWidth: CGFloat = 180
    public static let fallbackNotchHeight: CGFloat = 32

    // MARK: - 公开属性

    /// 灵动岛 NSPanel 实例。外部一般不直接操作 frame——任何对 frame 的
    /// 改动都违反决策 #1。只允许读取、order in/out。
    public private(set) var pillWindow: NSWindow

    /// 实际刘海宽度(从 `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`
    /// 反推); 无刘海或 macOS < 12 时 fallback 到 `fallbackNotchWidth`。
    public private(set) var notchWidth: CGFloat

    /// 实际刘海高度(= `safeAreaInsets.top`); 无刘海时 fallback 到
    /// `fallbackNotchHeight`。
    public private(set) var notchHeight: CGFloat

    /// 点击灵动岛胶囊命中区时触发的回调。由 `AppDelegate` 在装配阶段
    /// 注册(指向 `toggleChatCard` — 召唤锚定 pet 旁的对话卡片)。
    public var onTapped: (() -> Void)?

    /// 是否启用。`false` 时 panel `orderOut`,事件 monitor 仍在但 hit-test
    /// 会被 `isEnabled` 提前 short-circuit。常用于无刘海机型 / 用户在设置里
    /// 关掉灵动岛的场景。
    public var isEnabled: Bool {
        didSet {
            if isEnabled {
                pillWindow.orderFrontRegardless()
            } else {
                pillWindow.orderOut(nil)
            }
        }
    }

    // MARK: - 私有状态

    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    /// SwiftUI 内容视图的 view model。weather refresh / 状态切换都通过这里
    /// 推动 SwiftUI re-render(不直接持有 hostingController, 避免 deinit 时
    /// 的 @MainActor 隔离麻烦)。
    private let pillViewModel: DynamicIslandPillViewModel

    /// NSHostingController(参考 HermesPet v1.2.4 决策):跟 NSHostingView 不
    /// 同, sizingOptions=[] 能真正禁掉 macOS 26 上 updateAnimatedWindowSize
    /// 反推 NSWindow.setFrame —— 跟灵动岛 EmbeddableIslandPanel.constrainFrameRect
    /// override 不冲突。保留 strong 引用,避免 ARC 提前释放。
    private let pillHostingController: NSHostingController<DynamicIslandPillView>

    // MARK: - 方案 E 决策:删切桌面 transition 整套(2026-05-26)
    //
    // 之前 Task A 加 hideForSpaceTransition + activeSpaceObserver +
    // swipeEventMonitor 三层 fade out/in 逻辑,实测发现:
    //
    // 1. **macOS 26 系统手势期间 NSEvent.swipe 不发** — 3 指/4 指水平 swipe
    //    切桌面被系统级截取做手势,不向 app 派发 NSEvent.swipe → swipeEventMonitor
    //    实际从未触发。
    // 2. **activeSpaceDidChangeNotification 是事后通知** — 切完之后才发,期间
    //    panel 已经跟物理刘海错位重影,这套逻辑反而制造"切完闪一下"的视觉 bug。
    // 3. **macOS 公开 API 没有 "Space transition begin" 通知** — 无法实现"切
    //    桌面过程中消失"。
    //
    // HermesPet 同款决策:**完全不处理 Space 切换**,接受 panel 一直可见,
    // 依赖 collectionBehavior `.canJoinAllSpaces + .stationary` 让 macOS 渲染
    // 层把 panel 视觉锚定在物理屏顶位置(跟物理刘海一起常驻)。这是 macOS
    // API 硬限制下的最佳方案。

    // MARK: - 几何反推(纯函数)

    /// 反推 `screen` 的真实刘海几何。
    ///
    /// 优先用 `auxiliaryTopLeftArea` + `auxiliaryTopRightArea` 两块「耳朵」
    /// 反推刘海左右边界与中心 X(MBP 14"/16"、Mac Studio 外接 XDR 等不同
    /// 机型几何差异很大, 真刘海中心 ≠ 屏幕 midX, 尤其外接屏场景)。
    ///
    /// 无刘海(safeAreaInsets.top == 0)或 auxiliary 字段缺失(macOS < 12 /
    /// 模拟器)时 fallback 到 `fallbackNotchWidth × fallbackNotchHeight`,
    /// 横向用屏幕中线。
    ///
    /// - Returns: `(width, height, centerX)` 三元组, 屏幕坐标系。
    public static func reverseNotchGeometry(
        from screen: NSScreen
    ) -> (width: CGFloat, height: CGFloat, centerX: CGFloat) {
        let screenFrame = screen.frame
        let safeTop: CGFloat
        if #available(macOS 12.0, *) {
            safeTop = screen.safeAreaInsets.top
        } else {
            safeTop = 0
        }
        let height = (safeTop > 0) ? safeTop : fallbackNotchHeight

        // 优先用 auxiliary 两块耳朵反推真刘海几何。需要满足:
        //   1) safeAreaInsets.top > 0(真刘海机型)
        //   2) auxiliaryTopLeftArea / auxiliaryTopRightArea 都非 nil
        //   3) 反推出的宽度为正(防御异常机型 right.minX <= left.maxX)
        if #available(macOS 12.0, *),
           safeTop > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            if width > 0 {
                let centerX = (left.maxX + right.minX) / 2
                return (width, height, centerX)
            }
        }
        return (fallbackNotchWidth, height, screenFrame.midX)
    }

    // MARK: - 初始化

    /// 创建灵动岛控制器并按 `screen` 的真实刘海几何把 panel 安置到物理屏顶。
    ///
    /// - Parameters:
    ///   - screen: 目标屏幕。通常先用 `NSScreen.screens.first(刘海)` 找带刘海
    ///     的屏(外接屏场景 `NSScreen.main` 可能不是 MBP 自带屏), fallback
    ///     到 `NSScreen.main`。
    ///   - isEnabled: 初始启用状态;`true` 时 panel 立刻 `orderFrontRegardless`。
    public init(screen: NSScreen, isEnabled: Bool = true) {
        let geometry = Self.reverseNotchGeometry(from: screen)
        self.notchWidth = geometry.width
        self.notchHeight = geometry.height

        // panel 尺寸 = 真刘海几何 + 两侧"耳朵"延伸(高度跟物理刘海完全一致)。
        // **方案 E 修正**(2026-05-26): 之前 pillHeight = notchHeight + 4pt
        // (idleDrop) 在全屏 app 时多出小黑边。改为 = notchHeight 让 panel 高
        // 度跟物理刘海一致,全屏时跟 menu bar 一起被 macOS 隐藏,无小黑边。
        // SwiftUI UnevenRoundedRectangle 底圆角 = pillHeight/2 = notchHeight/2
        // ≈ 14pt,跟物理刘海底圆角完全一致。
        let pillWidth = geometry.width + Self.idleExtraWidth
        let pillHeight = geometry.height
        let pillSize = NSSize(width: pillWidth, height: pillHeight)
        let screenFrame = screen.frame

        // 横向以**真刘海中心**对齐(不是 screen.midX), 外接屏场景刘海可能
        // 偏左/右, 用 screen.midX 会让胶囊与刘海错位。
        let originX = geometry.centerX - pillWidth / 2
        // 纵向顶贴物理屏顶(EmbeddableIslandPanel.constrainFrameRect 已
        // override 绕过 visibleFrame 约束)。
        // 注意:用 screen.frame(物理屏幕),不是 visibleFrame(避开 menu bar
        // 后的可见区域)——visibleFrame.maxY 会比 frame.maxY 低约 24pt,
        // 放进去就贴不到刘海上了。
        let originY = screenFrame.maxY - pillHeight

        let panel = EmbeddableIslandPanel(
            contentRect: NSRect(x: originX, y: originY, width: pillWidth, height: pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar  // 高于普通 floating,接近 menu bar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isExcludedFromWindowsMenu = true
        // 决策 #2:整个 panel 不收任何事件,hit-test 完全走 NSEvent monitor。
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.animationBehavior = .none

        // 内容视图:SwiftUI Capsule + 天气 icon (借鉴 HermesPet)。
        // dark mode 下天然跟刘海融合;light mode 下也是黑色一体,符合
        // "刘海延伸"的视觉锚定(不要跟随系统主题翻白,会跟刘海颜色割裂)。
        //
        // 关键:用 NSHostingController 而非 NSHostingView。后者在 macOS 26
        // 即便 sizingOptions=[] 仍会通过 updateAnimatedWindowSize 在 CA
        // transaction commit 期间反推 NSWindow.setFrame, 跟
        // EmbeddableIslandPanel.constrainFrameRect override 强冲突 → 必崩。
        // NSHostingController 能真正禁掉那条路径。
        // bottomCornerRadius = panel.height/2 — 顶部直角贴物理屏顶,底部弧
        // 形成"耳朵包裹"感。比物理刘海底圆角 (~14pt) 略大让胶囊"包住"刘海。
        let viewModel = DynamicIslandPillViewModel(bottomCornerRadius: pillHeight / 2)
        let hosting = NSHostingController(rootView: DynamicIslandPillView(viewModel: viewModel))
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        hosting.view.frame = NSRect(origin: .zero, size: pillSize)
        hosting.view.autoresizingMask = [.width, .height]
        // 设 contentView 后 panel 自己 size 内嵌 view, autoresizingMask 让
        // SwiftUI 始终撑满 panel.contentView 的 frame, intrinsic content size
        // 不影响 panel 几何。
        panel.contentView = hosting.view
        self.pillViewModel = viewModel
        self.pillHostingController = hosting

        self.pillWindow = panel
        self.isEnabled = isEnabled

        if isEnabled {
            panel.orderFrontRegardless()
        }
        installEventMonitors()
    }

    /// 由 WeatherStateManager onUpdate 调:把当前 condition 推到 SwiftUI
    /// pill view 显示对应 SF Symbol (snowy → snowflake / rainy → cloud.rain
    /// / sunny → sun.max / cloudy → cloud / windy → wind / nil → 纯黑胶囊)。
    public func updateWeather(_ condition: WeatherConditionKind?) {
        pillViewModel.applyCondition(condition)
    }

    deinit {
        // deinit 在 @MainActor 隔离外执行,只能调用 nonisolated 的 NSEvent
        // 静态方法。removeMonitor 本身是线程安全的。
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Hit-test(决策 #2)

    /// 当前命中矩形(屏幕坐标系)。MVP 固定 = `pillWindow.frame`。
    /// 后续 phase 加 hover/active 形态切换时,改为根据当前状态返回不同矩形。
    private var hitRect: NSRect {
        pillWindow.frame
    }

    private func installEventMonitors() {
        // Local monitor:OpenPetAgent 自身 foreground 时触发。OpenPetAgent 是
        // accessory app,通常不进入 foreground,但用户在 Settings 窗口或
        // Bonded 气泡输入时仍可能 active,加上保险。
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            self?.handleMouseDown(at: NSEvent.mouseLocation)
            return event
        }
        // Global monitor:用户在其他 app foreground 时触发(主要路径)。
        // Global monitor 的 closure 在任意线程执行,必须显式跳回 main actor。
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseDown(at: NSEvent.mouseLocation)
            }
        }
    }

    /// 处理一次屏幕坐标系下的鼠标按下事件。
    /// internal 暴露,方便单测在不真正发 NSEvent 的情况下校验 hit-test 逻辑。
    internal func handleMouseDown(at location: NSPoint) {
        guard isEnabled else { return }
        guard hitRect.contains(location) else { return }
        onTapped?()
    }

    // 方案 E (2026-05-26): 删除 hideForSpaceTransition / scheduleFadeIn 整套。
    // 详见本文件头部"方案 E 决策"段。HermesPet 同款选择 — macOS API 不给
    // Space transition begin 事件, 这套逻辑实际无作用反而制造闪烁 bug。

    // MARK: - Notch 探测

    /// 判定给定 `screen` 是否带刘海。
    /// 实现:macOS 12+ 暴露 `NSScreen.safeAreaInsets`,带刘海机型 top 会
    /// > 0(通常 38pt 左右),无刘海机型 top == 0。
    public static func hasNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }

    /// 任意已连接屏幕是否带刘海(外接屏场景 `NSScreen.main` 不一定是 MBP
    /// 自带屏, 故遍历所有 `NSScreen.screens` 查一遍)。
    public static func mainScreenHasNotch() -> Bool {
        return NSScreen.screens.contains { hasNotch($0) }
    }
}

/// 灵动岛专用 NSPanel——override `constrainFrameRect(_:to:)` 直接返回原
/// `frameRect`,让 panel 顶贴**物理屏顶**(盖住刘海两侧)。
///
/// macOS 26 默认会把 borderless panel 约束到 `screen.visibleFrame`
/// (避开 menu bar)。即便 `level = .statusBar` 也被这个约束作用,导致
/// panel 的 y 被压低到 menu bar 之下,贴不上刘海。原样返回 frameRect
/// 跳过约束。
///
/// **注意**:这意味着开发者必须自己保证传入的 frame 合理(例如不要把
/// 胶囊放到屏幕外),AppKit 不会兜底。
public final class EmbeddableIslandPanel: NSPanel {
    public override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen: NSScreen?
    ) -> NSRect {
        return frameRect
    }
}
