import Foundation
import Testing
@testable import Shell

/// 锚定纯函数无头回归。屏：1440×875 可见区。卡片：360×460（gap10/margin12 → needV=482, needH=382）。
@Suite("ChatCardAnchor 锚定")
struct ChatCardAnchorTests {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    let card = NSSize(width: 360, height: 460)

    @Test("pet 在屏中下部 → above，水平居中、贴 pet 上方")
    func centerChoosesAbove() {
        let pet = NSRect(x: 700, y: 300, width: 80, height: 80)  // maxY=380, spaceAbove=495≥482
        let p = ChatCardAnchor.place(anchor: pet, in: screen, cardSize: card)
        #expect(p.edge == .above)
        #expect(p.origin.y == pet.maxY + 10)
        #expect(abs(p.origin.x - (pet.midX - card.width / 2)) < 0.5)  // 740-180=560
    }

    @Test("pet 贴屏顶 → below")
    func topChoosesBelow() {
        let pet = NSRect(x: 700, y: 500, width: 80, height: 80)  // maxY=580 spaceAbove=295<482; minY=500≥482
        let p = ChatCardAnchor.place(anchor: pet, in: screen, cardSize: card)
        #expect(p.edge == .below)
        #expect(p.origin.y == pet.minY - 10 - card.height)
    }

    @Test("极矮屏上下都不够 → right（横向 fallback）")
    func shortScreenChoosesRight() {
        let shortScreen = NSRect(x: 0, y: 0, width: 1440, height: 300)
        let pet = NSRect(x: 200, y: 130, width: 80, height: 80)  // 上下均 < 302；spaceRight=1160≥382
        let p = ChatCardAnchor.place(anchor: pet, in: shortScreen, cardSize: NSSize(width: 360, height: 280))
        #expect(p.edge == .right)
    }

    @Test("pet 贴右边但上方够 → above 且 X clamp 进屏")
    func rightEdgeClampsX() {
        let pet = NSRect(x: 1340, y: 300, width: 80, height: 80)  // maxX=1420 在屏内；midX=1380 raw x 溢出
        let p = ChatCardAnchor.place(anchor: pet, in: screen, cardSize: card)
        #expect(p.edge == .above)
        #expect(p.origin.x + card.width <= screen.maxX - 12 + 0.5)  // clamp 到 maxX-margin
    }

    @Test("pet 贴左下角 → X clamp 到左 margin，不溢出左边")
    func leftBottomClampsX() {
        let pet = NSRect(x: 0, y: 200, width: 80, height: 80)  // midX=40 raw x=-140
        let p = ChatCardAnchor.place(anchor: pet, in: screen, cardSize: card)
        #expect(p.edge == .above)
        #expect(p.origin.x >= screen.minX + 12 - 0.5)
    }

    @Test("四面全不够（巨卡片小屏）→ 取 overflow 最小者（并列取 above）")
    func tooBigChoosesMinOverflow() {
        let tiny = NSRect(x: 0, y: 0, width: 400, height: 400)
        let pet = NSRect(x: 180, y: 180, width: 40, height: 40)  // 居中，四面 overflow 并列
        let p = ChatCardAnchor.place(anchor: pet, in: tiny, cardSize: NSSize(width: 380, height: 380))
        #expect(p.edge == .above)
    }

    @Test("pet 贴右边且上下都不够 → left（右侧不足翻左）")
    func rightEdgeNoVerticalChoosesLeft() {
        let shortScreen = NSRect(x: 0, y: 0, width: 1440, height: 300)
        let pet = NSRect(x: 1380, y: 130, width: 50, height: 50)  // maxX=1430 spaceRight=10<382; spaceLeft=1380≥382
        let p = ChatCardAnchor.place(anchor: pet, in: shortScreen, cardSize: NSSize(width: 360, height: 280))
        #expect(p.edge == .left)
    }

    // MARK: - Tail（尖角指向 pet）

    @Test("edge → tailSide 映射（卡片在 pet 上方 → 尖角朝下）")
    func edgeToTailSide() {
        #expect(ChatCardAnchor.tailSide(for: .above) == .bottom)
        #expect(ChatCardAnchor.tailSide(for: .below) == .top)
        #expect(ChatCardAnchor.tailSide(for: .left) == .right)
        #expect(ChatCardAnchor.tailSide(for: .right) == .left)
    }

    @Test("横向边 tailPercent 按 X：pet 在卡片水平中点 → 0.5")
    func tailPercentHorizontalCentered() {
        let cardOrigin = NSPoint(x: 560, y: 400)   // card 360 宽 → midX=740
        let pet = NSRect(x: 700, y: 300, width: 80, height: 80)  // midX=740
        let pct = ChatCardAnchor.tailPercent(edge: .above, petRect: pet, cardOrigin: cardOrigin, cardSize: card)
        #expect(abs(pct - 0.5) < 0.01)
    }

    @Test("tailPercent clamp 到 [0.15, 0.85]：pet 远在卡片左侧 → 0.15")
    func tailPercentClampedLow() {
        let cardOrigin = NSPoint(x: 700, y: 400)
        let pet = NSRect(x: 0, y: 300, width: 80, height: 80)  // midX=40 ≪ cardOrigin.x → 负比例
        let pct = ChatCardAnchor.tailPercent(edge: .above, petRect: pet, cardOrigin: cardOrigin, cardSize: card)
        #expect(pct == 0.15)
    }

    @Test("竖向边 tailPercent 按 Y-down 折算：pet 在卡片竖直中点 → 0.5")
    func tailPercentVerticalCentered() {
        let cardOrigin = NSPoint(x: 800, y: 200)   // card 460 高 → 屏幕 Y 跨 [200,660]，中点 430
        let pet = NSRect(x: 700, y: 410, width: 40, height: 40)  // midY=430
        let pct = ChatCardAnchor.tailPercent(edge: .right, petRect: pet, cardOrigin: cardOrigin, cardSize: card)
        #expect(abs(pct - 0.5) < 0.01)
    }
}
