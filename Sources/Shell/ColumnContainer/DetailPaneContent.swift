import AgentSensing
import SwiftUI

/// 列容器里的「单条 detail」内容（从旧 `AgentDetailCardView` 抽出，去掉 beak/卡壳/pin/close）。
///
/// - tool → 状态头 + 输入/输出（`DetailContentView` 等宽块，带换行/原文/复制工具条）
/// - user/assistant/thinking/assistantTurn → 角色头 + 正文
///
/// 不含 `SideCardPinButton`、`onClose` 按钮、`BubbleShape`、`scaleEffect`、`opacity`、`offset`
/// 等外层卡/beak 修饰——那些由列面板包装层负责。
struct DetailPaneContent: View {

    let item: ConversationItem

    /// 内容区域固定宽度（与 `AgentDetailCardView.width` 对齐，便于列面板直接复用）。
    static let width: CGFloat = 520

    var body: some View {
        switch item.kind {
        case .tool(let name, let summary, let toolState, let input, let output):
            toolBody(name: name, summary: summary, toolState: toolState, input: input, output: output)
        case .user(let text):
            textBody(role: "你的消息", glyph: "person.fill", text: text)
        case .assistant(let text):
            textBody(role: "助手回复", glyph: "sparkles", text: text)
        case .thinking(let text):
            textBody(role: "思考", glyph: "brain", text: text)
        case .assistantTurn(let turn):
            textBody(role: "助手回复", glyph: "sparkles", text: turn.finalText)
        case .systemNotice(let text):
            textBody(role: "协作通知", glyph: "person.2.fill", text: item.systemNoticeDetail ?? text)
        case .compactBoundary:
            textBody(role: "压缩上下文", glyph: "arrow.triangle.merge", text: item.compactSummary ?? "")
        case .awaiting(let reason):
            textBody(role: awaitingRole(reason), glyph: "bell.fill", text: item.awaitingDetail ?? AgentConversationRow.awaitingText(reason))
        }
    }

    // MARK: - awaiting 主体

    private func awaitingRole(_ reason: AwaitReason) -> String {
        switch reason {
        case .question: return "等待回答"
        case .permission: return "等待确认"
        case .notification: return "提醒"
        }
    }

    // MARK: - tool 主体

    private func toolBody(
        name: String,
        summary: String,
        toolState: ConversationItem.ToolState,
        input: String?,
        output: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            toolHeader(name: name, summary: summary, toolState: toolState)
            Rectangle().fill(ChatCardTheme.hairline).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let input, !input.isEmpty {
                        DetailContentView(text: input, maxWidth: Self.width - 28, label: "输入")
                    }
                    if let output, !output.isEmpty {
                        DetailContentView(text: output, maxWidth: Self.width - 28, label: "输出")
                    } else if toolState != .running {
                        noOutputPlaceholder
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 工具头部（状态图标 + 工具名 + summary，无 pin/close）

    private func toolHeader(
        name: String,
        summary: String,
        toolState: ConversationItem.ToolState
    ) -> some View {
        HStack(alignment: .center, spacing: 9) {
            stateGlyph(toolState)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(ChatCardTheme.textPrimary.opacity(0.9))
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(ChatCardTheme.textPrimary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(ChatCardTheme.accent.opacity(0.05))   // 与 list 列头同一 tinted header strip 体系
    }

    // MARK: - user / assistant / thinking 正文（角色头 + 滚动正文，无 pin/close）

    private func textBody(role: String, glyph: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: glyph)
                    .font(.system(size: 13))
                    .foregroundColor(ChatCardTheme.accent.opacity(0.8))
                Text(role)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(ChatCardTheme.textPrimary.opacity(0.9))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(ChatCardTheme.accent.opacity(0.05))   // 同上：统一列头 tinted 底
            Rectangle().fill(ChatCardTheme.hairline).frame(height: 0.5)
            ScrollView {
                DetailContentView(text: text, maxWidth: Self.width - 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
    }

    // MARK: - 状态图标

    @ViewBuilder
    private func stateGlyph(_ toolState: ConversationItem.ToolState) -> some View {
        switch toolState {
        case .running:
            Image(systemName: "circle.dotted")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ChatCardTheme.accent)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(Color(nsColor: .systemGreen))
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 14))
                .foregroundColor(Color(nsColor: .systemRed))
        }
    }

    // MARK: - 无文本输出占位

    /// 工具已完成但无文本输出（图片/纯状态结果）→ 占位标注，避免「输出」段凭空消失。
    private var noOutputPlaceholder: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("输出")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(ChatCardTheme.textPrimary.opacity(0.45))
            Text("(无文本输出)")
                .font(.system(size: 12, design: .rounded))
                .italic()
                .foregroundColor(ChatCardTheme.textPrimary.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
