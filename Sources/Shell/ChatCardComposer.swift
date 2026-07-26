import SwiftUI

/// 对话卡片底部 pill 输入条：多行自适应 TextField + 圆形 accent 发送钮。
/// 借鉴 AccountyCat (https://github.com/strjonas/AccountyCat) 的 ComposerView：focus 时 accent 描边、圆形发送钮带招牌
/// `accentShadow` 静态压深（4pt y、0 radius）给按钮触感。
///
/// P6.1 目标选择闭环:**图标 = 一次性目标选择器,pin 徽标 = 唯一粘性开关,发送即回弹**。
/// - 点目标图标(或打字 @)→ 纯图标胶囊(pet + 三引擎,未装置灰)弹出,选中收起;
///   选中 = 一次性目标(`selectedMentionTrigger`),draft 自动剥除已键入的 `@` 片段。
/// - 目标是引擎时图标右上角出 pin 徽标(空心未钉/实心已钉),点徽标切钉住态;
///   取消钉住只走徽标(一次性与粘性各有唯一入口)。
/// - 发送时选中目标经 `MentionAutocomplete.withMentionPrefix` 烘焙进文本(controller 做),
///   发送即清空选中态 → 图标回弹 paw/pinned。
struct ChatCardComposer: View {
    @Binding var draft: String
    let isSending: Bool
    /// @mention 补全候选(App 注入;空 → 不弹)。恒含 soul 行 + 三引擎。
    var mentionOptions: [MentionOption] = []
    /// P6:当前钉住的引擎 trigger(nil = 未钉,默认灵魂层)。
    var pinnedMentionTrigger: String? = nil
    /// P6.1:胶囊选中的一次性目标 trigger(含 paw;nil = 无,发送即清空)。
    var selectedMentionTrigger: String? = nil
    /// P6.1:选中/再点取消回调(trigger;paw 也回传,用于一次性灵魂逃逸)。
    var onSelectMention: ((String?) -> Void)? = nil
    /// P6:钉住回调(pin 徽标 → 钉住该引擎)。
    var onPinMention: ((String) -> Void)? = nil
    /// P6:取消钉住回调(pin 徽标 → 回灵魂层)。
    var onUnpinMention: (() -> Void)? = nil
    let onSend: () -> Void

    @FocusState private var focused: Bool
    /// 胶囊高亮位(方向键移动;过滤结果变化时重置)。
    @State private var selectedMentionIndex: Int = 0
    /// 打字 @ 被 Esc 手动关闭后,本段 mention 输入内不再自动弹出(重新进入 mention 输入时恢复)。
    @State private var mentionDismissed: Bool = false
    /// 图标点击展开的全量胶囊(与打字 @ 触发的过滤胶囊同一份 UI)。
    @State private var capsuleOpen: Bool = false

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    /// 打字 @ 触发的过滤候选(不处于行首 mention 输入 → 空)。
    private var mentionMatches: [MentionOption] {
        guard let query = MentionAutocomplete.query(in: draft) else { return [] }
        return MentionAutocomplete.filter(mentionOptions, query: query)
    }

    /// 胶囊当前展示的候选:打字过滤态用过滤结果;图标点击展开用全量。
    private var capsuleOptions: [MentionOption] {
        if !mentionMatches.isEmpty && !mentionDismissed { return mentionMatches }
        return capsuleOpen ? mentionOptions : []
    }

    private var capsuleVisible: Bool {
        !capsuleOptions.isEmpty
    }

    /// 有效目标(图标状态机):打字完整 @ > 胶囊选中 > pinned > soul。
    private var composerTarget: ComposerTarget {
        ComposerTargetResolver.resolve(
            draft: draft,
            options: mentionOptions,
            pinnedTrigger: pinnedMentionTrigger,
            selectedTrigger: selectedMentionTrigger
        )
    }

    private let placeholder = "问点什么，@ 可点名引擎…"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if capsuleVisible { mentionCapsule }
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
            targetIcon
                .padding(.leading, 6)
                .padding(.bottom, 3)

            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(ChatCardTheme.body)
                .foregroundStyle(ChatCardTheme.textPrimary)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.leftArrow) { moveMentionSelection(-1) }
                .onKeyPress(.rightArrow) { moveMentionSelection(1) }
                .onKeyPress(.upArrow) { moveMentionSelection(-1) }
                .onKeyPress(.downArrow) { moveMentionSelection(1) }
                .onKeyPress(.escape) { dismissMentionCapsule() }
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
        // 胶囊可见时 Enter = 接受高亮候选(而非发送);胶囊关闭才走正常发送。
        if capsuleVisible, capsuleOptions.indices.contains(selectedMentionIndex) {
            acceptMention(capsuleOptions[selectedMentionIndex])
            return
        }
        guard canSend else { return }
        onSend()
    }

    // MARK: - P6.1 目标图标 + pin 徽标

    /// pill 前置目标图标:soul 爪印 / pinned 引擎(实色)/ 一次性目标(降透明)。
    /// 图标本体点击 = 展开/收起胶囊(全量候选);引擎目标右上角 pin 徽标 = 钉住切换。
    private var targetIcon: some View {
        let target = composerTarget
        return ZStack(alignment: .topTrailing) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { capsuleOpen.toggle() }
                focused = true
            } label: {
                targetIconContent(target)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(
                            target.isPinnedEngine
                                ? ChatCardTheme.accent.opacity(0.14)
                                : ChatCardTheme.inputFill
                        )
                    )
            }
            .buttonStyle(.plain)
            .help(target.helpText)

            // pin 徽标:引擎目标才显示;空心 = 未钉(点击钉住),实心 = 已钉(点击取消)。
            if case .engine(let option, let pinned) = target {
                Button {
                    if pinned {
                        onUnpinMention?()
                    } else {
                        onPinMention?(option.trigger)
                    }
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(ChatCardTheme.accent)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(ChatCardTheme.inputFill))
                        .overlay(Circle().stroke(ChatCardTheme.accent.opacity(0.4), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(pinned ? "取消钉住,回到 Pet 聊天" : "钉住 @\(option.trigger),之后不用每条 @")
                .offset(x: 3, y: -3)
            }
        }
    }

    @ViewBuilder
    private func targetIconContent(_ target: ComposerTarget) -> some View {
        switch target {
        case .soul:
            Image(systemName: "pawprint.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChatCardTheme.accent)
        case .engine(let option, let pinned):
            Group {
                if let logo = option.brandLogo {
                    BrandLogoShape(logo: logo)
                        .fill(logo.defaultColor, style: logo.fillRule)
                        .frame(width: 14, height: 14)
                        .clipped()
                } else {
                    Image(systemName: option.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ChatCardTheme.accent)
                }
            }
            .opacity(pinned ? 1 : 0.55)   // 一次性目标降透明,与 pinned 区分
        }
    }

    // MARK: - P6.1 纯图标胶囊

    /// 目标选择胶囊:pet + 三引擎纯图标横排,未装置灰;打字 @ 过滤 / 点图标全量同一份 UI。
    private var mentionCapsule: some View {
        HStack(spacing: 4) {
            ForEach(Array(capsuleOptions.enumerated()), id: \.element.id) { index, option in
                Button {
                    acceptMention(option)
                } label: {
                    capsuleIcon(option)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(
                                index == selectedMentionIndex
                                    ? ChatCardTheme.accent.opacity(0.18)
                                    : (selectedMentionTrigger == option.trigger
                                        ? ChatCardTheme.accent.opacity(0.10)
                                        : .clear)
                            )
                        )
                }
                .buttonStyle(.plain)
                .opacity(option.available ? 1 : 0.45)
                .help(option.isSoul
                      ? "Pet 灵魂层"
                      : "\(option.label)(@\(option.trigger))\(option.available ? "" : " · 未安装")")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ChatCardTheme.inputFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(ChatCardTheme.hairline, lineWidth: 1)
                )
        )
    }

    /// 品牌 logo 优先(与目标图标同款渲染),否则 SF Symbol(paw 走这里)。
    @ViewBuilder
    private func capsuleIcon(_ option: MentionOption) -> some View {
        if let logo = option.brandLogo {
            BrandLogoShape(logo: logo)
                .fill(logo.defaultColor, style: logo.fillRule)
                .frame(width: 15, height: 15)
                .clipped()
        } else {
            Image(systemName: option.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChatCardTheme.accent)
        }
    }

    // MARK: - 弹层交互

    private func moveMentionSelection(_ delta: Int) -> KeyPress.Result {
        guard capsuleVisible else { return .ignored }
        let count = capsuleOptions.count
        selectedMentionIndex = (selectedMentionIndex + delta + count) % count
        return .handled
    }

    private func dismissMentionCapsule() -> KeyPress.Result {
        if capsuleOpen {
            capsuleOpen = false
            return .handled
        }
        guard !mentionMatches.isEmpty, !mentionDismissed else { return .ignored }
        mentionDismissed = true
        return .handled
    }

    /// 选中候选:一次性目标入 state(paw 也回传,一次性灵魂逃逸);draft 剥除已键入
    /// 的 `@` 片段;再点同一候选 = 取消选中(回弹 nil)。选中后收起胶囊。
    private func acceptMention(_ option: MentionOption) {
        if selectedMentionTrigger == option.trigger {
            onSelectMention?(nil)
        } else {
            onSelectMention?(option.trigger)
        }
        draft = MentionAutocomplete.strippingDraftMention(draft)
        selectedMentionIndex = 0
        mentionDismissed = false
        capsuleOpen = false
        focused = true
    }
}
