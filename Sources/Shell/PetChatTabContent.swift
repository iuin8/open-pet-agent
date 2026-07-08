import SwiftUI

/// Pet Chat tab 的内容区：可滚动多轮消息列表 + 底部 composer。
///
/// P3.1 从 `ChatCardView` 整块抽出 —— **逻辑/绑定原样搬，行为/布局零变化**。
/// 卡片的锚定/tail/尺寸/进场动画 + 背景 + tab bar 仍在 `ChatCardView` 层。
struct PetChatTabContent: View {
    @ObservedObject var state: ChatCardState
    let onSend: (String) -> Void

    private static let bottomID = "chat-card-bottom"

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composer
        }
    }

    // MARK: - 消息列表（可滚动，流式时跟到底）

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if state.messages.isEmpty { emptyHint }
                    ForEach(state.messages) { row in
                        ChatCardMessageRow(row: row, isThinking: state.isThinking)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
            .onChange(of: state.messages.count) { _ in
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: state.messages.last?.text) { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22))
                .foregroundStyle(ChatCardTheme.accent.opacity(0.5))
            Text("问问我，或聊聊你在忙啥~")
                .font(ChatCardTheme.body)
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if !state.replyOptions.isEmpty || state.currentProject != nil {
                HStack(spacing: 6) {
                    if !state.replyOptions.isEmpty {
                        ReplySourceBar(selected: replyTargetBinding, options: state.replyOptions)
                    }
                    if let current = state.currentProject {
                        ProjectMenu(
                            current: current,
                            projects: state.projects,
                            onSelect: { state.commitProject($0) },
                            onRequestCreateProject: { state.requestCreateProject() },
                            onRequestCreateExternal: { state.requestCreateExternal() },
                            onRequestRenameCurrent: { state.requestRenameCurrent() },
                            onRequestDeleteCurrent: { state.requestDeleteCurrent() },
                            onRequestSyncCodexProjection: { state.requestSyncCodexProjection() },
                            onRequestSyncClaudeCodeProjection: { state.requestSyncClaudeCodeProjection() },
                            onRequestSyncOpencodeProjection: { state.requestSyncOpencodeProjection() },
                            onRequestShowProjectCapabilityDiagnostics: { state.requestShowProjectCapabilityDiagnostics() }
                        )
                    }
                }
            }
            if let syncMessage = state.codexProjectionSyncMessage {
                HStack(spacing: 4) {
                    Image(systemName: syncMessage.contains("失败") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(syncMessage).lineLimit(1)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(syncMessage.contains("失败") ? .red.opacity(0.75) : ChatCardTheme.accent.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ChatCardComposer(draft: $state.draft, isSending: state.isSending) {
                onSend(state.draft)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// 回复来源绑定：set 触发 `commitReplyTarget`（持久化 + 即时切 engine）。
    private var replyTargetBinding: Binding<ReplyTarget> {
        Binding(
            get: { state.replyTarget },
            set: { state.commitReplyTarget($0) }
        )
    }
}
