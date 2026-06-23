import AppKit
import Testing
@testable import Shell

@MainActor
@Suite("MouseAreaTracker — 全局光标 X 区域追踪")
struct MouseAreaTrackerTests {

    // MARK: - Pure classify (纯函数,覆盖各边界 case)

    @Test("classify: x < 40% → .left")
    func classifyLeft() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: 0, y: 100), screenFrame: frame) == .left)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: 399, y: 100), screenFrame: frame) == .left)
    }

    @Test("classify: 40% ≤ x ≤ 60% → .center")
    func classifyCenter() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: 400, y: 100), screenFrame: frame) == .center)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: 500, y: 100), screenFrame: frame) == .center)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: 600, y: 100), screenFrame: frame) == .center)
    }

    @Test("classify: x > 60% → .right")
    func classifyRight() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: 601, y: 100), screenFrame: frame) == .right)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: 1000, y: 100), screenFrame: frame) == .right)
    }

    @Test("classify: 鼠标在屏幕 frame 之外 → .center(其他屏视为中性)")
    func classifyOutsideScreen() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: -100, y: 100), screenFrame: frame) == .center)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: 2000, y: 100), screenFrame: frame) == .center)
    }

    @Test("classify: screenFrame nil → .center(无屏可参考)")
    func classifyNilScreen() {
        #expect(MouseAreaTracker.classify(location: NSPoint(x: 0, y: 0), screenFrame: nil) == .center)
    }

    @Test("classify: 屏幕 origin 非 0 时按相对位置算")
    func classifyOffsetScreen() {
        // 外接屏 frame.origin = (1920, 0),width 1280
        let frame = NSRect(x: 1920, y: 0, width: 1280, height: 800)
        let xCenter = 1920 + 1280 * 0.5
        let xLeft = 1920 + 1280 * 0.2
        let xRight = 1920 + 1280 * 0.8
        #expect(MouseAreaTracker.classify(location: NSPoint(x: xCenter, y: 100), screenFrame: frame) == .center)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: xLeft, y: 100), screenFrame: frame) == .left)
        #expect(MouseAreaTracker.classify(location: NSPoint(x: xRight, y: 100), screenFrame: frame) == .right)
    }

    // MARK: - Callback + 去重

    @Test("初始 currentArea 是 .center")
    func initialCurrentArea() {
        let tracker = MouseAreaTracker { (NSPoint(x: 500, y: 0), NSRect(x: 0, y: 0, width: 1000, height: 100)) }
        #expect(tracker.currentArea == .center)
    }

    @Test("evaluateAndNotify: area 变化触发 callback + 更新 currentArea")
    func callbackFiresOnAreaChange() {
        var captured: [MouseAreaTracker.MouseArea] = []
        let positions = [NSPoint(x: 100, y: 0), NSPoint(x: 500, y: 0), NSPoint(x: 900, y: 0)]
        var idx = 0
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 100)

        let tracker = MouseAreaTracker {
            let p = positions[idx]
            idx += 1
            return (p, frame)
        }
        tracker.onAreaChanged = { area in captured.append(area) }

        tracker.evaluateAndNotify()  // left
        tracker.evaluateAndNotify()  // center
        tracker.evaluateAndNotify()  // right

        #expect(captured == [.left, .center, .right])
        #expect(tracker.currentArea == .right)
    }

    @Test("evaluateAndNotify: 同 area 反复触发不调 callback(去重)")
    func sameAreaDoesNotFireCallback() {
        var callCount = 0
        let tracker = MouseAreaTracker {
            (NSPoint(x: 800, y: 0), NSRect(x: 0, y: 0, width: 1000, height: 100))
        }
        tracker.onAreaChanged = { _ in callCount += 1 }

        tracker.evaluateAndNotify()  // center → right, fire
        tracker.evaluateAndNotify()  // right → right, skip
        tracker.evaluateAndNotify()  // right → right, skip

        #expect(callCount == 1)
    }

    // MARK: - Lifecycle

    @Test("start / stop 是幂等的")
    func startStopIdempotent() {
        let tracker = MouseAreaTracker()
        #expect(tracker.isRunning == false)
        tracker.start()
        #expect(tracker.isRunning == true)
        tracker.start()  // 二次 start no-op
        #expect(tracker.isRunning == true)
        tracker.stop()
        #expect(tracker.isRunning == false)
        tracker.stop()  // 二次 stop no-op
        #expect(tracker.isRunning == false)
    }
}
