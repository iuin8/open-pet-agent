import AppKit
import AgentMode
import SwiftUI

struct ProjectCapabilityManagerView: View {
    let state: ProjectCapabilityCardState
    let syncMessages: [String]
    let onSelectTab: (ProjectCapabilityCardState.Tab) -> Void
    let onSetEnabled: (String, Bool) -> Void
    var onSetTargetEnabled: (String, CapabilityTarget, Bool) -> Void = { _, _, _ in }
    var onOpenItem: (Int, ProjectCapabilityCardState.Item) -> Void = { _, _ in }
    var onOpenAdd: (() -> Void)? = nil
    var onShowDiagnostics: (() -> Void)? = nil
    let onSyncCodex: () -> Void
    let onSyncClaudeCode: () -> Void
    let onSyncOpencode: () -> Void
    let onClose: () -> Void
    var selectedRowID: Int? = nil
    var showsHeader = true
    var usesCardChrome = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader { header }
            actionEntrypoints
            capabilitySummary
            syncControls
            if let auditSummary = state.auditSummary { auditStatus(auditSummary) }
            if !syncMessages.isEmpty { syncMessageList }
            tabBar
            if state.visibleItems.isEmpty {
                emptyState
            } else {
                ForEach(state.visibleRows, id: \.item.id) { row in
                    itemView(row.item, rowID: row.rowID)
                }
            }
        }
        .padding(10)
        .background(cardBackground)
        .overlay(cardStroke)
    }

    @ViewBuilder private var cardBackground: some View {
        if usesCardChrome {
            RoundedRectangle(cornerRadius: ChatCardTheme.bubbleRadius, style: .continuous)
                .fill(ChatCardTheme.petBubbleFill.opacity(0.95))
        }
    }

    @ViewBuilder private var cardStroke: some View {
        if usesCardChrome {
            RoundedRectangle(cornerRadius: ChatCardTheme.bubbleRadius, style: .continuous)
                .stroke(ChatCardTheme.petBubbleStroke, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(ChatCardTheme.accent)
            Text("项目能力")
                .font(ChatCardTheme.chip)
                .foregroundStyle(ChatCardTheme.textPrimary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭项目能力管理")
        }
    }

    private var actionEntrypoints: some View {
        HStack(spacing: 6) {
            if let onOpenAdd {
                secondaryAction("添加能力", icon: "plus.square.fill", action: onOpenAdd)
            }
            if let onShowDiagnostics {
                secondaryAction("项目能力诊断", icon: "checklist", action: onShowDiagnostics)
            }
        }
    }

    private func secondaryAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title).fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(ChatCardTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.52)))
        }
        .buttonStyle(.plain)
    }

    private var syncControls: some View {
        HStack(spacing: 5) {
            Button("同步 Codex") { onSyncCodex() }
            Button("同步 Claude") { onSyncClaudeCode() }
            Button("同步 opencode") { onSyncOpencode() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .foregroundStyle(ChatCardTheme.accent)
    }

    private var capabilitySummary: some View {
        let pluginCount = Set(state.items.map(\.pluginID)).count
        let skillCount = state.items.filter { $0.kind == .skill }.count
        let mcpCount = state.items.filter { $0.kind == .mcp }.count
        let issueCount = state.items.filter { $0.status == .warning || $0.status == .failed }.count
        return Text("\(pluginCount) plugins · \(skillCount) skills · \(mcpCount) MCP · \(issueCount) diagnostics")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.58))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.42)))
    }

    private func auditStatus(_ summary: ProjectCapabilityCardState.AuditSummary) -> some View {
        HStack(spacing: 5) {
            Image(systemName: summary.errorCount > 0 ? "exclamationmark.triangle.fill" : summary.warningCount > 0 ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
            Text(summary.statusText)
            if let lastSync = summary.lastSyncDescription {
                Text("同步 \(lastSync)")
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.45))
            }
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .foregroundStyle(summary.errorCount > 0 ? Color.red.opacity(0.75) : summary.warningCount > 0 ? ChatCardTheme.accent : ChatCardTheme.activeGreen)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.45)))
    }

    private var syncMessageList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(syncMessages.suffix(3).enumerated()), id: \.offset) { _, message in
                HStack(spacing: 4) {
                    Image(systemName: message.contains("失败") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    Text(message).lineLimit(1)
                }
                .foregroundStyle(message.contains("失败") ? Color.red.opacity(0.75) : ChatCardTheme.activeGreen)
            }
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(.overview, title: "全部", icon: "square.grid.2x2.fill")
            tabButton(.skills, title: "Skills", icon: "sparkles")
            tabButton(.mcp, title: "MCP", icon: "point.3.connected.trianglepath.dotted")
            tabButton(.profiles, title: "Profiles", icon: "square.stack.3d.up")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(ChatCardTheme.inputFill.opacity(0.65))
        )
    }

    private func tabButton(_ tab: ProjectCapabilityCardState.Tab, title: String, icon: String) -> some View {
        Button { onSelectTab(tab) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title).fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(state.selectedTab == tab ? ChatCardTheme.textPrimary : ChatCardTheme.textPrimary.opacity(0.55))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(state.selectedTab == tab ? Color.white.opacity(0.85) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        Text(state.selectedTab == .profiles ? "Profiles 还是预留位：后续用于项目模板组合。" : "当前项目没有这一类能力。")
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.55))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.52)))
    }

    private func itemView(_ item: ProjectCapabilityCardState.Item, rowID: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: item.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color(for: item.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(ChatCardTheme.textPrimary)
                    smallBadge(kindLabel(for: item.kind), color: color(for: item.status))
                    smallBadge("project", color: ChatCardTheme.textPrimary.opacity(0.45))
                    Text(item.pluginID)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.5))
                    statusBadge(item.status)
                }
                Text(item.sourcePath)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.52))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.targets.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.targets, id: \.target) { target in
                            targetToggle(item.pluginID, target: target)
                        }
                    }
                }
                ForEach(item.targetPaths, id: \.self) { target in
                    Text("→ \(target)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ForEach(item.diagnostics.indices, id: \.self) { index in
                    let diagnostic = item.diagnostics[index]
                    Text("\(diagnostic.severity): \(diagnostic.message)")
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(diagnostic.severity == "error" ? Color.red.opacity(0.75) : ChatCardTheme.accent.opacity(0.8))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            VStack(spacing: 5) {
                if item.kind == .skill || item.kind == .mcp {
                    Button {
                        onOpenItem(rowID, item)
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(.plain)
                    .help("打开详情")
                }
                Button {
                    onSetEnabled(item.pluginID, item.nextEnabledValue)
                } label: {
                    Image(systemName: item.isEnabled ? "power.circle.fill" : "power.circle")
                }
                .buttonStyle(.plain)
                .help(item.isEnabled ? "禁用 plugin" : "启用 plugin")
                Button {
                    openInFinder(item.sourcePath)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("在 Finder 打开 source")
                Button {
                    copy(item.copyText)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("复制 source → destination")
            }
            .font(.system(size: 10))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selectedRowID == rowID ? ChatCardTheme.accent.opacity(0.12) : Color.white.opacity(0.52))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selectedRowID == rowID ? ChatCardTheme.accent.opacity(0.42) : Color.clear, lineWidth: 1)
        )
    }

    private func statusBadge(_ status: ProjectCapabilityCardState.Item.Status) -> some View {
        Text(label(for: status))
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(color(for: status))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color(for: status).opacity(0.12)))
    }

    private func smallBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.10)))
    }

    private func targetToggle(_ pluginID: String, target: ProjectCapabilityCardState.ProjectionTargetState) -> some View {
        Button {
            onSetTargetEnabled(pluginID, target.target, !target.isEnabled)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: targetIcon(for: target.target))
                Text(targetLabel(for: target.target))
            }
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(target.isEnabled ? ChatCardTheme.accent : ChatCardTheme.textPrimary.opacity(0.35))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(target.isEnabled ? ChatCardTheme.accent.opacity(0.12) : Color.white.opacity(0.42))
            )
        }
        .buttonStyle(.plain)
        .help(target.isEnabled ? "停止投影到 \(targetLabel(for: target.target))" : "投影到 \(targetLabel(for: target.target))")
    }

    private func targetLabel(for target: CapabilityTarget) -> String {
        switch target {
        case .codex: return "Codex"
        case .claudeCode: return "Claude"
        case .opencode: return "opencode"
        }
    }

    private func targetIcon(for target: CapabilityTarget) -> String {
        switch target {
        case .codex: return "terminal.fill"
        case .claudeCode: return "sparkles"
        case .opencode: return "shippingbox.fill"
        }
    }

    private func icon(for kind: ProjectCapabilityCardState.Item.Kind) -> String {
        switch kind {
        case .skill: return "sparkles"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .profile: return "square.stack.3d.up"
        }
    }

    private func kindLabel(for kind: ProjectCapabilityCardState.Item.Kind) -> String {
        switch kind {
        case .skill: return "Skill"
        case .mcp: return "MCP"
        case .profile: return "Profile"
        }
    }

    private func label(for status: ProjectCapabilityCardState.Item.Status) -> String {
        switch status {
        case .enabled: return "已启用"
        case .disabled: return "未启用"
        case .warning: return "警告"
        case .failed: return "失败"
        }
    }

    private func color(for status: ProjectCapabilityCardState.Item.Status) -> Color {
        switch status {
        case .enabled: return ChatCardTheme.activeGreen
        case .disabled: return ChatCardTheme.textPrimary.opacity(0.35)
        case .warning: return ChatCardTheme.accent
        case .failed: return .red.opacity(0.75)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openInFinder(_ path: String) {
        var cleanPath = path
        if let hashIndex = cleanPath.firstIndex(of: "#") {
            cleanPath = String(cleanPath[..<hashIndex])
        }
        var url = URL(fileURLWithPath: cleanPath)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        guard url.path != "/" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private enum AddAction: CaseIterable {
    case plugin
    case skill
    case mcp
    case importExisting

    var title: String {
        switch self {
        case .plugin: return "Plugin"
        case .skill: return "Skill"
        case .mcp: return "MCP"
        case .importExisting: return "Import"
        }
    }

    var icon: String {
        switch self {
        case .plugin: return "shippingbox.fill"
        case .skill: return "sparkles"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .importExisting: return "tray.and.arrow.down.fill"
        }
    }
}


struct ProjectCapabilityAddFormView: View {
    var onImportExisting: (() -> Void)? = nil
    let onCreatePlugin: (String, String) -> Void
    let onAddSkill: (String, String, String, String) -> Void
    let onAddMCP: (String, String, [String]) -> Void

    @State private var addAction: AddAction = .skill
    @State private var pluginID = "dev-toolkit"
    @State private var pluginName = "Dev Toolkit"
    @State private var skillName = "code-review"
    @State private var skillDescription = "Review staged diffs before commit."
    @State private var skillBody = "Inspect git diff and report correctness issues before committing."
    @State private var mcpServerName = "filesystem"
    @State private var mcpCommand = "npx -y @modelcontextprotocol/server-filesystem"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(addActions, id: \.self) { action in addActionButton(action) }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ChatCardTheme.inputFill.opacity(0.65)))

            switch addAction {
            case .plugin:
                HStack(spacing: 6) {
                    compactField("plugin id", text: $pluginID)
                    compactField("display name", text: $pluginName)
                }
            case .skill:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        compactField("plugin id", text: $pluginID)
                        compactField("skill name", text: $skillName)
                    }
                    compactField("description", text: $skillDescription)
                    TextEditor(text: $skillBody)
                        .font(.system(size: 9, design: .rounded))
                        .scrollContentBackground(.hidden)
                        .frame(height: 112)
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChatCardTheme.inputFill.opacity(0.7)))
                }
            case .mcp:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        compactField("plugin id", text: $pluginID)
                        compactField("server", text: $mcpServerName)
                    }
                    compactField("command", text: $mcpCommand)
                }
            case .importExisting:
                Text("扫描当前项目已有 Claude / Codex Skill 与 MCP 配置，确认后写入 canonical catalog。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.62))
            }

            Button(actionTitle) { submitAddAction() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(canSubmitAddAction ? ChatCardTheme.accent : ChatCardTheme.textPrimary.opacity(0.35))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.62)))
                .disabled(!canSubmitAddAction)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.45)))
    }

    private var addActions: [AddAction] { onImportExisting == nil ? [.plugin, .skill, .mcp] : AddAction.allCases }

    private func addActionButton(_ action: AddAction) -> some View {
        Button { addAction = action } label: {
            HStack(spacing: 4) {
                Image(systemName: action.icon)
                Text(action.title).fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(addAction == action ? ChatCardTheme.textPrimary : ChatCardTheme.textPrimary.opacity(0.55))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(addAction == action ? Color.white.opacity(0.85) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var actionTitle: String {
        switch addAction {
        case .plugin: return "创建 Plugin"
        case .skill: return "添加 Skill"
        case .mcp: return "添加 MCP"
        case .importExisting: return "导入现有"
        }
    }

    private var canSubmitAddAction: Bool {
        switch addAction {
        case .plugin: return isValidPluginID(pluginID) && !pluginName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .skill:
            return isValidPluginID(pluginID) && !skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !skillDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !skillBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .mcp:
            return isValidPluginID(pluginID) && !mcpServerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !mcpCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .importExisting: return onImportExisting != nil
        }
    }

    private func submitAddAction() {
        switch addAction {
        case .plugin: onCreatePlugin(pluginID, pluginName)
        case .skill: onAddSkill(pluginID, skillName, skillDescription, skillBody)
        case .mcp: onAddMCP(pluginID, mcpServerName, mcpCommand.split(separator: " ").map(String.init))
        case .importExisting: onImportExisting?()
        }
    }

    private func isValidPluginID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("/") && trimmed != "." && trimmed != ".."
    }

    private func compactField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 9.5, design: .rounded))
            .textFieldStyle(.plain)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChatCardTheme.inputFill.opacity(0.7)))
    }
}
