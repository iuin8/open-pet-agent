import AppKit
import Orchestrator
import SwiftUI

/// 对话卡片单条消息行。
/// - user：右对齐，accent 实色气泡 + 白字。
/// - pet：左对齐，暖奶油气泡 + 深靛字 + markdown 富文本（空文本 = 流式打点占位）。
///
/// 尖角用 `UnevenRoundedRectangle`：贴向对侧的那个上角收小（user 右上 / pet 左上）→ 一行实现
/// 对话尖角，无需 Path（借鉴 AccountyCat (https://github.com/strjonas/AccountyCat) 的 ChatScrollView）。
struct ChatCardMessageRow: View {
    let row: ChatCardRow
    /// in-flight assistant row 思考中(text 空 + isThinking → 显示「思考中…」替代打点)。
    var isThinking: Bool = false
    /// P6.1:mention 候选(用户行 `@trigger` → 图标 chip 解析;空 → 退化为原文)。
    var mentionOptions: [MentionOption] = []

    private var isUser: Bool { row.role == .user }

    /// P6.1:用户行 mention 图标(trigger → 候选;查不到 → nil 退化为原文展示)。
    private var userMention: MentionOption? {
        guard let trigger = row.userMentionTrigger else { return nil }
        return mentionOptions.first { $0.trigger == trigger }
    }

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
            // P7.2:图片附件在正文上方缩略横排(无图零影响)。
            VStack(alignment: .trailing, spacing: 6) {
                if !row.images.isEmpty { imageStrip }
                // P7-polish:纯图片消息(空文本)不渲染空文本泡。
                if !row.text.isEmpty {
                    // P6.1:行首 @trigger 渲染为引擎 logo chip + 剥除前缀的正文(落盘原文不动)。
                    HStack(alignment: .center, spacing: 5) {
                        if let mention = userMention {
                            mentionChip(mention)
                        }
                        Text(userMention != nil
                             ? MentionAutocomplete.strippingLeadingMention(row.text, options: mentionOptions)
                             : row.text)
                            .font(ChatCardTheme.body)
                            .foregroundStyle(ChatCardTheme.userBubbleText)
                            .textSelection(.enabled)
                    }
                }
            }
        } else if row.text.isEmpty {
            if isThinking {
                Text("思考中…")
                    .font(ChatCardTheme.body)
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.5))
            } else {
                TypingDots()
            }
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

    /// P7.2:用户行图片附件横排(64pt 圆角,多图 HStack;解码失败 → 占位图标)。
    private var imageStrip: some View {
        HStack(spacing: 6) {
            ForEach(Array(row.images.enumerated()), id: \.offset) { _, image in
                Group {
                    if let nsImage = NSImage(data: image.data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(ChatCardTheme.userBubbleText.opacity(0.7))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.15))
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    /// P6.1:用户行 mention 图标 chip(引擎 logo / paw;白字在 accent 气泡上)。
    @ViewBuilder
    private func mentionChip(_ option: MentionOption) -> some View {
        Group {
            if let logo = option.brandLogo {
                BrandLogoShape(logo: logo)
                    .fill(logo.defaultColor, style: logo.fillRule)
                    .frame(width: 11, height: 11)
                    .clipped()
            } else {
                Image(systemName: option.systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ChatCardTheme.userBubbleText)
            }
        }
        .padding(3)
        .background(Circle().fill(Color.white.opacity(0.22)))
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
        HStack(spacing: 4) {
            // P5 @mention 署名:assistant 行带来源(engine 短标签)→ 小 chip;nil 不显示。
            if let source = row.source, !isUser {
                Text(source)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ChatCardTheme.accent.opacity(0.75))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(ChatCardTheme.accent.opacity(0.10)))
            }
            Text(Self.timeFormatter.string(from: row.timestamp))
                .font(ChatCardTheme.timestamp)
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.34))
        }
        .padding(.horizontal, 4)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()
}

// MARK: - 流式打点占位

// `TypingDots`(流式开始的三颗脉冲点)现为 CALayer 驱动(`BreathingLayerViews.swift`)——
// 旧 SwiftUI `.repeatForever` 会让整棵卡片树每帧重评(§6.4)。CA 动画在 render server 跑,不进 AttributeGraph。
