import SwiftUI

/// 对话卡片的 SwiftUI 视觉 token：把 `ChatBubbleTheme`（AppKit NSColor/几何）桥成 SwiftUI
/// `Color`/`Font`，并补卡片专属组合（user/pet 气泡填充 + uneven 尖角）。
///
/// 设计：**采纳 AccountyCat (https://github.com/strjonas/AccountyCat) 的结构**（uneven 尖角气泡、pill composer、玻璃 +
/// accent 分层、header chip），**用 OpenPetAgent 自己的主题色**（暖奶油 + accent #f95d02 +
/// SF Rounded + 深靛字），不照搬 AccountyCat 的灰/暗色板。
///
/// 字体直接用 SF Rounded SwiftUI Font（与 `ChatBubbleTheme` 的 `.rounded` design 一致），
/// 免去 NSFont→CTFont 桥接。
@MainActor
enum ChatCardTheme {
    // MARK: - 颜色（桥 ChatBubbleTheme）

    static var accent: Color { Color(nsColor: ChatBubbleTheme.accent) }
    static var accentShadow: Color { Color(nsColor: ChatBubbleTheme.accentShadow) }
    static var textPrimary: Color { Color(nsColor: ChatBubbleTheme.textPrimary) }
    static var cardBackground: Color { Color(nsColor: ChatBubbleTheme.cardBackground) }
    static var hairline: Color { Color(nsColor: ChatBubbleTheme.hairline) }
    static var inputFill: Color { Color(nsColor: ChatBubbleTheme.inputFill) }

    /// user 气泡：accent 实色填充 + 白字（accent 是饱和橙，实色保证白字对比）。
    static var userBubbleFill: Color { accent }
    static let userBubbleText = Color.white
    /// pet 气泡：暖奶油填充（区分于 user 的橙）+ 深靛字。
    static var petBubbleFill: Color { Color(nsColor: ChatBubbleTheme.proactiveCardBackground) }
    static var petBubbleText: Color { textPrimary }
    /// pet 气泡细描边（暖卡边缘隐约橙轮廓）。
    static var petBubbleStroke: Color { accent.opacity(0.14) }
    /// 选中/查看中的源行呼吸光圈色 —— **冷青绿 teal #00B3A4**，与 user 气泡的 accent 橙明显区分（不撞色）。
    static let selectionHalo = Color(red: 0.0, green: 0.702, blue: 0.643)
    /// 「活跃中」标识绿 —— 会话行活跃点 + 复制成功勾共用（会话 30s 内被写 / 复制完成）。
    static let activeGreen = Color(red: 0.30, green: 0.72, blue: 0.42)
    /// 鼠标悬停光圈色 —— **深靛**（= textPrimary）。橙底 user 行用 accent 橙画 hover 会与底色融合看不见
    /// （对比 1.0）；改走「亮度对比」而非「色相对比」：深靛对橙底 5.42、对白/奶白底 16+，三类行底都清晰，
    /// 又与 accent 橙、teal selection 都不撞（深靛 vs teal 对比 6.56，层级分明）。0.32 alpha 保「轻提示」不喧宾。
    static var hoverHalo: Color { textPrimary }

    // MARK: - 字体（SF Rounded，对齐 ChatBubbleTheme）

    static let body = Font.system(size: 13, design: .rounded)
    static let chip = Font.system(size: 10, weight: .semibold, design: .rounded)
    static let timestamp = Font.system(size: 9.5, weight: .regular, design: .monospaced)

    // MARK: - 几何

    static let cardRadius: CGFloat = ChatBubbleTheme.cornerRadius        // 14
    static let bubbleRadius: CGFloat = ChatBubbleTheme.cornerRadiusSmall // 10
    /// uneven 尖角的「尖」半径（贴向 pet 的那个上角收小 → 对话尖角）。
    static let tailCornerRadius: CGFloat = 4
    static let maxBubbleWidth: CGFloat = 248
    /// 外部会话流(`AgentSessionTabView`)里 user/assistant 消息行**全宽**(与工具行齐,P3.8 G1):
    /// 卡宽 360 − transcript 横向 padding 12×2 − 气泡横向 padding 11×2 = 314。markdown 换行宽据此。
    static let messageTextWidth: CGFloat = 314

    // MARK: - 卡片尺寸（固定，内部 ScrollView 容纳多轮 → 绕开 NSHostingView 动态高坑，见 §3.2）

    static let cardWidth: CGFloat = 360
    static let cardHeight: CGFloat = 480
    /// 指向 pet 的尖角高度（在固定窗口内占 tail 那一侧的一条窄带，content 让出同等内边距）。
    static let tailHeight: CGFloat = 9
}
