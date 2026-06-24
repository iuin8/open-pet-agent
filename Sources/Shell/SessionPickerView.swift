import AgentSensing
import SwiftUI

/// 陪伴卡片会话切换器(P3.8 G3)—— 折叠栏 + 自定义 popover 下拉富列表。
///
/// **不用 SwiftUI `Menu`**:`Menu` + `.borderlessButton` 在 macOS 会把多元素 HStack label 压扁
/// (只渲染主文本 + 系统 chevron,丢掉绿点 / 分支药丸 / 计数),NSMenu 项也只单行文本 —— 给不了
/// claude-devtools 式富行(标题 + 项目·分支·N条·相对时间 + 活跃点 + 勾)。改用 `Button` + `.popover`
/// 完全自绘(参考 lessons §1「框架信号」:别在错原语上硬补)。
struct SessionPickerView: View {
    let sessions: [AgentSessionSummary]
    /// 当前 tab 的 agent —— 据此拼复制按钮的终端续聊命令(`SessionResumeCommand`)。
    let agent: AgentKind
    /// 用户选了某会话 → 通知上层(钉住 + 拉历史)。
    let onSelect: (String) -> Void
    /// 切换某会话钉住态(行内 📌)。
    let onTogglePin: (String) -> Void
    /// 「浏览历史…」→ 上层开访达选目录。
    let onBrowse: () -> Void

    @State private var open = false

    private var selected: AgentSessionSummary? {
        sessions.first(where: \.isSelected) ?? sessions.first
    }

    var body: some View {
        // 底色/hairline 由调用方(AgentSessionTabView.headerBar)统一提供 —— 与右侧重置按钮共底,不双层。
        Button { open.toggle() } label: { collapsedBar }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                dropdown
            }
    }

    // MARK: - 折叠栏(当前会话:活跃点 + 标题 + 分支 + 会话数)

    private var collapsedBar: some View {
        HStack(spacing: 5) {
            collapsedDot
            Text(selected?.title ?? selected?.label ?? "会话")
                .font(ChatCardTheme.chip)
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.75))
                .lineLimit(1)
            if let branch = selected?.gitBranch {
                branchChip(branch)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.4))
            Spacer(minLength: 4)
            Text("\(sessions.count) 个会话")
                .font(.system(size: 9.5, weight: .regular, design: .rounded))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.35))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - 下拉富列表(卡片栈 —— 与浏览历史 sheet 同一 `SessionRowCard`)

    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sessions) { s in
                SessionRowCard(
                    summary: s,
                    isSelected: s.isSelected,
                    isPinned: s.isPinned,
                    copyCommand: SessionResumeCommand.command(agent: agent, sessionId: s.id),
                    onTap: { onSelect(s.id); open = false },   // 文件不可用时卡片内部已拦
                    onTogglePin: { onTogglePin(s.id) }
                )
            }
            // 底部「浏览历史…」入口(分隔线后)。
            Rectangle().fill(ChatCardTheme.hairline).frame(height: 0.5).padding(.vertical, 1)
            browseRow
        }
        .padding(8)
        .frame(width: 300)
        // 不透明白底:盖住系统 NSPopover 的 vibrancy material(深色模式下变暗)。本卡走固定浅色「白卡深靛字」,
        // 字色不随系统外观变 → 承载它的 surface 必须铺不透明浅底(与 SessionBrowseSheet:47 / 主卡 ChatCardView 一致);
        // 漏这层 → 夜间深靛字裸在系统暗 material 上对比度崩、看不清。
        .background(ChatCardTheme.cardBackground)
    }

    /// 「浏览历史…」行 → 关下拉 + 通知上层开访达选目录。
    private var browseRow: some View {
        Button { open = false; onBrowse() } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(ChatCardTheme.accent.opacity(0.8))
                Text("浏览历史…").font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 组件

    /// 折叠栏活跃点:选中会话 30s 内被写 → 绿点;否则回退会话堆图标。
    @ViewBuilder
    private var collapsedDot: some View {
        if SessionRecency.isOngoing(lastModified: selected?.lastModified, now: Date()) {
            Circle()
                .fill(ChatCardTheme.activeGreen)
                .frame(width: 6, height: 6)
        } else {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 10))
                .foregroundStyle(ChatCardTheme.accent.opacity(0.8))
        }
    }

    private func branchChip(_ branch: String) -> some View {
        Text(branch)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(ChatCardTheme.accent.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(ChatCardTheme.accent.opacity(0.12)))
    }
}
