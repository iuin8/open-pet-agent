import SwiftUI

/// 对话卡片单条消息行。
/// - user：右对齐，accent 实色气泡 + 白字。
/// - pet：左对齐，暖奶油气泡 + 深靛字 + markdown 富文本（空文本 = 流式打点占位）。
///
/// 尖角用 `UnevenRoundedRectangle`：贴向对侧的那个上角收小（user 右上 / pet 左上）→ 一行实现
/// 对话尖角，无需 Path（借鉴 AccountyCat (https://github.com/strjonas/AccountyCat) 的 ChatScrollView）。
struct ChatCardMessageRow: View {
    let row: ChatCardRow

    private var isUser: Bool { row.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                bubble
                timeLabel
            }
            .frame(maxWidth: ChatCardTheme.maxBubbleWidth, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    // MARK: - 气泡

    @ViewBuilder
    private var bubble: some View {
        bubbleContent
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(bubbleShape.fill(isUser ? ChatCardTheme.userBubbleFill : ChatCardTheme.petBubbleFill))
            .overlay {
                if !isUser { bubbleShape.stroke(ChatCardTheme.petBubbleStroke, lineWidth: 0.5) }
            }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if isUser {
            Text(row.text)
                .font(ChatCardTheme.body)
                .foregroundStyle(ChatCardTheme.userBubbleText)
                .textSelection(.enabled)
        } else if row.text.isEmpty {
            TypingDots()
        } else {
            MarkdownTextView(
                content: row.text,
                tint: ChatCardTheme.accent,
                maxWidth: ChatCardTheme.maxBubbleWidth - 24,
                baseFont: ChatCardTheme.body
            )
            .foregroundStyle(ChatCardTheme.petBubbleText)
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let r = ChatCardTheme.bubbleRadius
        let tail = ChatCardTheme.tailCornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: isUser ? r : tail,
            bottomLeadingRadius: r,
            bottomTrailingRadius: r,
            topTrailingRadius: isUser ? tail : r,
            style: .continuous
        )
    }

    private var timeLabel: some View {
        Text(Self.timeFormatter.string(from: row.timestamp))
            .font(ChatCardTheme.timestamp)
            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.34))
            .padding(.horizontal, 4)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()
}

// MARK: - 流式打点占位

/// pet 气泡流式开始（answer 仍空）时的三颗脉冲点。
struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(ChatCardTheme.textPrimary.opacity(0.45))
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(idx) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
