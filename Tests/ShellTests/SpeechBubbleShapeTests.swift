import CoreGraphics
import Testing
@testable import Shell

@Suite("SpeechBubbleShape — CGPath bubble with optional tail")
struct SpeechBubbleShapeTests {

    @Test("Zero-sized rect returns an empty path rather than crashing")
    func zeroRectReturnsEmpty() {
        let path = SpeechBubbleShape.path(in: .zero)
        #expect(path.isEmpty)
    }

    @Test("Bottom tail extends below the card so path height equals rect height")
    func bottomTailExtendsBelowCard() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 120)
        let path = SpeechBubbleShape.path(in: rect, tailSide: .bottom, tailHeight: 12)
        let box = path.boundingBox
        // Bounding box should match the rect within sub-pixel tolerance.
        #expect(abs(box.maxY - rect.maxY) < 0.5)
        #expect(abs(box.minY - rect.minY) < 0.5)
    }

    @Test("`.none` tail degrades to a plain rounded rect inside the rect")
    func tailNoneFitsRect() {
        let rect = CGRect(x: 0, y: 0, width: 160, height: 80)
        let path = SpeechBubbleShape.path(in: rect, tailSide: .none)
        let box = path.boundingBox
        #expect(box.width <= rect.width + 0.5)
        #expect(box.height <= rect.height + 0.5)
        #expect(!path.isEmpty)
    }

    @Test("`tailPercent` outside [0,1] does not push the tail past the safe band",
          arguments: [-2.0, -0.5, 1.5, 9.0])
    func tailPercentClamped(percent: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 120)
        let path = SpeechBubbleShape.path(in: rect, tailSide: .bottom, tailPercent: percent, tailHeight: 12, tailWidth: 14)
        let box = path.boundingBox
        // After clamping, the path's x-extent should not exceed the rect.
        #expect(box.minX >= rect.minX - 0.5)
        #expect(box.maxX <= rect.maxX + 0.5)
        #expect(!path.isEmpty)
    }

    @Test("Tiny rects with a tail bigger than the card degrade to a rounded rect")
    func tinyRectFallsBackToRoundedRect() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 8)
        let path = SpeechBubbleShape.path(in: rect, tailSide: .bottom, tailHeight: 12)
        // tailHeight (12) >= rect.height (8) → cardBottom <= 0 → fallback.
        let box = path.boundingBox
        #expect(box.height <= rect.height + 0.5)
        #expect(!path.isEmpty)
    }

    @Test("Each tail side stays within the rect bounding box",
          arguments: [SpeechBubbleTailSide.top, .bottom, .left, .right])
    func eachSideStaysInsideBounds(side: SpeechBubbleTailSide) {
        let rect = CGRect(x: 0, y: 0, width: 240, height: 160)
        let path = SpeechBubbleShape.path(in: rect, tailSide: side)
        let box = path.boundingBox
        #expect(box.minX >= rect.minX - 0.5)
        #expect(box.maxX <= rect.maxX + 0.5)
        #expect(box.minY >= rect.minY - 0.5)
        #expect(box.maxY <= rect.maxY + 0.5)
    }

    @Test("Degenerate corner radius (huge) is clamped to half the shorter side")
    func cornerRadiusClampedForSmallRect() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 30)
        let path = SpeechBubbleShape.path(in: rect, cornerRadius: 9999, tailSide: .none)
        #expect(!path.isEmpty)
        let box = path.boundingBox
        #expect(box.height <= rect.height + 0.5)
    }
}
