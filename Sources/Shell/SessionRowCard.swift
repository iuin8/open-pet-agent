import AppKit
import SwiftUI

/// 会话行**共享卡片** —— picker 下拉与浏览历史 sheet 共用一套渲染(两处一致 = 卡片形式)。
///
/// 一行卡:活跃点 + 标题 + 副行(项目·分支·N条·时间) + 复制按钮 + 钉住按钮。
/// **选中只用底色**(无右侧勾):勾会把钉住按钮顶得与未选中行不齐 → 用 accent 底色表选中,
/// 复制/钉住固定在右侧定宽位 → 各行按钮恒对齐。复制走 `NSPasteboard` + 本地「已复制」反馈
/// (`@State copied`,故卡片需是独立 View struct)。
struct SessionRowCard: View {
    let summary: AgentSessionSummary
    let isSelected: Bool
    let isPinned: Bool
    /// 终端续聊命令(复制按钮点了写剪贴板);由调用方按 agent 预拼(`SessionResumeCommand`)。
    let copyCommand: String
    /// 点行主体(picker = 选中切换;browse = 加载该会话)。文件不可用时卡片内部已拦,不会触发。
    let onTap: () -> Void
    /// 点 📌 切钉住态。
    let onTogglePin: () -> Void

    @State private var copied = false

    /// 复制成功后勾保持时长(落在 1–2s 舒适反馈窗内:claude-devtools 600ms 偏急、其 CopyButton 2000ms 偏松)。
    private static let copiedFeedbackDuration: TimeInterval = 1.1

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            activeDot.padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title ?? summary.label)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(summary.isUnavailable ? 0.35 : 0.9))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            copyButton
            pinButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { if !summary.isUnavailable { onTap() } }
    }

    // MARK: - 右侧定宽按钮(各行恒对齐)

    /// 复制终端续聊命令 → 剪贴板;短暂翻成勾(已复制)再翻回。
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyCommand, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFeedbackDuration) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: copied ? .bold : .regular))
                .foregroundStyle(copied ? ChatCardTheme.activeGreen
                                        : ChatCardTheme.textPrimary.opacity(0.3))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "已复制" : "复制终端续聊命令:\(copyCommand)")
    }

    /// 钉住切换(非活跃会话也能靠它留在列表)。
    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10))
                .foregroundStyle(isPinned ? ChatCardTheme.accent : ChatCardTheme.textPrimary.opacity(0.3))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPinned ? "取消钉住" : "钉住(非活跃也留在列表)")
    }

    // MARK: - 视觉

    /// 卡底:选中 = accent 染色 + 细描边;未选中 = 极淡灰卡。
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? ChatCardTheme.accent.opacity(0.12) : ChatCardTheme.textPrimary.opacity(0.025))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ChatCardTheme.accent.opacity(isSelected ? 0.30 : 0), lineWidth: 0.5)
            )
    }

    /// 活跃点:文件 30s 内被写 → 绿点;否则透明占位(保持标题左缘对齐)。
    @ViewBuilder
    private var activeDot: some View {
        if SessionRecency.isOngoing(lastModified: summary.lastModified, now: Date()) {
            Circle().fill(ChatCardTheme.activeGreen).frame(width: 6, height: 6)
        } else {
            Circle().fill(Color.clear).frame(width: 6, height: 6)
        }
    }

    /// 副行:`项目 · 分支 · N条 · 相对时间`(缺项跳过;标题已是项目名时不重复)。不可用 → 提示删除。
    private var subtitle: String {
        if summary.isUnavailable { return "文件已移除 · 点 📌 取消钉住" }
        var parts: [String] = []
        if summary.title != nil, summary.label != summary.title { parts.append(summary.label) }
        if let branch = summary.gitBranch { parts.append(branch) }
        if let count = summary.messageCount { parts.append("\(count) 条") }
        parts.append(SessionRecency.shortRelative(from: summary.lastModified ?? summary.lastActivity, now: Date()))
        return parts.joined(separator: " · ")
    }
}
