import AgentMode
import Combine
import SwiftUI

public enum ProjectCapabilitySkillDetailError: Error, LocalizedError {
    case savingUnavailable
    case missingSkill(String)

    public var errorDescription: String? {
        switch self {
        case .savingUnavailable: return "当前 Skill 无法保存"
        case .missingSkill(let ref): return "保存后找不到 Skill：\(ref)"
        }
    }
}

@MainActor
public final class ProjectCapabilitySkillDetailState: ObservableObject {
    @Published public private(set) var skill: CapabilitySkill
    @Published public var draftBody: String
    @Published public private(set) var isEditing = false
    @Published public private(set) var errorMessage: String?

    public let pluginID: String
    public let sourcePath: String
    public let sourceProvenance: String?
    private let onSave: (String) throws -> CapabilitySkill

    public init(
        pluginID: String,
        sourcePath: String,
        sourceProvenance: String? = nil,
        skill: CapabilitySkill,
        onSave: @escaping (String) throws -> CapabilitySkill
    ) {
        self.pluginID = pluginID
        self.sourcePath = sourcePath
        self.sourceProvenance = sourceProvenance
        self.skill = skill
        self.draftBody = skill.body ?? ""
        self.onSave = onSave
    }

    public func beginEditing() {
        draftBody = skill.body ?? ""
        errorMessage = nil
        isEditing = true
    }

    public func cancelEditing() {
        draftBody = skill.body ?? ""
        errorMessage = nil
        isEditing = false
    }

    public func save() {
        do {
            skill = try onSave(draftBody)
            draftBody = skill.body ?? ""
            errorMessage = nil
            isEditing = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ProjectCapabilitySkillDetailView: View {
    @ObservedObject var model: ProjectCapabilitySkillDetailState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metadata
            Divider()
            if model.isEditing { editor } else { preview }
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
            Image(systemName: "sparkles")
                .foregroundStyle(ChatCardTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.skill.name)
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
            } else {
                Button("编辑") { model.beginEditing() }
                    .foregroundStyle(ChatCardTheme.accent)
            }
        }
        .buttonStyle(.plain)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            metadataRow("来源", model.sourcePath)
            if let provenance = model.sourceProvenance { metadataRow("来源标签", provenance) }
            metadataRow("Canonical", model.skill.relativePath)
            metadataRow("目标", model.skill.targets.map(\.displayName).joined(separator: " · ").nonEmpty ?? "未启用")
            ForEach(model.skill.diagnostics.indices, id: \.self) { index in
                let diagnostic = model.skill.diagnostics[index]
                Label(diagnostic.message, systemImage: diagnostic.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
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
            Text(model.skill.body ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editor: some View {
        TextEditor(text: $model.draftBody)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(ChatCardTheme.inputFill.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChatCardTheme.hairline, lineWidth: 0.5))
    }
}

private extension CapabilityTarget {
    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .opencode: return "opencode"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
