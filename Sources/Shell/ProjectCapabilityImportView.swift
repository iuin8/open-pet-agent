import AgentMode
import SwiftUI

struct ProjectCapabilityImportView: View {
    @ObservedObject var model: ProjectCapabilityImportState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                destinationFields
                diagnostics
                candidateList
                preview
                footer
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("导入现有能力", systemImage: "square.and.arrow.down")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(ChatCardTheme.textPrimary)
            Text("扫描项目里的 Claude Code / Codex Skill 与 MCP 配置；确认前不会写入。")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.58))
        }
    }

    private var destinationFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CANONICAL PLUGIN")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.48))
            HStack(spacing: 8) {
                field("plugin id", text: $model.pluginID)
                field("显示名称", text: $model.pluginName)
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(ChatCardTheme.inputFill.opacity(0.75))
            )
    }

    @ViewBuilder private var diagnostics: some View {
        if !model.diagnostics.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Label(diagnostic.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.red.opacity(0.78))
                }
            }
        }
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("发现 \(model.candidates.count) 项")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.62))
            if model.candidates.isEmpty {
                Text("当前项目没有可导入的 Skill 或 MCP 配置。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.5))
                    .padding(.vertical, 12)
            } else {
                ForEach(model.candidates) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    private func candidateRow(_ candidate: ProjectCapabilityImportCandidate) -> some View {
        let blocked = !candidate.diagnostics.isEmpty
        return HStack(alignment: .top, spacing: 8) {
            Button {
                model.toggleSelection(candidate.id)
            } label: {
                Image(systemName: model.selectedIDs.contains(candidate.id)
                    ? "checkmark.square.fill" : "square")
                    .foregroundStyle(blocked
                        ? ChatCardTheme.textPrimary.opacity(0.25)
                        : ChatCardTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(blocked)

            Button {
                model.focus(candidate.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: candidate.kind == .skill
                            ? "sparkles" : "point.3.connected.trianglepath.dotted")
                        Text(candidate.name)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Text(candidate.kind == .skill ? "Skill" : "MCP")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(ChatCardTheme.accent)
                    }
                    ForEach(candidate.sources, id: \.url) { source in
                        Text(source.url.path)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    ForEach(Array(candidate.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text(diagnostic.message)
                            .font(.system(size: 8.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.red.opacity(0.75))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.focusedCandidateID == candidate.id
                    ? ChatCardTheme.accent.opacity(0.11)
                    : Color.white.opacity(0.48))
        )
    }

    @ViewBuilder private var preview: some View {
        if let candidate = model.focusedCandidate {
            VStack(alignment: .leading, spacing: 5) {
                Text("预览")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.62))
                Text(previewText(candidate))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.72))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ChatCardTheme.inputFill.opacity(0.6))
                    )
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.red.opacity(0.78))
            } else if model.didImport {
                Label("已导入 canonical catalog；尚未同步到任何 Agent。", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(ChatCardTheme.activeGreen)
            }
            Button("导入所选 \(model.selectedIDs.count) 项") {
                model.importSelected()
            }
            .buttonStyle(.borderedProminent)
            .tint(ChatCardTheme.accent)
            .disabled(!model.canImport)
        }
    }

    private func previewText(_ candidate: ProjectCapabilityImportCandidate) -> String {
        if let body = candidate.skillBody { return body }
        guard let value = candidate.mcpValue else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
