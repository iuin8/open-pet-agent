import SwiftUI

/// Composer 输入框上方的「项目」选择器 —— Menu 下拉(项目多时 scalable,vs segmented 横向挤)。
///
/// 选当前 agent 工作项目(ACP engine 的 cwd + opencode config 来源)。跟 `ReplySourceBar`(engine)
/// 横排:engine 选「用什么 brain」,project 选「在哪个项目工作」。两者独立。
///
/// Menu 入口:项目列表(切换)+ 新建项目(托管)+ 添加外部项目(NSOpenPanel)+ 重命名/删除当前
/// (default 不可删改,disabled)。创建/重命名走 App 原生 NSAlert,外部走 NSOpenPanel —— **Shell 不碰
/// sheet/dialog**(NSPanel 上 SwiftUI sheet 有坑)。详见 `docs/project-config-architecture-design.md`。
struct ProjectMenu: View {
    let current: ProjectOption
    let projects: [ProjectOption]
    let onSelect: (String) -> Void
    let onRequestCreateProject: () -> Void
    let onRequestCreateExternal: () -> Void
    let onRequestRenameCurrent: () -> Void
    let onRequestDeleteCurrent: () -> Void
    let onRequestSyncCodexProjection: () -> Void
    let onRequestSyncClaudeCodeProjection: () -> Void
    let onRequestSyncOpencodeProjection: () -> Void

    var body: some View {
        Menu {
            ForEach(projects) { p in
                Button {
                    onSelect(p.id)
                } label: {
                    Text(label(for: p))
                }
            }
            Divider()
            Button {
                onRequestCreateProject()
            } label: {
                Label("新建项目", systemImage: "plus")
            }
            Button {
                onRequestCreateExternal()
            } label: {
                Label("添加外部项目…", systemImage: "folder.badge.plus")
            }
            Divider()
            Button {
                onRequestSyncCodexProjection()
            } label: {
                Label("同步 Codex 配置", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                onRequestSyncClaudeCodeProjection()
            } label: {
                Label("同步 Claude Code 配置", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                onRequestSyncOpencodeProjection()
            } label: {
                Label("同步 opencode 配置", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            Button {
                onRequestRenameCurrent()
            } label: {
                Label("重命名当前项目…", systemImage: "pencil")
            }
            .disabled(current.id == "default")
            Button {
                onRequestDeleteCurrent()
            } label: {
                Label("删除当前项目", systemImage: "trash")
            }
            .disabled(current.id == "default")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(current.name)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .font(ChatCardTheme.chip)
            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ChatCardTheme.inputFill.opacity(0.7))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Agent 工作项目 · cwd + opencode config 来源")
    }

    /// Menu 列表项 label:当前项目加 ✓ 前缀;外部项目加「(外部)」后缀。
    private func label(for p: ProjectOption) -> String {
        var s = p.id == current.id ? "✓ " : ""
        s += p.name
        if p.isExternal { s += "  (外部)" }
        return s
    }
}
