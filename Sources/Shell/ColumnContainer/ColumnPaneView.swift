import AgentSensing
import SwiftUI

/// 列容器里的单列面板。
///
/// 头部策略（访达式：内容自描述）：
/// - **list 列**：渲染 ColumnPaneView 列头（图标 + 标题 + 副标题 + tinted 底；root 列含关闭按钮）——
///   因 `TranscriptListView` 本身无标题，需列头点明「这是哪类列表」。
/// - **detail / image 列**：**不挂列头**，内容视图（`DetailPaneContent` / `ImagePaneContent`）自带更丰富的
///   头（状态图标 + 工具名 + summary），避免「详情」+「Edit」双头冗余。root 列改用右上悬浮关闭按钮。
///
/// 宽度由 `width(for:)` 固定：list 360 / detail 520 / image 460。
/// 列内行 drill-in 通过 `onRowDrillIn` 透传给 `MillerColumnsView`；列表行点击经 `onListRowTapped` 由
/// wiring 层计算子列 `ColumnKind` 后再调 `state.drillIn`。
struct ColumnPaneView: View {

    let column: Column
    let isRoot: Bool

    /// 列内行 drill-in：把 rowId 展开为右侧新列（kind 由 wiring 按行类型决定，见 Task 7 buildChildColumn）。
    let onRowDrillIn: (_ rowId: Int, _ child: ColumnKind) -> Void

    /// 整容器关闭（仅 root 列头显示关闭按钮时调用）。
    let onClose: () -> Void

    /// 列内 list 行点击：将 item 透传给 wiring，由 wiring 算出 child kind 后调 drillIn。
    let onListRowTapped: (_ item: ConversationItem) -> Void

    /// 列内 workflow 工具行 pill 点击：打开该 run 的衍生 agent 列。
    var onOpenWorkflow: ((String) -> Void)? = nil

    /// 窗口**置顶**态(仅 root 列头显置顶按钮,与主卡/浏览 sheet 同一 `CardPinButton`)。
    var isPinned: Bool = false
    /// 点根列置顶按钮(仅 root 非 nil)。
    var onTogglePin: (() -> Void)? = nil

    // MARK: - 宽度常量

    /// 按 kind 返回列定宽。
    static func width(for kind: ColumnKind) -> CGFloat {
        switch kind {
        case .list:   return 360
        case .detail: return DetailPaneContent.width   // 520
        case .image:  return 460
        case .projectCapabilityManager: return 380
        case .projectCapabilitySkillDetail,
             .projectCapabilityMCPDetail,
             .projectCapabilityImport,
             .projectCapabilityAdd,
             .projectCapabilityDiagnostics: return 520
        }
    }

    private var showsColumnHeader: Bool {
        switch column.kind {
        case .list, .projectCapabilityManager: return true
        case .detail, .image, .projectCapabilitySkillDetail,
             .projectCapabilityMCPDetail, .projectCapabilityImport,
             .projectCapabilityAdd, .projectCapabilityDiagnostics: return false
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if showsColumnHeader {
                listHeader
                Rectangle()
                    .fill(ChatCardTheme.hairline)
                    .frame(height: 0.5)
            }
            content
        }
        .frame(width: Self.width(for: column.kind))
        .background(ChatCardTheme.cardBackground)
        .overlay(alignment: .topTrailing) {
            // detail/image 根列无列头 → 右上悬浮置顶 + 关闭（list / 项目能力列的在列头内）。
            if isRoot, !showsColumnHeader {
                HStack(spacing: 4) {
                    floatingPinButton
                    floatingCloseButton
                }
                .padding(8)
            }
        }
    }

    // MARK: - list 列头（tinted 底，与主卡 headerBar / detail 头同一视觉体系）

    @ViewBuilder private var listHeader: some View {
        switch column.kind {
        case .list(_, _, let glyph, let title, let subtitle):
            columnHeader(glyph: glyph, title: title, subtitle: subtitle)
        case .projectCapabilityManager:
            columnHeader(glyph: "shippingbox.fill", title: "项目能力", subtitle: "Skills / MCP / Profiles")
        case .detail, .image, .projectCapabilitySkillDetail,
             .projectCapabilityMCPDetail, .projectCapabilityImport,
             .projectCapabilityAdd, .projectCapabilityDiagnostics:
            EmptyView()
        }
    }

    private func columnHeader(glyph: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ChatCardTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(ChatCardTheme.textPrimary.opacity(0.9))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundColor(ChatCardTheme.textPrimary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if isRoot {
                CardPinButton(isPinned: isPinned) { onTogglePin?() }   // 置顶(同主卡/浏览 sheet)
                closeButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ChatCardTheme.accent.opacity(0.05))
    }

    /// list 列头内关闭按钮（root 列）。
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ChatCardTheme.textPrimary.opacity(0.5))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }

    /// detail/image 根列右上悬浮关闭（无列头时的关闭入口）。圆形浅底 + hairline 描边，
    /// 在 diff/图片内容上都清晰可见。
    private var floatingCloseButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(ChatCardTheme.textPrimary.opacity(0.55))
                .frame(width: 20, height: 20)
                .background(Circle().fill(ChatCardTheme.cardBackground.opacity(0.92)))
                .overlay(Circle().stroke(ChatCardTheme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// detail/image 根列右上悬浮置顶(无列头时的置顶入口)。同 close 的圆形浅底,置顶时 accent 实心。
    private var floatingPinButton: some View {
        Button(action: { onTogglePin?() }) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isPinned ? ChatCardTheme.accent : ChatCardTheme.textPrimary.opacity(0.55))
                .frame(width: 20, height: 20)
                .background(Circle().fill(ChatCardTheme.cardBackground.opacity(0.92)))
                .overlay(Circle().stroke(ChatCardTheme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(isPinned ? "已置顶(点别处不关)" : "置顶(点别处不关)")
    }

    // MARK: - 内容分发

    @ViewBuilder private var content: some View {
        switch column.kind {
        case .list(let items, let subBy, _, _, _):
            TranscriptListView(
                items: items,
                highlightedItemId: column.selectedRowId,
                canLoadEarlier: false,
                isLoadingEarlier: false,
                showCodexHint: false,
                onExpandToSide: { onListRowTapped($0) },
                onLoadEarlierTap: {},
                onReachTop: {},
                subagentByItemId: subBy,
                onOpenSubagent: { onListRowTapped($0) },
                onOpenWorkflow: onOpenWorkflow
            )
        case .detail(let item):
            DetailPaneContent(item: item)
        case .image(let data):
            ImagePaneContent(data: data)
        case .projectCapabilityManager(let model):
            ProjectCapabilityManagerColumnView(
                model: model,
                selectedRowID: column.selectedRowId,
                onClose: onClose
            )
        case .projectCapabilitySkillDetail(let model):
            ProjectCapabilitySkillDetailView(model: model)
        case .projectCapabilityMCPDetail(let model):
            ProjectCapabilityMCPDetailView(model: model)
        case .projectCapabilityImport(let model):
            ProjectCapabilityImportView(model: model)
        case .projectCapabilityAdd(let model):
            ProjectCapabilityAddView(model: model)
        case .projectCapabilityDiagnostics(let panel):
            ProjectCapabilityPanelView(panel: panel) { onClose() }
        }
    }
}

private struct ProjectCapabilityManagerColumnView: View {
    @ObservedObject var model: ProjectCapabilityColumnState
    let selectedRowID: Int?
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            ProjectCapabilityManagerView(
                state: model.card,
                syncMessages: model.syncMessages,
                onSelectTab: { model.selectTab($0) },
                onSetEnabled: { model.setPluginEnabled(pluginID: $0, enabled: $1) },
                onSetTargetEnabled: { model.setTargetEnabled(pluginID: $0, target: $1, enabled: $2) },
                onSetSourceConfirmed: { model.setSourceConfirmed(pluginID: $0, confirmed: $1) },
                onRevokeAllSourceConfirmations: { model.revokeAllSourceConfirmations() },
                onOpenItem: { model.openItem($1, rowID: $0) },
                onOpenAdd: { model.openAdd() },
                onShowDiagnostics: { model.showDiagnostics() },
                onPreviewCodex: { model.previewCodex() },
                onPreviewClaudeCode: { model.previewClaudeCode() },
                onPreviewOpencode: { model.previewOpencode() },
                onRestoreLatestBackup: { model.restoreLatestBackup() },
                onSyncCodex: { model.syncCodex() },
                onSyncClaudeCode: { model.syncClaudeCode() },
                onSyncOpencode: { model.syncOpencode() },
                onClose: onClose,
                selectedRowID: selectedRowID,
                showsHeader: false,
                usesCardChrome: false
            )
            .padding(6)
        }
    }
}


private struct ProjectCapabilityAddView: View {
    @ObservedObject var model: ProjectCapabilityColumnState

    var body: some View {
        ScrollView {
            ProjectCapabilityAddFormView(
                onImportExisting: { model.openImport() },
                onCreatePlugin: { model.createPlugin(pluginID: $0, name: $1) },
                onAddSkill: { model.addSkill(pluginID: $0, skillName: $1, skillDescription: $2, body: $3) },
                onAddMCP: { model.addMCP(pluginID: $0, serverName: $1, command: $2) }
            )
            .padding(10)
        }
    }
}
