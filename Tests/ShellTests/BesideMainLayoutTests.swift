import Testing
import AppKit
@testable import Shell

@Suite("BesideMainLayout — 贴主卡侧定位(列容器/sheet 统一)")
struct BesideMainLayoutTests {
    let screen = NSRect(x: 0, y: 0, width: 1800, height: 1100)

    @Test("右侧空间够 → 贴右,gap=12,顶对齐主卡")
    func docksRightWhenRoom() {
        let main = NSRect(x: 200, y: 300, width: 360, height: 480)   // maxX=560,右侧剩 1240
        let f = BesideMainLayout.frame(maxSize: NSSize(width: 420, height: 460), mainFrame: main, screen: screen)
        #expect(f.minX == main.maxX + 12)            // 贴右
        #expect(f.width == 420)                       // 够放 → 不缩
        #expect(f.maxY == main.maxY)                  // 顶对齐(maxY - h ... h=460,maxY=780 → y=320,maxY=780)
    }

    @Test("右侧不够且左侧更大 → 贴左")
    func docksLeftWhenRightTight() {
        let main = NSRect(x: 1300, y: 300, width: 360, height: 480)  // maxX=1660,右剩 ~128 放不下 420;左剩 ~1276
        let f = BesideMainLayout.frame(maxSize: NSSize(width: 420, height: 460), mainFrame: main, screen: screen)
        #expect(f.maxX == main.minX - 12)            // 贴左:面板右缘 = 主卡左缘 - gap
        #expect(f.width == 420)
    }

    @Test("面板高 = 主卡高 → 顶对齐即底对齐(列容器场景一致)")
    func fullHeightAlignsBoth() {
        let main = NSRect(x: 200, y: 300, width: 360, height: 480)
        let f = BesideMainLayout.frame(maxSize: NSSize(width: 300, height: 480), mainFrame: main, screen: screen)
        #expect(f.minY == main.minY)                 // 等高 → 顶对齐 == 底对齐
        #expect(f.maxY == main.maxY)
    }

    @Test("超宽(列容器内容超可用宽)→ 取该侧可用宽,内部横滚")
    func clampsWidthToAvailable() {
        let main = NSRect(x: 1400, y: 300, width: 360, height: 480)  // 右剩 ~16,左剩 ~1376
        let f = BesideMainLayout.frame(maxSize: NSSize(width: 5000, height: 480), mainFrame: main, screen: screen)
        #expect(f.width < 5000)                       // 缩到可用宽
        #expect(f.width <= main.minX - 12 - 12)       // 不超左侧可用
    }
}
