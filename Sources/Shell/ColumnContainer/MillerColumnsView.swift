import AgentSensing
import SwiftUI

/// 列容器主视图：横向滚动平铺所有列，新列追加在右，自动滚到最新列（访达列视图语义）。
/// 超出窗口宽度 → 横滚可看更早的列。
///
/// 需 macOS 15（`scrollPosition(id:)` + `onChange` 新签名，项目基线已满足）。
@MainActor
struct MillerColumnsView: View {

    @ObservedObject var state: ColumnContainerState

    /// 当前滚动锚定的列 id（`.scrollPosition(id:)` 驱动）。
    @State private var scrolledColumnId: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                ForEach(state.stack.columns) { col in
                    let isRoot = col.id == state.stack.columns.first?.id
                    ColumnPaneView(
                        column: col,
                        isRoot: isRoot,
                        onRowDrillIn: { _, _ in },   // Task 7 wiring 接管
                        onClose: { state.close() },
                        onListRowTapped: { state.onListRowTapped?(col.id, $0) },
                        isPinned: state.isPinned,
                        onTogglePin: isRoot ? { state.onTogglePin?() } : nil   // 仅根列显置顶按钮
                    )
                    .id(col.id)
                    if col.id != state.stack.columns.last?.id { Divider() }   // 列间分隔;末列右侧不挂多余分隔线
                }
            }
        }
        .scrollPosition(id: $scrolledColumnId, anchor: .leading)
        .onChange(of: state.stack.columns.count) { _, _ in
            // 访达语义:drill-in 后保持「父列 + 新子列」这一对可见 —— 锚定**倒数第二列(父)**到 leading,
            // 子列在其右侧揭示(超屏则右裁,横滚补全)。避免锚最新列把父挤出去只剩一条缝(丢父子关系)。
            // 父列恒为 list(360,drill 都从列表行发起):360+list360=720 两列全显;360+detail520 父全显+子露 432
            // (diff 左侧重要部分);均优于旧版父被裁。仅 1 列(root)时锚它本身。
            let cols = state.stack.columns
            guard let targetId = cols.count >= 2 ? cols[cols.count - 2].id : cols.last?.id else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                scrolledColumnId = targetId
            }
        }
        .background(ChatCardTheme.cardBackground)
    }
}
