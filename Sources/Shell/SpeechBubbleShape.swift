import CoreGraphics
import Foundation

/// Which edge the speech bubble's tail (triangular pointer) lives on.
public enum SpeechBubbleTailSide: Sendable {
    case top, bottom, left, right
    /// No tail — degrades to a plain rounded rect.
    case none
}

/// Builds a `CGPath` for a rounded-corner speech bubble with a triangular
/// tail on any of four edges. Implemented in CoreGraphics so AppKit `NSView`s
/// can clip against it via `CAShapeLayer` masks without pulling in SwiftUI.
///
/// The tail center is clamped to the safe band between corner arcs so the
/// path never doubles back on a corner curve. Pathological inputs (`rect`
/// too small, tail wider than rect, etc.) degrade gracefully to a rounded
/// rect rather than throwing.
public enum SpeechBubbleShape {

    /// - Parameters:
    ///   - rect: View bounds the bubble must fit inside.
    ///   - cornerRadius: Card corner radius (default 14).
    ///   - tailSide: Which edge the tail extends from (default `.bottom`).
    ///   - tailPercent: Tail center along the tail edge in `0...1`. For top/
    ///     bottom this is an x-fraction, for left/right a y-fraction. Values
    ///     outside `[0, 1]` are clamped (defensive).
    ///   - tailHeight: How far the tail sticks out past the card (default 12).
    ///   - tailWidth: Tail base width along the card edge (default 14).
    public static func path(
        in rect: CGRect,
        cornerRadius: CGFloat = 14,
        tailSide: SpeechBubbleTailSide = .bottom,
        tailPercent: CGFloat = 0.5,
        tailHeight: CGFloat = 12,
        tailWidth: CGFloat = 14
    ) -> CGPath {
        guard rect.width > 0, rect.height > 0 else {
            return CGMutablePath()
        }

        // Degenerate corner radius: clamp to half the smaller side.
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        // Clamp tail percent to [0, 1].
        let pct = max(0, min(1, tailPercent))

        switch tailSide {
        case .none:
            return roundedRect(in: rect, radius: r)
        case .top:
            return topPath(in: rect, r: r, pct: pct, tailHeight: tailHeight, tailWidth: tailWidth)
        case .bottom:
            return bottomPath(in: rect, r: r, pct: pct, tailHeight: tailHeight, tailWidth: tailWidth)
        case .left:
            return leftPath(in: rect, r: r, pct: pct, tailHeight: tailHeight, tailWidth: tailWidth)
        case .right:
            return rightPath(in: rect, r: r, pct: pct, tailHeight: tailHeight, tailWidth: tailWidth)
        }
    }

    // MARK: - Per-edge builders

    private static func roundedRect(in rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Clamp tail center to the safe band between corner arcs so the tail
    /// never collides with a corner curve.
    private static func clamp(
        center: CGFloat,
        length: CGFloat,
        radius: CGFloat,
        tailWidth: CGFloat
    ) -> CGFloat {
        let minV = radius + tailWidth / 2
        let maxV = length - radius - tailWidth / 2
        guard minV <= maxV else { return length / 2 }
        return max(minV, min(center, maxV))
    }

    private static func bottomPath(
        in rect: CGRect, r: CGFloat, pct: CGFloat,
        tailHeight: CGFloat, tailWidth: CGFloat
    ) -> CGPath {
        // The card occupies `rect` minus `tailHeight` at the bottom; the
        // tail occupies that remaining strip in the middle.
        let cardBottom = rect.height - tailHeight
        guard cardBottom > 2 * r else { return roundedRect(in: rect, radius: r) }
        let tc = clamp(center: rect.width * pct, length: rect.width, radius: r, tailWidth: tailWidth)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: rect.width - r, y: 0))
        p.addArc(center: CGPoint(x: rect.width - r, y: r), radius: r,
                 startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        p.addLine(to: CGPoint(x: rect.width, y: cardBottom - r))
        p.addArc(center: CGPoint(x: rect.width - r, y: cardBottom - r), radius: r,
                 startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: tc + tailWidth / 2, y: cardBottom))
        p.addLine(to: CGPoint(x: tc, y: rect.height))
        p.addLine(to: CGPoint(x: tc - tailWidth / 2, y: cardBottom))
        p.addLine(to: CGPoint(x: r, y: cardBottom))
        p.addArc(center: CGPoint(x: r, y: cardBottom - r), radius: r,
                 startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addArc(center: CGPoint(x: r, y: r), radius: r,
                 startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        p.closeSubpath()
        return p
    }

    private static func topPath(
        in rect: CGRect, r: CGFloat, pct: CGFloat,
        tailHeight: CGFloat, tailWidth: CGFloat
    ) -> CGPath {
        let cardTop = tailHeight
        guard rect.height - cardTop > 2 * r else { return roundedRect(in: rect, radius: r) }
        let tc = clamp(center: rect.width * pct, length: rect.width, radius: r, tailWidth: tailWidth)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r, y: cardTop))
        p.addLine(to: CGPoint(x: tc - tailWidth / 2, y: cardTop))
        p.addLine(to: CGPoint(x: tc, y: 0))
        p.addLine(to: CGPoint(x: tc + tailWidth / 2, y: cardTop))
        p.addLine(to: CGPoint(x: rect.width - r, y: cardTop))
        p.addArc(center: CGPoint(x: rect.width - r, y: cardTop + r), radius: r,
                 startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        p.addLine(to: CGPoint(x: rect.width, y: rect.height - r))
        p.addArc(center: CGPoint(x: rect.width - r, y: rect.height - r), radius: r,
                 startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: r, y: rect.height))
        p.addArc(center: CGPoint(x: r, y: rect.height - r), radius: r,
                 startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.addLine(to: CGPoint(x: 0, y: cardTop + r))
        p.addArc(center: CGPoint(x: r, y: cardTop + r), radius: r,
                 startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        p.closeSubpath()
        return p
    }

    private static func leftPath(
        in rect: CGRect, r: CGFloat, pct: CGFloat,
        tailHeight: CGFloat, tailWidth: CGFloat
    ) -> CGPath {
        let cardLeft = tailHeight
        guard rect.width - cardLeft > 2 * r else { return roundedRect(in: rect, radius: r) }
        let tc = clamp(center: rect.height * pct, length: rect.height, radius: r, tailWidth: tailWidth)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cardLeft + r, y: 0))
        p.addLine(to: CGPoint(x: rect.width - r, y: 0))
        p.addArc(center: CGPoint(x: rect.width - r, y: r), radius: r,
                 startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        p.addLine(to: CGPoint(x: rect.width, y: rect.height - r))
        p.addArc(center: CGPoint(x: rect.width - r, y: rect.height - r), radius: r,
                 startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: cardLeft + r, y: rect.height))
        p.addArc(center: CGPoint(x: cardLeft + r, y: rect.height - r), radius: r,
                 startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.addLine(to: CGPoint(x: cardLeft, y: tc + tailWidth / 2))
        p.addLine(to: CGPoint(x: 0, y: tc))
        p.addLine(to: CGPoint(x: cardLeft, y: tc - tailWidth / 2))
        p.addLine(to: CGPoint(x: cardLeft, y: r))
        p.addArc(center: CGPoint(x: cardLeft + r, y: r), radius: r,
                 startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        p.closeSubpath()
        return p
    }

    private static func rightPath(
        in rect: CGRect, r: CGFloat, pct: CGFloat,
        tailHeight: CGFloat, tailWidth: CGFloat
    ) -> CGPath {
        let cardRight = rect.width - tailHeight
        guard cardRight > 2 * r else { return roundedRect(in: rect, radius: r) }
        let tc = clamp(center: rect.height * pct, length: rect.height, radius: r, tailWidth: tailWidth)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: cardRight - r, y: 0))
        p.addArc(center: CGPoint(x: cardRight - r, y: r), radius: r,
                 startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        p.addLine(to: CGPoint(x: cardRight, y: tc - tailWidth / 2))
        p.addLine(to: CGPoint(x: rect.width, y: tc))
        p.addLine(to: CGPoint(x: cardRight, y: tc + tailWidth / 2))
        p.addLine(to: CGPoint(x: cardRight, y: rect.height - r))
        p.addArc(center: CGPoint(x: cardRight - r, y: rect.height - r), radius: r,
                 startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: r, y: rect.height))
        p.addArc(center: CGPoint(x: r, y: rect.height - r), radius: r,
                 startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addArc(center: CGPoint(x: r, y: r), radius: r,
                 startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: false)
        p.closeSubpath()
        return p
    }
}
