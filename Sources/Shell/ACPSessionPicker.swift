import SwiftUI

/// ACP 会话选择器(P2):composer 行的小芯片按钮 + popover 会话列表。
///
/// 样式对齐同排 `ProjectMenu`(chip + chevron)。popover 全自绘行(标题 + 相对时间 +
/// 当前勾),不用 `Menu` —— 富行渲染会被系统 Menu 压扁(lessons §1 会话 picker 判例)。
/// 打开 popover 时触发 `onRefreshACPSessions`(App 重新 session/list)。
struct ACPSessionPicker: View {
    @ObservedObject var state: ChatCardState
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
            if isPresented { state.onRefreshACPSessions?() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .font(ChatCardTheme.chip)
            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(ChatCardTheme.textPrimary.opacity(0.07))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("ACP 会话:切换历史会话或开新会话")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
                .frame(width: 260)
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ACP 会话")
                    .font(ChatCardTheme.chip.weight(.semibold))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.6))
                Spacer()
                if state.isLoadingACPSessions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 新会话:置顶固定行(不等列表数据)
            Button {
                isPresented = false
                state.onRequestNewACPSession?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ChatCardTheme.accent)
                    Text("新会话")
                        .font(ChatCardTheme.body)
                        .foregroundStyle(ChatCardTheme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.vertical, 2)

            if state.acpSessions.isEmpty && !state.isLoadingACPSessions {
                Text("暂无历史会话")
                    .font(ChatCardTheme.chip)
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.acpSessions) { item in
                            sessionRow(item)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(.vertical, 4)
    }

    private func sessionRow(_ item: ACPSessionItem) -> some View {
        Button {
            isPresented = false
            if !item.isCurrent { state.onSelectACPSession?(item.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.isCurrent ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(item.isCurrent ? ChatCardTheme.accent : ChatCardTheme.textPrimary.opacity(0.25))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(ChatCardTheme.body)
                        .foregroundStyle(ChatCardTheme.textPrimary)
                        .lineLimit(1)
                    if let updatedAt = item.updatedAt {
                        Text(updatedAt, style: .relative)
                            .font(ChatCardTheme.chip)
                            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.45))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
