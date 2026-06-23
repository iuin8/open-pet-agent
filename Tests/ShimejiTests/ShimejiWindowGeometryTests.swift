import Foundation
import Testing
import PetBehavior
@testable import Shimeji

@Suite("ShimejiWindowGeometry")
struct ShimejiWindowGeometryTests {
    @Test("anchor(top-origin) − imageAnchor → NSWindow bottom-origin frame")
    func windowFrameConversion() {
        // anchor(700,300) top-origin,imageAnchor(64,128),图 128×128,屏高 1080
        let rect = ShimejiWindowGeometry.windowFrame(
            anchor: BehaviorPoint(x: 700, y: 300),
            imageAnchorX: 64, imageAnchorY: 128,
            imageWidth: 128, imageHeight: 128,
            screenHeight: 1080)
        #expect(rect.origin.x == 636)            // 700 − 64
        #expect(rect.origin.y == 780)            // 1080 − (300−128) − 128
        #expect(rect.width == 128)
        #expect(rect.height == 128)
    }

    @Test("脚底锚点在屏幕地面(top y=1040)→ 窗口底贴 bottom-origin y=40")
    func footOnFloor() {
        // anchor 在 workArea 底(y=1040),imageAnchor 在脚底中心(64,128)→ 窗口底边在屏底上方 40(Dock)
        let rect = ShimejiWindowGeometry.windowFrame(
            anchor: BehaviorPoint(x: 960, y: 1040),
            imageAnchorX: 64, imageAnchorY: 128,
            imageWidth: 128, imageHeight: 128,
            screenHeight: 1080)
        // 窗口顶 top-origin = 1040−128 = 912;底边 top-origin = 912+128 = 1040;bottom-origin y = 1080−1040 = 40
        #expect(rect.origin.y == 40)
        #expect(rect.origin.x == 896)            // 960 − 64
    }

    @Test("右向图锚点 x 镜像(由调用方传入镜像后的 imageAnchorX)")
    func mirroredAnchor() {
        // 同 anchor,镜像后 imageAnchorX = w − 64 = 64(对称图巧合相等);用非对称锚点验证
        let rect = ShimejiWindowGeometry.windowFrame(
            anchor: BehaviorPoint(x: 700, y: 300),
            imageAnchorX: 128 - 40, imageAnchorY: 128,   // 原锚 40,镜像 → 88
            imageWidth: 128, imageHeight: 128,
            screenHeight: 1080)
        #expect(rect.origin.x == 612)   // 700 − 88(镜像锚点)
    }

    @Test("PF6 scale:窗口等比放大 + 脚底锚点世界位置不动")
    func scaledKeepsAnchor() {
        // 脚站地面(anchor 960,1040,imageAnchor 64,128,图 128×128)。scale=2 → 窗口 256×256,
        // 但脚底锚点(屏幕位置)必须不动:bottom-origin 窗底 y 仍 = 40,脚的 x 仍 = 960。
        let s1 = ShimejiWindowGeometry.windowFrame(
            anchor: BehaviorPoint(x: 960, y: 1040), imageAnchorX: 64, imageAnchorY: 128,
            imageWidth: 128, imageHeight: 128, screenHeight: 1080)
        let s2 = ShimejiWindowGeometry.windowFrame(
            anchor: BehaviorPoint(x: 960, y: 1040), imageAnchorX: 64, imageAnchorY: 128,
            imageWidth: 128, imageHeight: 128, screenHeight: 1080, scale: 2)
        // 尺寸翻倍
        #expect(s2.width == 256)
        #expect(s2.height == 256)
        // 脚底锚点世界位置不动:窗口底边 bottom-origin y 不变(脚贴地);脚的世界 x(= origin.x + anchorX*scale)不变
        #expect(s2.origin.y == s1.origin.y)                 // 40,脚仍贴地
        #expect(s2.origin.x + 64 * 2 == s1.origin.x + 64)   // 脚 x = 960 两边相等
        // scale=1 与默认无参一致
        let sDefault = ShimejiWindowGeometry.windowFrame(
            anchor: BehaviorPoint(x: 960, y: 1040), imageAnchorX: 64, imageAnchorY: 128,
            imageWidth: 128, imageHeight: 128, screenHeight: 1080, scale: 1)
        #expect(sDefault == s1)
    }
}
