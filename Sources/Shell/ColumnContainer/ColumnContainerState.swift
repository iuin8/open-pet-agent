import AgentSensing
import Combine
import Foundation

/// 列容器状态：持有 `ColumnStack` 纯值栈，暴露 drill-in / 开根 / 关闭操作给 Controller 和 View。
///
/// `onListRowTapped` 由 wiring 层（Task 7）注入，负责把列表行映射成子列 `ColumnKind` 后调
/// `drillIn(columnId:rowId:into:)`。State 本身不知道映射逻辑。
@MainActor
public final class ColumnContainerState: ObservableObject {

    public init() {}

    /// 当前列栈（驱动 `MillerColumnsView` 重渲）。
    @Published public var stack = ColumnStack()

    /// 列表行点击回调：`(列 id, 被点击的 item)` → wiring 算 child kind → `drillIn`。
    public var onListRowTapped: ((_ columnId: Int, _ item: ConversationItem) -> Void)?

    /// 窗口**置顶**态(default off)—— 根列 header `CardPinButton` 绑定它显示;置顶 = 点主卡不 dismiss + 常驻浮顶。
    @Published public var isPinned = false
    /// 点根列置顶按钮 → Controller 注入(翻 `isPinned` + 应用 `WindowPinState`)。
    public var onTogglePin: (() -> Void)?

    // MARK: - 操作

    /// 从主卡某行打开根列。
    /// - Returns: `false` 表示同 sourceKey toggle 关闭（调用方据此 hide 面板）。
    @discardableResult
    public func openRoot(_ kind: ColumnKind, sourceKey: String) -> Bool {
        stack.openRoot(kind, sourceKey: sourceKey)
    }

    /// 将列 id 转换为栈内下标，再委托给 `ColumnStack.drillIn`。
    public func drillIn(columnId: Int, rowId: Int, into kind: ColumnKind) {
        guard let i = stack.columns.firstIndex(where: { $0.id == columnId }) else { return }
        stack.drillIn(fromColumnIndex: i, rowId: rowId, into: kind)
    }

    /// 会话流同源同 id item 刷新时，同步已打开 detail 列的 item 快照。
    public func replaceDetailItem(_ item: ConversationItem, sourceKey: String) {
        stack.replaceDetailItem(item, sourceKey: sourceKey)
    }

    /// 清栈并关闭容器。
    public func close() {
        stack.close()
    }
}
