import AppKit
import AgentMode
import SwiftUI

struct ProjectCapabilityMCPDetailView: View {
    @ObservedObject var model: ProjectCapabilityMCPDetailState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metadata
            Divider()
            if model.isDeleted {
                deletedNotice
            } else if model.isEditing { editor } else { preview }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.red.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(ChatCardTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.server.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(model.pluginID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.5))
            }
            Spacer()
            if model.isEditing {
                Button("取消") { model.cancelEditing() }
                Button("保存") { model.save() }
                    .foregroundStyle(ChatCardTheme.accent)
            } else if !model.isDeleted {
                Button("删除", role: .destructive) { confirmDelete() }
                    .foregroundStyle(Color.red.opacity(0.8))
                Button("编辑") { model.beginEditing() }
                    .foregroundStyle(ChatCardTheme.accent)
            }
        }
        .buttonStyle(.plain)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            metadataRow("来源", model.sourcePath)
            metadataRow("Canonical", "\(model.server.fileRef)#\(model.server.name)")
            metadataRow("Transport", model.server.transport.rawValue)
            metadataRow("目标", model.server.targets.map(displayName).joined(separator: " · ").nonEmpty ?? "未启用")
            ForEach(model.server.diagnostics.indices, id: \.self) { index in
                let diagnostic = model.server.diagnostics[index]
                Label(
                    diagnostic.message,
                    systemImage: diagnostic.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(diagnostic.severity == .error ? Color.red.opacity(0.8) : ChatCardTheme.accent)
            }
        }
        .font(.system(size: 10, design: .rounded))
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).fontWeight(.semibold)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.58))
                .textSelection(.enabled)
        }
    }

    private var preview: some View {
        ScrollView {
            Text(model.server.rawJSON ?? "{}")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var deletedNotice: some View {
        Label("已从 canonical catalog 删除。显式同步前，现有投影文件不会自动变化。", systemImage: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.7))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("编辑模式", selection: Binding(
                get: { model.editorMode },
                set: { model.selectEditorMode($0) }
            )) {
                ForEach(ProjectCapabilityMCPDetailState.EditorMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.editorMode == .raw { rawEditor } else { basicEditor }
        }
    }

    private var basicEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Transport", selection: $model.draftTransport) {
                    Text("stdio").tag(MCPTransport.stdio)
                    Text("http").tag(MCPTransport.http)
                    Text("sse").tag(MCPTransport.sse)
                }
                .pickerStyle(.segmented)

                if model.draftTransport == .stdio {
                    field("Command", text: $model.draftCommand, prompt: "npx")
                    textArea("Args（每行一个）", text: $model.draftArguments, minimumHeight: 72)
                } else {
                    field("URL", text: $model.draftURL, prompt: "https://example.com/mcp")
                }
                textArea("Env（每行 KEY=VALUE）", text: $model.draftEnvironment, minimumHeight: 72)
                field("Working Directory", text: $model.draftCWD, prompt: "/path/to/project")
            }
        }
    }

    private var rawEditor: some View {
        TextEditor(text: $model.draftRawJSON)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(ChatCardTheme.inputFill.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChatCardTheme.hairline, lineWidth: 0.5))
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除 MCP server「\(model.server.name)」?"
        alert.informativeText = "只会删除 canonical catalog 条目；Codex / Claude Code / opencode 投影文件不会自动变化。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.delete()
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .rounded))
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(ChatCardTheme.inputFill.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(ChatCardTheme.hairline, lineWidth: 0.5))
        }
    }

    private func textArea(_ label: String, text: Binding<String>, minimumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold, design: .rounded))
            TextEditor(text: text)
                .font(.system(size: 10, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: minimumHeight)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(ChatCardTheme.inputFill.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(ChatCardTheme.hairline, lineWidth: 0.5))
        }
    }

    private func displayName(_ target: CapabilityTarget) -> String {
        switch target {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .opencode: return "opencode"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
