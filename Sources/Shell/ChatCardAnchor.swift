// Sources/Shell/ChatCardAnchor.swift
import Foundation

/// 卡片相对 pet 的方位 = tail 指向 pet 的边。也用来决定 spring 进场的缩放锚点。
public enum ChatCardEdge: Sendable, Equatable {
    case above   // 卡片在 pet 上方，tail 朝下（进场从底部放大）
    case below   // 卡片在 pet 下方，tail 朝上
    case left    // 卡片在 pet 左侧，tail 朝右
    case right   // 卡片在 pet 右侧，tail 朝左
}

/// 锚定结果：卡片窗口左下角原点（屏幕坐标，AppKit 习惯）+ tail 指向的边。
public struct ChatCardPlacement: Sendable, Equatable {
    public let origin: NSPoint
    public let edge: ChatCardEdge
    public init(origin: NSPoint, edge: ChatCardEdge) {
        self.origin = origin
        self.edge = edge
    }
}

/// 把对话卡片锚定到 pet 旁的纯函数。**只用 NSGeometry 值类型，不碰 NSWindow/NSScreen
/// → 无头可确定性测试**（参考 AccountyCat (https://github.com/strjonas/AccountyCat) 的 CompanionGeometry.popoverPlacement，
/// 但简化为四方位 + overflow fallback）。
///
/// 选边优先级：above → below → right → left（先竖向，贴合「头顶气泡」直觉；横向作兜底）。
/// 四面都放不下 → 取 overflow（need − space）最小的那条。选定边后在正交轴 clamp 进屏。
public enum ChatCardAnchor {
    public static func place(
        anchor petRect: NSRect,
        in visibleFrame: NSRect,
        cardSize: NSSize,
        gap: CGFloat = 10,
        margin: CGFloat = 12
    ) -> ChatCardPlacement {
        let edge = chooseEdge(petRect: petRect, visible: visibleFrame, card: cardSize, gap: gap, margin: margin)
        let raw = rawOrigin(edge: edge, petRect: petRect, card: cardSize, gap: gap)
        let clamped = clampOntoScreen(origin: raw, edge: edge, visible: visibleFrame, card: cardSize, margin: margin)
        return ChatCardPlacement(origin: clamped, edge: edge)
    }

    // MARK: - 选边

    private static func chooseEdge(petRect: NSRect, visible: NSRect, card: NSSize, gap: CGFloat, margin: CGFloat) -> ChatCardEdge {
        let needV = card.height + gap + margin
        let needH = card.width + gap + margin
        let spaceAbove = visible.maxY - petRect.maxY
        let spaceBelow = petRect.minY - visible.minY
        let spaceRight = visible.maxX - petRect.maxX
        let spaceLeft = petRect.minX - visible.minX

        if spaceAbove >= needV { return .above }
        if spaceBelow >= needV { return .below }
        if spaceRight >= needH { return .right }
        if spaceLeft >= needH { return .left }

        // 四面都不够：取 overflow 最小者（越接近放得下越好）。顺序即并列时的偏好。
        let candidates: [(ChatCardEdge, CGFloat)] = [
            (.above, needV - spaceAbove),
            (.below, needV - spaceBelow),
            (.right, needH - spaceRight),
            (.left, needH - spaceLeft),
        ]
        return candidates.min(by: { $0.1 < $1.1 })!.0
    }

    // MARK: - 原点（未 clamp）

    private static func rawOrigin(edge: ChatCardEdge, petRect: NSRect, card: NSSize, gap: CGFloat) -> NSPoint {
        switch edge {
        case .above:
            return NSPoint(x: petRect.midX - card.width / 2, y: petRect.maxY + gap)
        case .below:
            return NSPoint(x: petRect.midX - card.width / 2, y: petRect.minY - gap - card.height)
        case .right:
            return NSPoint(x: petRect.maxX + gap, y: petRect.midY - card.height / 2)
        case .left:
            return NSPoint(x: petRect.minX - gap - card.width, y: petRect.midY - card.height / 2)
        }
    }

    // MARK: - clamp 进屏（正交轴）

    private static func clampOntoScreen(origin: NSPoint, edge: ChatCardEdge, visible: NSRect, card: NSSize, margin: CGFloat) -> NSPoint {
        switch edge {
        case .above, .below:
            // 竖向放置 → 卡片可能横向溢出 → clamp X
            let x = clamp(origin.x, lo: visible.minX + margin, hi: visible.maxX - card.width - margin)
            return NSPoint(x: x, y: origin.y)
        case .left, .right:
            // 横向放置 → 卡片可能纵向溢出 → clamp Y
            let y = clamp(origin.y, lo: visible.minY + margin, hi: visible.maxY - card.height - margin)
            return NSPoint(x: origin.x, y: y)
        }
    }

    /// hi < lo（卡片比屏还大）时退化为 lo（左/下对齐），不再二次保证。
    private static func clamp(_ v: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        guard hi > lo else { return lo }
        return Swift.min(Swift.max(v, lo), hi)
    }

    // MARK: - Tail（尖角指向 pet）

    /// 卡片相对 pet 的边 → tail 指向 pet 的边（`SpeechBubbleShape` 语义：卡片在 pet 上方 → tail 朝下）。
    public static func tailSide(for edge: ChatCardEdge) -> SpeechBubbleTailSide {
        switch edge {
        case .above: return .bottom
        case .below: return .top
        case .left:  return .right
        case .right: return .left
        }
    }

    /// tail 在所在边上的相对位置（指向 pet 中心），clamp 到 [0.15, 0.85] 防顶到圆角。
    /// 横向边(above/below)按 X；竖向边(left/right)按 SwiftUI **Y-down** 折算（屏幕 Y-up → 视图 Y-down）。
    public static func tailPercent(edge: ChatCardEdge, petRect: NSRect, cardOrigin: NSPoint, cardSize: NSSize) -> CGFloat {
        let raw: CGFloat
        switch edge {
        case .above, .below:
            raw = (petRect.midX - cardOrigin.x) / cardSize.width
        case .left, .right:
            // 视图 Y-down：view 顶 = 屏幕 maxY(cardOrigin.y + height)，view 底 = 屏幕 minY。
            raw = ((cardOrigin.y + cardSize.height) - petRect.midY) / cardSize.height
        }
        return Swift.max(0.15, Swift.min(0.85, raw))
    }
}
