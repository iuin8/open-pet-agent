import Foundation
import Testing
import Context
import PetBehavior
@testable import Shimeji

@MainActor
@Suite("DesktopEnvironmentProvider")
struct DesktopEnvironmentProviderTests {
    // 1920×1080 屏,Dock 40px(visibleFrame bottom-origin (0,40,1920,1040))。
    private let screenW = 1920.0
    private let screenH = 1080.0
    private let workArea = Rect(origin: Point(x: 0, y: 40), width: 1920, height: 1040)

    @Test("cursor bottom-origin → top-origin 翻转")
    func cursorFlip() {
        let provider = DesktopEnvironmentProvider()
        let snapshot = DesktopSnapshot(cursorPosition: Point(x: 500, y: 700))   // bottom-origin
        let env = provider.environment(snapshot: snapshot, workAreaBottomOrigin: workArea,
                                       screenWidth: screenW, screenHeight: screenH)
        #expect(env.cursor.x == 500)
        #expect(env.cursor.y == 1080 - 700)   // 380 top-origin
    }

    @Test("workArea bottom-origin visibleFrame → top-origin(floor=bottom=1040)")
    func workAreaFlip() {
        let provider = DesktopEnvironmentProvider()
        let env = provider.environment(snapshot: DesktopSnapshot(), workAreaBottomOrigin: workArea,
                                       screenWidth: screenW, screenHeight: screenH)
        #expect(env.workArea.top == 0)        // 1080 − (40+1040)
        #expect(env.workArea.bottom == 1040)  // 1080 − 40 = 地面(Dock 之上)
        #expect(env.workArea.left == 0)
        #expect(env.workArea.right == 1920)
        #expect(env.screen.bottom == 1080)    // 全屏
    }

    @Test("activeWindow 用 CGWindow top-origin bounds 直接映射")
    func activeWindowTopOrigin() {
        let provider = DesktopEnvironmentProvider()
        let snapshot = DesktopSnapshot(
            visibleApplicationName: "Xcode",
            visibleWindows: [
                VisibleWindowSnapshot(ownerName: "Finder", bounds: Rect(origin: Point(x: 0, y: 0), width: 100, height: 100)),
                VisibleWindowSnapshot(ownerName: "Xcode", bounds: Rect(origin: Point(x: 500, y: 300), width: 400, height: 400)),
            ])
        let env = provider.environment(snapshot: snapshot, workAreaBottomOrigin: workArea,
                                       screenWidth: screenW, screenHeight: screenH)
        // 选 visibleApplicationName=Xcode 的窗,bounds top-origin 直用
        #expect(env.activeWindow.left == 500)
        #expect(env.activeWindow.top == 300)
        #expect(env.activeWindow.right == 900)
        #expect(env.activeWindow.bottom == 700)
        #expect(env.activeWindow.visible == true)
    }

    @Test("无可见窗口 → activeWindow .invisible")
    func noActiveWindow() {
        let provider = DesktopEnvironmentProvider()
        let env = provider.environment(snapshot: DesktopSnapshot(), workAreaBottomOrigin: workArea,
                                       screenWidth: screenW, screenHeight: screenH)
        #expect(env.activeWindow.visible == false)
    }

    @Test("cursor 半衰速度跨帧累积(Thrown 初速源)")
    func cursorHalfDecayVelocity() {
        let provider = DesktopEnvironmentProvider()
        // 第一帧建立基线(无速度)
        _ = provider.environment(snapshot: DesktopSnapshot(cursorPosition: Point(x: 100, y: 540)),
                                 workAreaBottomOrigin: workArea, screenWidth: screenW, screenHeight: screenH)
        // 第二帧光标右移 40(top-origin x +40),dx 半衰 = (0 + 40)/2 = 20
        let env = provider.environment(snapshot: DesktopSnapshot(cursorPosition: Point(x: 140, y: 540)),
                                       workAreaBottomOrigin: workArea, screenWidth: screenW, screenHeight: screenH)
        #expect(env.cursor.dx == 20)
    }
}
