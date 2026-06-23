import AppKit

/// Visual design tokens for the chat speech bubble.
///
/// White card, deep-indigo text on a tight high-contrast shadow, accent
/// orange for primary actions. Replaces the previous
/// translucent-teal-with-white-text styling that felt like a system HUD
/// rather than a deliberate speech bubble.
@MainActor
enum ChatBubbleTheme {

    // MARK: - Palette

    /// Deep indigo (#23113C). Used for transcript body, status, and as the
    /// alpha source for hairline borders + shadows. Earlier drafts used
    /// `#231160` here — the wrong blue channel — which read as too-saturated
    /// purple; #23113C (B=0x3C=60) matches the warm-paper look.
    static let textPrimary = NSColor(srgbRed: 35.0/255, green: 17.0/255, blue: 60.0/255, alpha: 1.0)

    /// Same hue at 55% opacity — secondary copy.
    static let textMuted = ChatBubbleTheme.textPrimary.withAlphaComponent(0.55)

    /// Same hue at 30% opacity — hint / placeholder copy.
    static let textHint = ChatBubbleTheme.textPrimary.withAlphaComponent(0.30)

    /// Accent orange (#f95d02). Reserved for the primary call-to-action
    /// (send button); avoid using it for body text or large surfaces.
    static let accent = NSColor(srgbRed: 249.0/255, green: 93.0/255, blue: 2.0/255, alpha: 1.0)

    /// Card background. **Pure white**. Earlier drafts used #fffdf7 warm-paper;
    /// that warm tone belongs to the secondary surface inside the card (e.g. code
    /// blocks), not the card itself. Pure white reads as a deliberate speech bubble.
    static let cardBackground = NSColor.white

    /// Accent button drop shadow — #C94A01.
    /// Used as a static 4pt y-offset zero-radius "press depth" under the
    /// send button. This signature primary-button trick is the single biggest
    /// reason the bubble feels tactile rather than flat.
    static let accentShadow = NSColor(srgbRed: 201.0/255, green: 74.0/255, blue: 1.0/255, alpha: 1.0)

    /// Hairline border around the card — 0.06 alpha. The bubble is
    /// **borderless** by default; retained as a token so callers that want a
    /// hairline can opt-in.
    static let hairline = ChatBubbleTheme.textPrimary.withAlphaComponent(0.06)

    /// Input field fill — barely visible tint that just separates the
    /// field from the card so users see where to type.
    static let inputFill = ChatBubbleTheme.textPrimary.withAlphaComponent(0.04)

    // MARK: - Proactive suggestion accent (主动建议暖染色)

    /// 主动建议气泡背景：显式暖奶白（偏黄不偏红，避开「粉」），区分于用户问的中性白气泡。
    /// 不用 `blended(of: accent)`（accent 是红橙，低比例混白会偏粉，且 blend 色彩空间不可控），
    /// 改用精确 srgb 暖奶白 —— 仍近白以维持 `textPrimary` 深靛文字可读性。具体浓淡可调。
    static let proactiveCardBackground = NSColor(srgbRed: 255.0/255, green: 249.0/255, blue: 238.0/255, alpha: 1.0)

    /// 主动建议气泡描边：accent 橙 0.4 alpha 细描边，勾勒气泡 path（含 tail），
    /// 让暖卡边缘有一道隐约的橙色轮廓，强化「主动」语义。
    static let proactiveBorder: NSColor = ChatBubbleTheme.accent.withAlphaComponent(0.4)

    // MARK: - Shape

    /// Card corner radius.
    static let cornerRadius: CGFloat = 14
    /// Smaller corner radius — input fill + nested buttons.
    static let cornerRadiusSmall: CGFloat = 10
    /// Speech-bubble tail height.
    static let tailHeight: CGFloat = 8
    /// Speech-bubble tail width.
    static let tailWidth: CGFloat = 14

    // MARK: - Shadow (drawn via CALayer.shadowPath, not NSWindow.hasShadow)

    /// Shadow tint — same hue as text, 22% alpha. Crisp + opinionated, not
    /// the soft macOS-system shadow.
    static let shadowColor = NSColor(srgbRed: 35.0/255, green: 17.0/255, blue: 60.0/255, alpha: 0.22)
    /// `+2` y — `.shadow(... x: 0, y: 2)` is downward in screen space. The
    /// earlier `-2` was a mis-translation of the SwiftUI sign; CALayer.shadowOffset
    /// is unaffected by `isFlipped` (isFlipped only changes subview layout, not
    /// layer compositing).
    static let shadowOffset = CGSize(width: 0, height: 2)
    static let shadowRadius: CGFloat = 3

    /// Empty space around the bubble inside the host window, reserved so
    /// `CALayer.shadowPath` has somewhere to render without being clipped
    /// at the contentView edge. The NSWindow is sized as bubble + 2 × this
    /// on each axis.
    static let shadowMargin: CGFloat = 20

    // MARK: - Spacing rhythm (tight HUD-like vertical rhythm)

    static let cardPadding: CGFloat = 16
    /// 5-8pt between siblings reads tight. 12pt was inherited from an earlier
    /// draft and made the bubble feel loose; 8pt locks the row rhythm.
    static let stackGap: CGFloat = 8

    // MARK: - Typography

    /// Transcript body. SF Rounded gives the bubble a friendlier "spoken"
    /// feel than the default SF Pro Text.
    static let bodyFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 13, weight: .regular)
        guard let desc = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: desc, size: 13) ?? base
    }()

    /// Status / footer text. One step smaller, muted.
    static let captionFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 10, weight: .medium)
        guard let desc = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: desc, size: 10) ?? base
    }()

    /// Input field text and send-button label.
    static let inputFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 13, weight: .regular)
        guard let desc = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: desc, size: 13) ?? base
    }()

    static let buttonFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
        guard let desc = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: desc, size: 12) ?? base
    }()
}
