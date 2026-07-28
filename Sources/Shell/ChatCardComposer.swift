import AppKit
import Orchestrator
import SwiftUI

/// 对话卡片底部 pill 输入条:`ChatComposerEditor`(NSTextView 富文本)+ 圆形 accent 发送钮。
/// 借鉴 AccountyCat (https://github.com/strjonas/AccountyCat) 的 ComposerView:focus 时 accent 描边、圆形发送钮带招牌
/// `accentShadow` 静态压深(4pt y、0 radius)给按钮触感。
///
/// P7.1:composer 从 SwiftUI TextField 重写为 NSTextView 编辑器,mention 从 P6.2 tray 标签
/// 迁移为**文本流内嵌 chip**(U+FFFC attachment,单字符原子删除):
/// - 行首 chip = 路由目标(深色 = 钉住常驻、浅色 = 一次性);发送清空后钉住 chip 自动回补
///   (`ChatCardState.syncPinnedChip`),语义与 P6.2 tray 逐项对齐;
/// - 打字 @ → 行式 picker(图标 + 名字 + trigger + 未安装置灰);选中/敲全 trigger →
///   chip 替换已键入的 `@query` 段;paw(soul)= 一次性逃逸;
/// - chip 点击 → 菜单(行首引擎 chip [钉住/取消钉住, 移除];其余 [移除]);
/// - 发送时 `state.draft` 已是 parts 序列化出的 wire format,路由/署名/落盘管线零改动。
struct ChatCardComposer: View {
    /// composer 内容(`ChatCardState.composerParts`;draft 是其序列化投影)。
    @Binding var parts: [ComposerPart]
    /// P7.2:待发送图片附件(粘贴/拖拽入;附件条展示 + hover × 移除)。
    @Binding var images: [ChatImage]
    let isSending: Bool
    /// @mention 补全候选(App 注入;空 → 不弹)。恒含 soul 行 + 三引擎。
    var mentionOptions: [MentionOption] = []
    /// P6:当前钉住的引擎 trigger(nil = 未钉,默认灵魂层)。
    var pinnedMentionTrigger: String? = nil
    /// P6:钉住回调(chip 菜单「钉住」)。
    var onPinMention: ((String) -> Void)? = nil
    /// P6:取消钉住回调(chip 菜单「取消钉住」/ 移除钉住 chip)。
    var onUnpinMention: (() -> Void)? = nil
    let onSend: () -> Void

    /// 编辑器驱动句柄(接受候选 / 聚焦)。
    @State private var editorProxy = ChatComposerEditorProxy()
    /// 编辑器焦点(描边高亮;由 editor didBegin/EndEditing 驱动)。
    @State private var editorFocused: Bool = false
    /// 光标前「当前键入段」的 @ query(editor 回调;nil = 不在 mention 输入中)。
    @State private var mentionQuery: String? = nil
    /// picker 高亮行(过滤结果变化时重置)。
    @State private var selectedMentionIndex: Int = 0
    /// 打字 @ 被 Esc 手动关闭后,本段 mention 输入内不再自动弹出(重新进入 mention 输入时恢复)。
    @State private var mentionDismissed: Bool = false
    /// P7.2:附件条 hover 中的缩略图下标(× 移除钮显隐)。
    @State private var hoveredThumbIndex: Int? = nil

    private var canSend: Bool {
        // 只有 chip 不算可发送(路由要求 mention 后有正文)。
        ComposerParts.hasContent(parts) && !isSending
    }

    /// 打字 @ 触发的过滤候选(不处于 mention 输入 → 空)。
    private var mentionMatches: [MentionOption] {
        guard let query = mentionQuery else { return [] }
        return MentionAutocomplete.filter(mentionOptions, query: query)
    }

    private var pickerVisible: Bool {
        !mentionMatches.isEmpty && !mentionDismissed
    }

    private let placeholder = "问点什么，@ 可点名引擎…"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if pickerVisible { mentionPicker }
            if !images.isEmpty { attachmentStrip }
            inputPill
        }
        // 过滤结果变化 → 高亮归零;进入新一段 mention 输入 → dismiss 复位
        .onChange(of: mentionMatches.map(\.trigger)) { _, _ in
            selectedMentionIndex = 0
            if !mentionMatches.isEmpty { mentionDismissed = false }
        }
        // 敲全 trigger(与候选精确匹配)→ 自动落 chip(打字党一等公民,同 P6.2 词边界落 token)。
        // 接受后 editor 重建使 query 归零,onChange 不会自旋。
        .onChange(of: mentionQuery) { _, query in
            guard let query,
                  let option = mentionOptions.first(where: { $0.trigger == query.lowercased() }) else { return }
            acceptMention(option)
        }
    }

    // MARK: - P7.2 图片附件条(editor 上方,仅非空)

    /// 待发送图片横条:48pt 圆角缩略图(scaledToFill),hover 浮 × 移除;样式随 picker/inputFill。
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    attachmentThumb(image, index: index)
                }
            }
            .padding(4)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ChatCardTheme.inputFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(ChatCardTheme.hairline, lineWidth: 1)
                )
        )
    }

    /// 单张附件缩略图:NSImage 解码失败 → 占位图标(不裸奔);hover 右上浮 ×。
    private func attachmentThumb(_ image: ChatImage, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = NSImage(data: image.data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ChatCardTheme.inputFill)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ChatCardTheme.hairline, lineWidth: 1)
            )

            if hoveredThumbIndex == index {
                Button {
                    images.remove(at: index)
                    hoveredThumbIndex = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .help("移除图片")
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovering in
            hoveredThumbIndex = hovering ? index : (hoveredThumbIndex == index ? nil : hoveredThumbIndex)
        }
    }

    // MARK: - 输入 pill

    private var inputPill: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ChatComposerEditor(
                parts: $parts,
                mentionOptions: mentionOptions,
                pinnedMentionTrigger: pinnedMentionTrigger,
                placeholder: placeholder,
                proxy: editorProxy,
                onSubmit: submit,
                onEscape: dismissMentionPicker,
                onArrow: moveMentionSelection,
                onQueryChange: { mentionQuery = $0 },
                onPinMention: { onPinMention?($0) },
                onUnpinMention: { onUnpinMention?() },
                onFocusChange: { editorFocused = $0 },
                onImage: { images.append($0) }
            )
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
                        .stroke(editorFocused ? ChatCardTheme.accent.opacity(0.5) : ChatCardTheme.hairline, lineWidth: 1)
                )
        )
        .animation(.easeOut(duration: 0.15), value: editorFocused)
        .onAppear { editorProxy.focus() }
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

    // MARK: - 行式 picker(P6.2 沿用,数据从 editor query 驱动)

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

    private func moveMentionSelection(_ delta: Int) -> Bool {
        guard pickerVisible else { return false }
        let count = mentionMatches.count
        selectedMentionIndex = (selectedMentionIndex + delta + count) % count
        return true
    }

    private func dismissMentionPicker() -> Bool {
        guard pickerVisible else { return false }
        mentionDismissed = true
        return true
    }

    /// 选中候选:editor 用 chip 替换已键入的 `@query` 段(含 paw 一次性灵魂逃逸);收起 picker。
    private func acceptMention(_ option: MentionOption) {
        editorProxy.accept(option)
        selectedMentionIndex = 0
        mentionDismissed = false
    }
}
