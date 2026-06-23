import AppKit
import Testing
@testable import Shell

/// N1 灵动岛骨架的单测。所有测试在物理 macOS 进程内跑(有 `NSScreen.main`),
/// 不需要 mock screen。
///
/// 覆盖范围:
/// - `EmbeddableIslandPanel.constrainFrameRect` 不收紧 frame(决策 #1)
/// - `reverseNotchGeometry` 在带/不带刘海屏上反推几何 + fallback 正确
/// - 形态常量(idleDrop / idleExtraWidth / fallbackNotchWidth/Height)语义稳定
/// - panel 创建后顶贴 screen.maxY + 横向与真刘海中心对齐 + 尺寸 = 几何 + 探出
/// - `isEnabled` 切换正确控制 panel order
/// - `handleMouseDown(at:)` hit-test 判定正确
/// - `hasNotch(_:)` / `mainScreenHasNotch()` 在任意 screen 上不崩、返回 Bool
@MainActor
@Suite("DynamicIslandController — 灵动岛骨架")
struct DynamicIslandControllerTests {

    // MARK: - 测试辅助

    /// 真实的 NSScreen——单测在物理机上跑,NSScreen.main 必然存在。
    /// 如果某天 CI 上是 headless,需要换成 mock,但目前用真实 screen 最稳。
    private var screen: NSScreen {
        guard let screen = NSScreen.main else {
            fatalError("DynamicIslandControllerTests 需要 NSScreen.main 可用")
        }
        return screen
    }

    /// 当前 screen 反推出来的真刘海几何(测试机带刘海则返回真值, 否则
    /// fallback)。所有"动态尺寸"断言都靠它当参考, 避免在测试里重复算。
    private var geometry: (width: CGFloat, height: CGFloat, centerX: CGFloat) {
        DynamicIslandController.reverseNotchGeometry(from: screen)
    }

    // MARK: - 决策 #1:constrainFrameRect 不收紧 frame

    @Test("EmbeddableIslandPanel.constrainFrameRect 原样返回 frameRect (决策 #1)")
    func embeddableIslandPanelConstrainFrameRectReturnsOriginal() {
        let panel = EmbeddableIslandPanel(
            contentRect: NSRect(x: 100, y: 100, width: 280, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let arbitraryFrame = NSRect(x: 7, y: 9999, width: 280, height: 40)
        let constrained = panel.constrainFrameRect(arbitraryFrame, to: screen)
        // 必须原样返回——AppKit 默认会把 y 压回 visibleFrame, 我们 override 跳过约束。
        #expect(constrained == arbitraryFrame)
    }

    @Test("EmbeddableIslandPanel.constrainFrameRect 在 nil screen 下也原样返回")
    func embeddableIslandPanelConstrainFrameRectWithNilScreen() {
        let panel = EmbeddableIslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let arbitraryFrame = NSRect(x: -50, y: -50, width: 280, height: 40)
        let constrained = panel.constrainFrameRect(arbitraryFrame, to: nil)
        #expect(constrained == arbitraryFrame)
    }

    // MARK: - 形态常量

    @Test("idleDrop = 4 (耳朵融入刘海, 不再挂在刘海下面)")
    func idleDropConstant() {
        #expect(DynamicIslandController.idleDrop == 4)
    }

    @Test("idleExtraWidth = 80 (两侧探出耳朵总宽)")
    func idleExtraWidthConstant() {
        #expect(DynamicIslandController.idleExtraWidth == 80)
    }

    @Test("fallback 几何 = 180×32 (无刘海机型兜底)")
    func fallbackGeometryConstants() {
        #expect(DynamicIslandController.fallbackNotchWidth == 180)
        #expect(DynamicIslandController.fallbackNotchHeight == 32)
    }

    // MARK: - 几何反推(纯函数)

    @Test("reverseNotchGeometry 在任意 screen 上不崩 + 返回合理值")
    func reverseNotchGeometryDoesNotCrash() {
        let g = DynamicIslandController.reverseNotchGeometry(from: screen)
        // width / height 必须为正(无刘海走 fallback 180×32, 带刘海走实测)
        #expect(g.width > 0)
        #expect(g.height > 0)
        // centerX 必须落在屏幕范围内
        #expect(g.centerX >= screen.frame.minX)
        #expect(g.centerX <= screen.frame.maxX)
    }

    @Test("reverseNotchGeometry 无刘海(safeArea.top == 0)→ fallback 180×32 + 屏幕中线")
    func reverseNotchGeometryFallbackOnNoNotch() {
        // 物理判定: 若测试机本身无刘海, 必须返回 fallback; 若带刘海, 此测试
        // 在带刘海机型上不适用(直接跳过断言, 不算 fail)。
        if !DynamicIslandController.hasNotch(screen) {
            let g = DynamicIslandController.reverseNotchGeometry(from: screen)
            #expect(g.width == DynamicIslandController.fallbackNotchWidth)
            #expect(g.height == DynamicIslandController.fallbackNotchHeight)
            #expect(abs(g.centerX - screen.frame.midX) < 0.5)
        }
    }

    @Test("reverseNotchGeometry 带刘海屏 → width/height 落在合理范围(MBP 14 / 16 寸)")
    func reverseNotchGeometryOnNotchedScreen() {
        // 只在测试机本身带刘海时跑此断言。MBP 14"/16" 的刘海宽度通常在
        // 150-220pt 之间, 高度 32-42pt。给宽松上下界, 任何带刘海机型都该过。
        if DynamicIslandController.hasNotch(screen) {
            let g = DynamicIslandController.reverseNotchGeometry(from: screen)
            #expect(g.width >= 100, "刘海宽 \(g.width) 异常偏小")
            #expect(g.width <= 400, "刘海宽 \(g.width) 异常偏大")
            #expect(g.height >= 20, "刘海高 \(g.height) 异常偏小")
            #expect(g.height <= 60, "刘海高 \(g.height) 异常偏大")
        }
    }

    // MARK: - 安装位置

    @Test("init 后 panel 顶贴 screen.frame.maxY")
    func initPositionsPanelAtScreenTop() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        let panelFrame = controller.pillWindow.frame
        // origin.y == screenFrame.maxY - pillHeight, maxY == screenFrame.maxY
        #expect(panelFrame.maxY == screen.frame.maxY)
    }

    @Test("init 后 panel 横向与真刘海中心对齐 (而非 screen.midX)")
    func initPositionsPanelAlignedWithNotchCenter() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        let panelFrame = controller.pillWindow.frame
        let expectedMidX = geometry.centerX
        // midX 浮点容差: 像素 < 0.5
        #expect(abs(panelFrame.midX - expectedMidX) < 0.5)
    }

    @Test("init 后 panel size = notch 几何 + 探出(width = notchW+80, height = notchH+4)")
    func initPanelSizeMatchesNotchPlusExtras() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        let panelFrame = controller.pillWindow.frame
        let expectedWidth = geometry.width + DynamicIslandController.idleExtraWidth
        // 方案 E (2026-05-26): pillHeight = notchHeight (删 idleDrop=4),
        // 让 panel 高度跟物理刘海一致, 全屏 app 时无小黑边。
        let expectedHeight = geometry.height
        #expect(panelFrame.size.width == expectedWidth)
        #expect(panelFrame.size.height == expectedHeight)
    }

    @Test("init 后控制器缓存的 notchWidth/notchHeight == 反推几何")
    func controllerCachesReverseGeometry() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        #expect(controller.notchWidth == geometry.width)
        #expect(controller.notchHeight == geometry.height)
    }

    @Test("panel.contentView 形态: SwiftUI hosting view 撑满 panel frame")
    func panelContentViewStyling() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        guard let contentView = controller.pillWindow.contentView else {
            Issue.record("panel.contentView 缺失")
            return
        }
        // 灵动岛内容现在是 SwiftUI Capsule (via NSHostingController),圆角由
        // SwiftUI Capsule 的 mask 处理而非 CALayer.cornerRadius。验证
        // hosting view 撑满 panel frame, autoresizingMask 含 [.width, .height]
        // 这样 panel.setFrame 之后 SwiftUI 内容跟着 resize。
        #expect(contentView.frame.size == controller.pillWindow.frame.size)
        #expect(contentView.autoresizingMask.contains(.width))
        #expect(contentView.autoresizingMask.contains(.height))
    }

    // MARK: - isEnabled 生命周期

    @Test("isEnabled = false 时 panel 隐藏 (不可见)")
    func isEnabledFalseHidesPanel() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        #expect(controller.pillWindow.isVisible == false)
    }

    @Test("isEnabled = true 时 panel 显示 (可见)")
    func isEnabledTrueShowsPanel() {
        let controller = DynamicIslandController(screen: screen, isEnabled: true)
        // orderFrontRegardless 后 isVisible 应为 true
        #expect(controller.pillWindow.isVisible == true)
        controller.isEnabled = false  // teardown 隐藏避免污染其他测试
    }

    @Test("isEnabled 从 false 切到 true 触发 orderFrontRegardless")
    func isEnabledTransitionFalseToTrue() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        #expect(controller.pillWindow.isVisible == false)
        controller.isEnabled = true
        #expect(controller.pillWindow.isVisible == true)
        controller.isEnabled = false
    }

    @Test("isEnabled 从 true 切到 false 触发 orderOut")
    func isEnabledTransitionTrueToFalse() {
        let controller = DynamicIslandController(screen: screen, isEnabled: true)
        #expect(controller.pillWindow.isVisible == true)
        controller.isEnabled = false
        #expect(controller.pillWindow.isVisible == false)
    }

    // MARK: - Hit-test (决策 #2)

    @Test("handleMouseDown 命中 hitRect 内 → onTapped 触发")
    func handleMouseDownInsideHitRectTriggers() {
        let controller = DynamicIslandController(screen: screen, isEnabled: true)
        var tapCount = 0
        controller.onTapped = { tapCount += 1 }
        // panel 中心点必然在 hitRect 内
        let center = NSPoint(
            x: controller.pillWindow.frame.midX,
            y: controller.pillWindow.frame.midY
        )
        controller.handleMouseDown(at: center)
        #expect(tapCount == 1)
        controller.isEnabled = false
    }

    @Test("handleMouseDown 命中 hitRect 外 → onTapped 不触发")
    func handleMouseDownOutsideHitRectDoesNotTrigger() {
        let controller = DynamicIslandController(screen: screen, isEnabled: true)
        var tapCount = 0
        controller.onTapped = { tapCount += 1 }
        // 屏幕左下角:必然在 panel frame 之外(panel 在屏幕顶部中央)
        let bottomLeft = NSPoint(x: 0, y: 0)
        controller.handleMouseDown(at: bottomLeft)
        #expect(tapCount == 0)
        controller.isEnabled = false
    }

    @Test("isEnabled = false 时即使点中 hitRect 也不触发 onTapped")
    func handleMouseDownWhileDisabledDoesNotTrigger() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        var tapCount = 0
        controller.onTapped = { tapCount += 1 }
        let center = NSPoint(
            x: controller.pillWindow.frame.midX,
            y: controller.pillWindow.frame.midY
        )
        controller.handleMouseDown(at: center)
        #expect(tapCount == 0)
    }

    @Test("onTapped == nil 时点中 hitRect 不崩")
    func handleMouseDownWithoutCallbackDoesNotCrash() {
        let controller = DynamicIslandController(screen: screen, isEnabled: true)
        controller.onTapped = nil
        let center = NSPoint(
            x: controller.pillWindow.frame.midX,
            y: controller.pillWindow.frame.midY
        )
        controller.handleMouseDown(at: center)
        // 测试目标:不 crash 即通过
        controller.isEnabled = false
    }

    // MARK: - panel 配置(决策 #2 关联)

    @Test("panel.ignoresMouseEvents = true (决策 #2)")
    func panelIgnoresMouseEvents() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        #expect(controller.pillWindow.ignoresMouseEvents == true)
    }

    @Test("panel.level = .statusBar (高于普通 floating)")
    func panelLevelIsStatusBar() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        #expect(controller.pillWindow.level == .statusBar)
    }

    @Test("panel 是 borderless + 透明背景 (跟刘海融合)")
    func panelIsBorderlessAndTransparent() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        #expect(controller.pillWindow.styleMask.contains(.borderless))
        #expect(controller.pillWindow.isOpaque == false)
        #expect(controller.pillWindow.hasShadow == false)
    }

    @Test("panel collectionBehavior 包含 canJoinAllSpaces + stationary (跨空间常驻)")
    func panelCollectionBehaviorIsCrossSpace() {
        let controller = DynamicIslandController(screen: screen, isEnabled: false)
        let behavior = controller.pillWindow.collectionBehavior
        #expect(behavior.contains(.canJoinAllSpaces))
        #expect(behavior.contains(.stationary))
        #expect(behavior.contains(.fullScreenAuxiliary))
        #expect(behavior.contains(.ignoresCycle))
    }

    // MARK: - Notch 探测

    @Test("hasNotch 接受任意 screen,返回 Bool 不崩")
    func hasNotchAcceptsArbitraryScreen() {
        // 物理执行: 不关心返回值是 true 还是 false(取决于跑测试的机器是否带刘海),
        // 只验证不崩 + 返回 Bool。
        _ = DynamicIslandController.hasNotch(screen)
    }

    @Test("mainScreenHasNotch 不崩 + 返回 Bool")
    func mainScreenHasNotchDoesNotCrash() {
        _ = DynamicIslandController.mainScreenHasNotch()
    }

    @Test("mainScreenHasNotch 跟 任意屏带刘海 一致")
    func mainScreenHasNotchMatchesAnyScreenHasNotch() {
        let anyHasNotch = NSScreen.screens.contains {
            DynamicIslandController.hasNotch($0)
        }
        #expect(DynamicIslandController.mainScreenHasNotch() == anyHasNotch)
    }

    // 方案 E (2026-05-26): Task A "Space 切换 fade out/in" 整套删除 ——
    // macOS 公开 API 没有 Space transition begin 事件 (NSEvent.swipe 在
    // 系统手势期间不发, activeSpaceDidChange 是事后通知), 这套逻辑实际
    // 制造"切完闪一下"视觉 bug 而非消除重影。HermesPet 同款选择: 接受
    // panel 一直可见, .stationary 让 macOS 渲染层把 panel 锚定在物理屏顶。
    // 6 个 Task A 测试 + spaceTransitionDebounce/FadeOut/FadeIn 常量
    // + hideForSpaceTransition / scheduleFadeIn / fadeInTriggerCount 全删。
}
