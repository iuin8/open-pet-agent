import SwiftUI

/// 对话卡片底部 pill 输入条：多行自适应 TextField + 圆形 accent 发送钮。
/// 借鉴 AccountyCat (https://github.com/strjonas/AccountyCat) 的 ComposerView：focus 时 accent 描边、圆形发送钮带招牌
/// `accentShadow` 静态压深（4pt y、0 radius）给按钮触感。
///
/// P5 follow-up @mention 补全弹层:draft 处于行首 `@前缀` 输入中时,pill 上方弹出引擎
/// 候选(品牌 logo + 展示名 + CLI 可用性);↑/↓ 移动、Enter 接受、Esc 关、点选亦可。
/// 判定走 `MentionAutocomplete`(与 `AgentMention.parse` 行首语义对齐);工具层关闭
/// (mentionEnabled=false)完全不弹、占位文案也不带 @ 提示。
struct ChatCardComposer: View {
    @Binding var draft: String
    let isSending: Bool
    /// @mention 补全候选(App 注入;空 → 不弹)。
    var mentionOptions: [MentionOption] = []
    /// @mention 是否启用(= 工具层开启)。
    var mentionEnabled: Bool = false
    let onSend: () -> Void

    @FocusState private var focused: Bool
    /// 补全弹层高亮行(过滤结果变化时重置)。
    @State private var selectedMentionIndex: Int = 0
    /// Esc 手动关闭后,本段 mention 输入内不再自动弹出(重新进入 mention 输入时恢复)。
    @State private var mentionDismissed: Bool = false

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    /// 当前过滤出的补全候选(不处于行首 mention 输入 → 空)。
    private var mentionMatches: [MentionOption] {
        guard mentionEnabled, let query = MentionAutocomplete.query(in: draft) else { return [] }
        return MentionAutocomplete.filter(mentionOptions, query: query)
    }

    private var mentionPopupVisible: Bool {
        !mentionMatches.isEmpty && !mentionDismissed
    }

    private var placeholder: String {
        mentionEnabled ? "问点什么，@ 可点名引擎…" : "问点什么，或聊聊你在忙啥…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if mentionPopupVisible { mentionPopup }
            inputPill
        }
        // 过滤结果变化 → 高亮归零;进入新一段 mention 输入 → dismiss 复位
        .onChange(of: mentionMatches.map(\.trigger)) { _, _ in
            selectedMentionIndex = 0
            if !mentionMatches.isEmpty { mentionDismissed = false }
        }
    }

    // MARK: - 输入 pill

    private var inputPill: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(ChatCardTheme.body)
                .foregroundStyle(ChatCardTheme.textPrimary)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.upArrow) { moveMentionSelection(-1) }
                .onKeyPress(.downArrow) { moveMentionSelection(1) }
                .onKeyPress(.escape) { dismissMentionPopup() }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            sendButton
                .padding(.trailing, 4)
                .padding(.bottom, 3)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ChatCardTheme.inputFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(focused ? ChatCardTheme.accent.opacity(0.5) : ChatCardTheme.hairline, lineWidth: 1)
                )
        )
        .animation(.easeOut(duration: 0.15), value: focused)
        .onAppear { focused = true }
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: isSending ? "ellipsis" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(canSend ? Color.white : ChatCardTheme.textPrimary.opacity(0.4))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(canSend ? ChatCardTheme.accent : ChatCardTheme.inputFill)
                        // 招牌做法：静态 4pt y 压深（0 radius）→ 按钮有触感（非软系统阴影）。
                        .shadow(color: canSend ? ChatCardTheme.accentShadow : .clear, radius: 0, y: 2)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    private func submit() {
        // 补全弹层可见时 Enter = 接受候选(而非发送);弹层关闭才走正常发送。
        if mentionPopupVisible, mentionMatches.indices.contains(selectedMentionIndex) {
            acceptMention(mentionMatches[selectedMentionIndex])
            return
        }
        guard canSend else { return }
        onSend()
    }

    // MARK: - 补全弹层

    private var mentionPopup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(mentionMatches.enumerated()), id: \.element.id) { index, option in
                Button {
                    acceptMention(option)
                } label: {
                    HStack(spacing: 8) {
                        mentionIcon(option)
                        Text(option.label)
                            .font(ChatCardTheme.body)
                            .foregroundStyle(ChatCardTheme.textPrimary)
                        Text("@\(option.trigger)")
                            .font(ChatCardTheme.timestamp)
                            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.4))
                        Spacer()
                        if !option.available {
                            Text("未安装")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(index == selectedMentionIndex ? ChatCardTheme.accent.opacity(0.14) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .opacity(option.available ? 1 : 0.55)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ChatCardTheme.inputFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(ChatCardTheme.hairline, lineWidth: 1)
                )
        )
    }

    /// 品牌 logo 优先(与 `ReplySourceBar` 同款渲染),否则 SF Symbol。
    @ViewBuilder
    private func mentionIcon(_ option: MentionOption) -> some View {
        if let logo = option.brandLogo {
            BrandLogoShape(logo: logo)
                .fill(logo.defaultColor, style: logo.fillRule)
                .frame(width: 13, height: 13)
                .clipped()
        } else {
            Image(systemName: option.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ChatCardTheme.accent)
        }
    }

    // MARK: - 弹层交互

    private func moveMentionSelection(_ delta: Int) -> KeyPress.Result {
        guard mentionPopupVisible else { return .ignored }
        let count = mentionMatches.count
        selectedMentionIndex = (selectedMentionIndex + delta + count) % count
        return .handled
    }

    private func dismissMentionPopup() -> KeyPress.Result {
        guard mentionPopupVisible else { return .ignored }
        mentionDismissed = true
        return .handled
    }

    private func acceptMention(_ option: MentionOption) {
        draft = MentionAutocomplete.acceptedDraft(trigger: option.trigger)
        selectedMentionIndex = 0
        mentionDismissed = false
        focused = true
    }
}
