import AgentSensing
import Foundation

/// 一列的内容种类。每种复用一个现有内容视图渲染（list→TranscriptListView,detail→DetailPaneContent,image→ImagePaneContent）。
public enum ColumnKind {
    /// 列表列：元数据 steps / 子 agent transcript / workflow 衍生 agent 列表。
    case list(items: [ConversationItem], subagentByItemId: [Int: SubagentRef], glyph: String, title: String, subtitle: String)
    /// 单条 detail 列：tool 的 input/output 或长消息全文。
    case detail(item: ConversationItem)
    /// 图片列：用户行图片全图。
    case image(data: Data)
    /// 项目能力管理 root 列。
    case projectCapabilityManager(ProjectCapabilityColumnState)
    /// Skill 详情/编辑列：复用同一列承载只读与编辑态。
    case projectCapabilitySkillDetail(ProjectCapabilitySkillDetailState)
    /// MCP 详情/编辑列：Basic 与 Advanced JSON 共用同一列。
    case projectCapabilityMCPDetail(ProjectCapabilityMCPDetailState)
    /// Import Existing 列：扫描、选择、预览与显式确认导入。
    case projectCapabilityImport(ProjectCapabilityImportState)
    /// 添加能力列：Plugin / Skill / MCP / Import 动作表单。
    case projectCapabilityAdd(ProjectCapabilityColumnState)
    /// 项目能力诊断列：dry-run / ownership / drift 只读面板。
    case projectCapabilityDiagnostics(ProjectCapabilityPanelState)
}

/// 列视图里的一列。`selectedRowId` = 本列哪行被 drill-in（高亮 + 紧邻右列是它的展开）。
public struct Column: Identifiable {
    public let id: Int
    public var kind: ColumnKind
    public var selectedRowId: Int?
    public init(id: Int, kind: ColumnKind, selectedRowId: Int? = nil) {
        self.id = id; self.kind = kind; self.selectedRowId = selectedRowId
    }
}

/// **纯值类型**:列栈的全部 drill-in 逻辑（访达列视图语义）。无 UI 依赖 → 无头单测（同 `layoutSideCards` 范式）。
public struct ColumnStack {
    public private(set) var columns: [Column] = []
    /// 当前根列的来源 key（主卡源行标识）—— `openRoot` toggle 判定用。
    public private(set) var rootSourceKey: String?
    private var nextId = 0

    public init() {}
    public var isEmpty: Bool { columns.isEmpty }

    /// 从主卡某行打开:清栈置单列。**同 sourceKey 且当前非空 → toggle 关**（返回 false,调用方据此 hide 窗口）。
    /// 否则置为以 `kind` 为唯一列的新栈,返回 true。
    @discardableResult
    public mutating func openRoot(_ kind: ColumnKind, sourceKey: String) -> Bool {
        if !columns.isEmpty, rootSourceKey == sourceKey {
            columns = []; rootSourceKey = nil
            return false
        }
        columns = [Column(id: bump(), kind: kind)]
        rootSourceKey = sourceKey
        return true
    }

    /// 点第 `i` 列里 id=`rowId` 的行:截断 `i` 之后所有列。
    /// - 该行原本已展开（同行其下有列）→ toggle 收回（截到 i + 清 selected,不追加）。
    /// - 否则 → 设第 i 列 selectedRowId=rowId + 追加 `kind` 为新列。
    public mutating func drillIn(fromColumnIndex i: Int, rowId: Int, into kind: ColumnKind) {
        guard i >= 0, i < columns.count else { return }
        let toggling = columns[i].selectedRowId == rowId && i + 1 < columns.count
        columns = Array(columns.prefix(i + 1))
        if toggling { columns[i].selectedRowId = nil; return }
        columns[i].selectedRowId = rowId
        columns.append(Column(id: bump(), kind: kind))
    }

    /// 已打开的 awaiting detail 列持有 item 快照；会话流 rebuild 后用同 id 新 awaiting item 替换，保证回答结果回填可见。
    public mutating func replaceDetailItem(_ item: ConversationItem, sourceKey: String) {
        guard rootSourceKey == sourceKey, case .awaiting = item.kind else { return }
        for idx in columns.indices {
            if case .detail(let old) = columns[idx].kind, old.id == item.id,
               case .awaiting = old.kind {
                columns[idx].kind = .detail(item: item)
            }
        }
    }

    public mutating func close() { columns = []; rootSourceKey = nil }

    private mutating func bump() -> Int { defer { nextId += 1 }; return nextId }
}
