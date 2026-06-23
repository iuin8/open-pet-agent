import SwiftUI

/// 对话卡片底部 pill 输入条：多行自适应 TextField + 圆形 accent 发送钮。
/// 借鉴 AccountyCat (https://github.com/strjonas/AccountyCat) 的 ComposerView：focus 时 accent 描边、圆形发送钮带招牌
/// `accentShadow` 静态压深（4pt y、0 radius）给按钮触感。
struct ChatCardComposer: View {
    @Binding var draft: String
    let isSending: Bool
    let onSend: () -> Void

    @FocusState private var focused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("问点什么，或聊聊你在忙啥…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(ChatCardTheme.body)
                .foregroundStyle(ChatCardTheme.textPrimary)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(submit)
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
        guard canSend else { return }
        onSend()
    }
}
