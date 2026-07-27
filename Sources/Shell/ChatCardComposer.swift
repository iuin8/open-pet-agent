import SwiftUI

/// 对话卡片底部 pill 输入条：多行自适应 TextField + 圆形 accent 发送钮。
/// 借鉴 AccountyCat (https://github.com/strjonas/AccountyCat) 的 ComposerView：focus 时 accent 描边、圆形发送钮带招牌
/// `accentShadow` 静态压深（4pt y、0 radius）给按钮触感。
///
/// P6.2 mention token 化:**mention 活在消息里,composer 无常驻 chrome**。
/// - 打字 @ → 行式 picker(图标 + 名字 + trigger + 未安装置灰);选中/敲全 trigger →
///   落成 **tray 标签**(pill 上方标签条),draft 自动剥除已键入的 `@` 片段。
/// - tray 标签 = 行首路由目标:深色 = 钉住(常驻)、浅色 = 一次性(发送后清空);
///   点击 pin 图标切换钉/取消;× 移除(钉住态先取消钉住)。
/// - 发送时选中目标经 `MentionAutocomplete.withMentionPrefix` 烘焙进文本(controller 做),
///   路由/署名/落盘管线零改动。
/// - 真 inline chip(文本流内嵌)需 NSTextView 编辑器 + 中文 IME 专项,留作将来里程碑。
struct ChatCardComposer: View {
    @Binding var draft: String
    let isSending: Bool
    /// @mention 补全候选(App 注入;空 → 不弹)。恒含 soul 行 + 三引擎。
    var mentionOptions: [MentionOption] = []
    /// P6:当前钉住的引擎 trigger(nil = 未钉,默认灵魂层)。
    var pinnedMentionTrigger: String? = nil
    /// P6.2:落 token 的一次性目标 trigger(含 paw;nil = 无,发送即清空)。
    var selectedMentionTrigger: String? = nil
    /// P6.2:落 token / 移除回调(trigger;nil = 移除一次性 token)。
    var onSelectMention: ((String?) -> Void)? = nil
    /// P6:钉住回调(tray 浅色标签点 pin → 钉住该引擎)。
    var onPinMention: ((String) -> Void)? = nil
    /// P6:取消钉住回调(tray 深色标签点 pin / × → 取消)。
    var onUnpinMention: (() -> Void)? = nil
    let onSend: () -> Void

    @FocusState private var focused: Bool
    /// picker 高亮行(过滤结果变化时重置)。
    @State private var selectedMentionIndex: Int = 0
    /// 打字 @ 被 Esc 手动关闭后,本段 mention 输入内不再自动弹出(重新进入 mention 输入时恢复)。
    @State private var mentionDismissed: Bool = false

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    /// 打字 @ 触发的过滤候选(不处于行首 mention 输入 → 空)。
    private var mentionMatches: [MentionOption] {
        guard let query = MentionAutocomplete.query(in: draft) else { return [] }
        return MentionAutocomplete.filter(mentionOptions, query: query)
    }

    private var pickerVisible: Bool {
        !mentionMatches.isEmpty && !mentionDismissed
    }

    /// tray 有效 token:选中 trigger ?? pinnedTrigger(都没有 → nil 无 chrome)。
    private var trayToken: MentionTrayToken? {
        MentionAutocomplete.trayToken(
            selectedTrigger: selectedMentionTrigger,
            pinnedTrigger: pinnedMentionTrigger,
            options: mentionOptions
        )
    }

    private let placeholder = "问点什么，@ 可点名引擎…"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let token = trayToken { trayChip(token) }
            if pickerVisible { mentionPicker }
            inputPill
        }
        // 过滤结果变化 → 高亮归零;进入新一段 mention 输入 → dismiss 复位
        .onChange(of: mentionMatches.map(\.trigger)) { _, _ in
            selectedMentionIndex = 0
            if !mentionMatches.isEmpty { mentionDismissed = false }
        }
        // 敲全 trigger(词边界)→ 自动落 token 并剥除 draft 里的 @ 片段(打字党一等公民)。
        // 剥除后 draft 不再命中 resolvedTarget,onChange 不会自旋。
        .onChange(of: draft) { _, newDraft in
            guard let option = MentionAutocomplete.resolvedTarget(in: newDraft, options: mentionOptions),
                  option.trigger != selectedMentionTrigger else { return }
            onSelectMention?(option.trigger)
            draft = MentionAutocomplete.strippingDraftMention(newDraft)
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
                .onKeyPress(.escape) { dismissMentionPicker() }
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
        // picker 可见时 Enter = 接受高亮候选(而非发送);picker 关闭才走正常发送。
        if pickerVisible, mentionMatches.indices.contains(selectedMentionIndex) {
            acceptMention(mentionMatches[selectedMentionIndex])
            return
        }
        guard canSend else { return }
        onSend()
    }

    // MARK: - P6.2 tray 标签

    /// tray 标签:引擎 logo/爪印 + 名字 + pin 切换(非 soul)+ × 移除。
    /// 深色(钉住,白字)/ 浅色(一次性,accent 字)。
    private func trayChip(_ token: MentionTrayToken) -> some View {
        let pinned = token.isPinned
        return HStack(spacing: 5) {
            chipIcon(token.option, pinned: pinned)
            Text(token.option.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(chipForeground(pinned))
            if !token.option.isSoul {
                Button {
                    if pinned {
                        onUnpinMention?()
                    } else {
                        onPinMention?(token.option.trigger)
                    }
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(chipForeground(pinned).opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(pinned ? "取消钉住(转为一次性)" : "钉住 @\(token.option.trigger)(之后不用每条 @)")
            }
            Button {
                // × 移除:一次性 → 清选中;钉住态 → 取消钉住(token 随之消失)
                if pinned {
                    onUnpinMention?()
                } else {
                    onSelectMention?(nil)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(chipForeground(pinned).opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("移除")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(
                pinned ? ChatCardTheme.accent.opacity(0.85) : ChatCardTheme.accent.opacity(0.14)
            )
        )
    }

    private func chipForeground(_ pinned: Bool) -> Color {
        pinned ? Color.white : ChatCardTheme.accent
    }

    @ViewBuilder
    private func chipIcon(_ option: MentionOption, pinned: Bool) -> some View {
        if let logo = option.brandLogo {
            BrandLogoShape(logo: logo)
                .fill(pinned ? Color.white : logo.defaultColor, style: logo.fillRule)
                .frame(width: 11, height: 11)
                .clipped()
        } else {
            Image(systemName: option.systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(chipForeground(pinned))
        }
    }

    // MARK: - P6.2 行式 picker

    /// 打字 @ 弹出的候选列表:图标 + 名字 + trigger + 未安装置灰(将来可按类型分区)。
    private var mentionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(mentionMatches.enumerated()), id: \.element.id) { index, option in
                Button {
                    acceptMention(option)
                } label: {
                    HStack(spacing: 8) {
                        pickerIcon(option)
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

    /// 品牌 logo 优先,否则 SF Symbol(paw 走这里)。
    @ViewBuilder
    private func pickerIcon(_ option: MentionOption) -> some View {
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

    // MARK: - picker 交互

    private func moveMentionSelection(_ delta: Int) -> KeyPress.Result {
        guard pickerVisible else { return .ignored }
        let count = mentionMatches.count
        selectedMentionIndex = (selectedMentionIndex + delta + count) % count
        return .handled
    }

    private func dismissMentionPicker() -> KeyPress.Result {
        guard pickerVisible else { return .ignored }
        mentionDismissed = true
        return .handled
    }

    /// 选中候选:落 token(含 paw 一次性灵魂逃逸);draft 剥除已键入的 `@` 片段;收起 picker。
    private func acceptMention(_ option: MentionOption) {
        onSelectMention?(option.trigger)
        draft = MentionAutocomplete.strippingDraftMention(draft)
        selectedMentionIndex = 0
        mentionDismissed = false
        focused = true
    }
}
