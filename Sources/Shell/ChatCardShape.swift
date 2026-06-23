import SwiftUI

/// 把 `SpeechBubbleShape`（CGPath，Y-down 坐标）包成 SwiftUI `Shape`，给对话卡片画「指向 pet 的尖角」。
/// `SpeechBubbleShape` 的几何是 Y-down 坐标，与 SwiftUI 一致，可直接 `Path(cgPath)`。
struct ChatCardShape: Shape {
    var tailSide: SpeechBubbleTailSide
    var tailPercent: CGFloat
    var cornerRadius: CGFloat
    var tailHeight: CGFloat
    var tailWidth: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        Path(SpeechBubbleShape.path(
            in: rect,
            cornerRadius: cornerRadius,
            tailSide: tailSide,
            tailPercent: tailPercent,
            tailHeight: tailHeight,
            tailWidth: tailWidth
        ))
    }
}
