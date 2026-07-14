import AppKit
import SwiftUI

struct ProjectCapabilityPanelView: View {
    let panel: ProjectCapabilityPanelState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metadata
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(panel.sections.enumerated()), id: \.offset) { _, section in
                        sectionView(section)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(ChatCardTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("项目能力诊断")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("dry-run / ownership / drift")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.5))
            }
            Spacer()
            Button {
                copy(panel.fullText)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("复制完整诊断")
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            metadataRow("引擎", panel.sections.map(\.engineName).joined(separator: " · "))
            metadataRow("状态", statusSummary)
        }
        .font(.system(size: 10, design: .rounded))
    }

    private var statusSummary: String {
        let failed = panel.sections.filter { $0.status == .failed }.count
        let warning = panel.sections.filter { $0.status == .warning }.count
        if failed > 0 { return "\(failed) 个失败" }
        if warning > 0 { return "\(warning) 个警告" }
        return "全部正常"
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).fontWeight(.semibold)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.58))
                .textSelection(.enabled)
        }
    }

    private func sectionView(_ section: ProjectCapabilityPanelState.Section) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon(for: section.status))
                    .foregroundStyle(color(for: section.status))
                Text(section.engineName)
                    .font(ChatCardTheme.chip)
                    .foregroundStyle(ChatCardTheme.textPrimary)
                if let ownership = section.ownership {
                    Text(ownership)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.55))
                        .lineLimit(1)
                }
            }
            if section.rows.isEmpty && section.diagnostics.isEmpty {
                Text("无计划写入")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.55))
            }
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            ForEach(Array(section.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                diagnosticView(diagnostic)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.52))
        )
    }

    private func rowView(_ row: ProjectCapabilityPanelState.Row) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.kind)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(ChatCardTheme.accent.opacity(0.8))
                    if let pluginID = row.pluginID {
                        Text(pluginID)
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Text(row.target)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.48))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Button {
                openInFinder(row.target)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("在 Finder 打开 target")
            Button {
                copy(row.copyText)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help(row.source == nil ? "复制 target" : "复制 source → destination")
        }
    }

    private func diagnosticView(_ diagnostic: ProjectCapabilityPanelState.Diagnostic) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(diagnostic.severity): \(diagnostic.message)")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(diagnostic.severity == "error" ? Color.red.opacity(0.75) : ChatCardTheme.textPrimary.opacity(0.7))
            if let path = diagnostic.path {
                Text(path)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func icon(for status: ProjectCapabilityPanelState.Section.Status) -> String {
        switch status {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .empty: return "minus.circle"
        }
    }

    private func color(for status: ProjectCapabilityPanelState.Section.Status) -> Color {
        switch status {
        case .ready: return ChatCardTheme.activeGreen
        case .warning: return ChatCardTheme.accent
        case .failed: return .red.opacity(0.75)
        case .empty: return ChatCardTheme.textPrimary.opacity(0.35)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openInFinder(_ path: String) {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        guard url.path != "/" else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
