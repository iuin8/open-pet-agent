import AgentSensing
import AppKit
import SwiftUI

/// 会话流的**滚动容器**:用 AppKit `NSTableView`(包进 `NSViewRepresentable`)替掉 SwiftUI `ScrollView`。
///
/// **为什么换地基**(lessons §5.11):SwiftUI `ScrollView`+`scrollPosition`/`onScrollGeometryChange` 做
/// 「滚到顶加载更早 + prepend 视口不跳 + 仅停底跟随」是 Apple 官方都未解决的(开发者论坛 thread 799521
/// 「无像素级精度」),手搓反复死锁/无限滚/冻死(6 次)。`NSTableView` 是 30 年成熟原语(Mail/iTerm2 同款):
/// `insertRows`/`reloadData` + 存恢复 scroll origin = **原子的「插入老消息不跳」**,正是 SwiftUI 缺的那一步。
///
/// **行渲染零改动**:每行 = `NSHostingView(rootView: AgentConversationRow(...))`,富行(气泡/工具卡/diff/
/// 展开/侧卡/待答)原样托管。**数据层(store/游标/readWindow)全保留**,只换容器。
///
/// 机制:
/// - **变高行**:显式 `heightOfRow` 同步测量(离屏 `NSHostingView.fittingSize`)+ 按 id+签名缓存 → 几何确定、
///   `rect(ofRow:)` 像素级准 → 锚点恢复精确(自动行高的惰性/估算会让锚点恢复不准,故弃用)。
/// - **每次更新** = `reloadData` + **锚点恢复**(钉住视口顶那条 item)/ 仅「本就在底 且 末条变了」才跟随到底。
/// - **到顶加载** = `NSScrollView` `boundsDidChange`(可靠滚动事件)→ 距顶 ≤ margin 触发;程序化滚动期间屏蔽;
///   store 内 `!isLoadingEarlier && canLoadEarlier` 幂等 + `reachedStart` 兜底 → 不死锁、不无限。
struct TranscriptListView: NSViewRepresentable {
    let items: [ConversationItem]
    let highlightedItemId: Int?
    /// 高亮子区(配合 highlightedItemId,区分点的是总结还是元数据栏)。子 agent 卡静态流默认 .primary。
    var highlightedRegion: RowHighlightRegion = .primary
    let canLoadEarlier: Bool
    let isLoadingEarlier: Bool
    let showCodexHint: Bool
    /// 当前选中会话 id —— 协调器据此判「切会话」(整表重建 + 到底);同会话只增量更新不跳。
    /// 子 agent 卡的静态 transcript 传 nil(首帧 oldRows.isEmpty 即到底,之后无更新)。
    var sessionId: String? = nil

    /// 点有详情的行 → 弹侧卡(2026-06-16:所有详情统一走侧卡,无内联展开)。App 未注入 → nil,行不可点。
    let onExpandToSide: ((ConversationItem) -> Void)?
    let onLoadEarlierTap: () -> Void
    let onReachTop: () -> Void
    /// 高亮行的 top-down 窗口 midY 回调(协调器用 `rect(ofRow:)` 算)→ 写回 store.highlightedRowMidY,
    /// 供侧卡/权限卡 beak 对准源行(NSTableView 容器里 SwiftUI preference 跨不过边界,必走这条)。
    var onHighlightedRowMidY: ((CGFloat) -> Void)? = nil
    /// 高亮行屏幕矩形(逐帧滚动广播)→ 侧卡连接线源端跟随行(#3)。
    var onHighlightedRowRect: ((NSRect?) -> Void)? = nil
    /// D2:item.id → 子 agent(MainActor 侧据 store 索引预算)。命中的 Task 行挂「子 agent」入口。
    var subagentByItemId: [Int: SubagentRef] = [:]
    /// D2:点子 agent 入口 → 弹子 agent 侧卡。
    var onOpenSubagent: ((ConversationItem) -> Void)? = nil
    /// 点模型一轮元数据栏 → 弹「元数据行」侧卡(思考/工具)。
    var onOpenTurnSteps: ((ConversationItem) -> Void)? = nil
    /// 点 workflow 🧩 → 开 workflow 衍生 agent 列表卡(#9)。参数 = run id。
    var onOpenWorkflow: ((String) -> Void)? = nil
    /// #2:点会话流空白处(消息行下方 / 边距,非任何行)→ 关所有未钉住侧卡。App 未注入 → nil 不响应。
    var onBackgroundClick: (() -> Void)? = nil
    /// P1-5:点用户行图片缩略图 → 开图片侧卡。
    var onOpenImage: ((ImageAttachment) -> Void)? = nil

    /// 距视口顶 ≤ 此值(pt)即触发加载更早(预加载提前量)。
    static let loadEarlierMargin: CGFloat = 120
    /// 行间距(对齐旧 LazyVStack 的 spacing: 8)。
    static let interRowSpacing: CGFloat = 8

    func makeCoordinator() -> TranscriptListCoordinator { TranscriptListCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.onReachTop = onReachTop

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.usesAutomaticRowHeights = false   // 显式 heightOfRow → 几何确定(见类型注释)
        table.intercellSpacing = NSSize(width: 0, height: Self.interRowSpacing)
        table.gridStyleMask = []
        let column = NSTableColumn(identifier: .transcriptColumn)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = coordinator
        table.delegate = coordinator

        let scroll = TranscriptScrollView()
        scroll.onBackgroundClick = onBackgroundClick   // #2:点空白(行下方/边距,行与表消费各自点击 → 不触发)→ 关侧卡
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.interRowSpacing, left: 0, bottom: Self.interRowSpacing, right: 0)

        coordinator.attach(table: table, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll as? TranscriptScrollView)?.onBackgroundClick = onBackgroundClick   // 闭包随 store 注入刷新
        let coordinator = context.coordinator
        coordinator.onReachTop = onReachTop
        coordinator.onHighlightedRowMidY = onHighlightedRowMidY
        coordinator.onHighlightedRowRect = onHighlightedRowRect
        coordinator.builder = TranscriptRowBuilder(
            onExpandToSide: onExpandToSide, onLoadEarlierTap: onLoadEarlierTap,
            onOpenSubagent: onOpenSubagent, onOpenTurnSteps: onOpenTurnSteps,
            onOpenWorkflow: onOpenWorkflow, onOpenImage: onOpenImage
        )
        let rows = TranscriptRowBuilder.rows(
            items: items, highlightedItemId: highlightedItemId, highlightedRegion: highlightedRegion,
            canLoadEarlier: canLoadEarlier, isLoadingEarlier: isLoadingEarlier,
            showCodexHint: showCodexHint, subagentByItemId: subagentByItemId
        )
        coordinator.apply(rows: rows, sessionId: sessionId)
    }
}

extension NSUserInterfaceItemIdentifier {
    static let transcriptColumn = NSUserInterfaceItemIdentifier("transcript.column")
    static let transcriptRow = NSUserInterfaceItemIdentifier("transcript.row")
}

/// 会话流滚动容器 —— 为「点 chat 卡任意处关侧卡」子类化。
/// 详情/交互一律走行内 `Button`(展开总结/元数据栏/子agent/workflow/复制/图片/加载更早),**Button 自己消费
/// 点击 → 不到这个 `mouseDown`**;落到 scroll 自身的 mouseDown = 点在空白 或 无详情的普通行 = 用户「想关侧卡」。
/// 故**任何到达此处的点击都关侧卡**(详情按钮点击不会到达 → 照常开/切侧卡),天然区分「关」vs「开/切」,
/// 无 NSEvent 全局监听的 mouseDown-先-mouseUp-后竞态。
final class TranscriptScrollView: NSScrollView {
    var onBackgroundClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()   // 到达此处 = 未被任何行内 Button 消费(空白/普通行)→ 关侧卡(「任意处关」)
        super.mouseDown(with: event)
    }
}

// MARK: - 行模型(纯数据,可单测构建)

/// 表里的一行 —— item 之外还有顶部「加载更早」按钮、底部 Codex 提示。
/// (权限/问题待答**不再内联**,改 pet 旁权限侧卡堆叠展示,2026-06-16。)
struct TranscriptRow {
    enum Kind {
        case loadEarlier
        case item(ConversationItem)
        case codexHint
    }
    let kind: Kind
    /// 该行被高亮查看的**子区**(.primary 主内容 / .metadata 元数据栏);nil = 未高亮。
    let highlightRegion: RowHighlightRegion?
    let loading: Bool
    /// D2:该 item 行关联的子 agent(命中则行下挂「子 agent」入口,**影响行高** → 计入 heightSignature)。
    let subagent: SubagentRef?

    /// 该行是否被高亮(供协调器 `rect(ofRow:)` 找高亮行算 midY)。
    var highlighted: Bool { highlightRegion != nil }

    /// 稳定身份(锚点匹配 / 高度缓存键)。item 用其 id;特殊行用负哨兵(不与 item id ≥0 冲突)。
    var id: Int {
        switch kind {
        case .loadEarlier: return -1
        case .item(let it): return it.id
        case .codexHint: return -3
        }
    }

    /// 高度签名 —— 渲染高度可能变化时改变(高亮是 overlay 不影响高度,故不计入)。子 agent 入口出现 → 行变高 → 入签名。
    var heightSignature: String {
        switch kind {
        case .loadEarlier: return "load:\(loading)"
        case .item(let it): return "item:\(it.id):\(itemContentToken(it)):\(actionHeightToken(it))"
        case .codexHint: return "codex"
        }
    }

    /// 视图签名 —— 影响**渲染**(不止高度)的变化:高度签名 + 高亮子区(halo overlay)。`refreshChangedRows` 用它判断要不要刷该行。
    /// **必须计入子区**:否则点元数据栏↔总结切换(同 item 同高度,仅子区变)NSTableView 不会重画该行(§5.11)。
    var renderSignature: String {
        let h: String
        switch highlightRegion {
        case .none: h = "|_"
        case .primary: h = "|Hp"
        case .metadata: h = "|Hm"
        }
        return heightSignature + h
    }

    private var actionHeightToken: Int {
        guard case .item(let it) = kind else { return 0 }
        return actionHeightToken(it)
    }

    private func actionHeightToken(_ it: ConversationItem) -> Int {
        guard case .tool = it.kind else { return 0 }
        return (subagent == nil ? 0 : 1) &+ (it.workflowRunId == nil ? 0 : 2)
    }

    /// 影响渲染的内容指纹(Int,廉价)。供 `Equatable` 短路用 —— 与 `heightSignature` 同源但免每次拼串。
    var contentToken: Int {
        switch kind {
        case .loadEarlier: return loading ? 1 : 0
        case .item(let it): return itemContentToken(it)
        case .codexHint: return 0
        }
    }

    private func itemContentToken(_ it: ConversationItem) -> Int {
        switch it.kind {
        case .user(let t):   // 行高随文字 + 缩略图条(P1-5:有图行更高,签名须含附件数)
            return t.count &+ it.attachments.count &* 7_777
        case .assistant(let t), .thinking(let t): return t.count
        case .tool(let n, let s, let st, let i, let o):
            return n.count &+ s.count &* 31 &+ (i?.count ?? 0) &* 131 &+ (o?.count ?? 0) &* 1301 &+ st.hashValue
        case .awaiting: return 7
        case .compactBoundary: return 3   // 固定矮分割线行,内容恒定
        case .assistantTurn(let a):   // 行高随:元数据栏(计数/ctx)+ 最终文字长度 + running/error/中断
            return a.finalText.count &+ a.toolCount &* 7 &+ a.thinkingCount &* 13
                &+ (a.contextTokens ?? 0) &+ (a.isRunning ? 1 : 0) &+ (a.hasError ? 2 : 0)
                &+ (a.wasInterrupted ? 4 : 0)
        }
    }
}

extension ConversationItem.ToolState {
    var hashValue: Int { switch self { case .running: return 1; case .ok: return 2; case .error: return 3 } }
}

extension TranscriptRow: Equatable {
    /// **廉价**比较:只看影响渲染的字段(id / loading / 高亮子区 / subagent 有无 / 内容指纹 Int),
    /// **绝不比 `ConversationItem` 内容或图片字节**(§6.2:重数据旁挂字段配廉价 Equatable,否则 diff 热路径被拖垮)。
    /// 语义对齐 `renderSignature`,供 `TranscriptListCoordinator.apply` 在「行未变」时零成本早退(§6.6 根因:越跑越高)。
    static func == (l: TranscriptRow, r: TranscriptRow) -> Bool {
        l.id == r.id
            && l.loading == r.loading
            && l.highlightRegion == r.highlightRegion
            && l.actionHeightToken == r.actionHeightToken
            && l.contentToken == r.contentToken
    }
}

/// 行 → SwiftUI 视图的构建器(测量与显示共用同一份 → 高度一致)。
@MainActor
struct TranscriptRowBuilder {
    let onExpandToSide: ((ConversationItem) -> Void)?
    let onLoadEarlierTap: () -> Void
    /// D2:点 Task/Agent 行的「子 agent」入口 → 弹子 agent 侧卡。
    let onOpenSubagent: ((ConversationItem) -> Void)?
    /// 点模型一轮的元数据栏 → 弹「元数据行」侧卡(思考/工具,不含总结)。
    let onOpenTurnSteps: ((ConversationItem) -> Void)?
    /// 点 workflow 🧩 → 开 workflow 衍生 agent 列表卡(#9)。参数 = run id。
    let onOpenWorkflow: ((String) -> Void)?
    /// P1-5:点用户行图片缩略图 → 开图片侧卡。参数 = 被点附件。
    let onOpenImage: ((ImageAttachment) -> Void)?

    init(onExpandToSide: ((ConversationItem) -> Void)? = nil,
         onLoadEarlierTap: @escaping () -> Void = {},
         onOpenSubagent: ((ConversationItem) -> Void)? = nil,
         onOpenTurnSteps: ((ConversationItem) -> Void)? = nil,
         onOpenWorkflow: ((String) -> Void)? = nil,
         onOpenImage: ((ImageAttachment) -> Void)? = nil) {
        self.onExpandToSide = onExpandToSide
        self.onLoadEarlierTap = onLoadEarlierTap
        self.onOpenSubagent = onOpenSubagent
        self.onOpenTurnSteps = onOpenTurnSteps
        self.onOpenWorkflow = onOpenWorkflow
        self.onOpenImage = onOpenImage
    }

    /// 组装一帧的行序列:[加载更早?] + items + [Codex 提示?]。纯函数 → 可单测(nonisolated)。
    /// `subagentByItemId`:item.id → 子 agent(MainActor 侧据 store 索引预算,传纯数据进来,使本函数仍 nonisolated)。
    /// (权限/问题待答不再在此 —— 改 pet 旁权限侧卡。)
    nonisolated static func rows(
        items: [ConversationItem], highlightedItemId: Int?, highlightedRegion: RowHighlightRegion = .primary,
        canLoadEarlier: Bool, isLoadingEarlier: Bool, showCodexHint: Bool,
        subagentByItemId: [Int: SubagentRef] = [:]
    ) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        if canLoadEarlier {
            rows.append(TranscriptRow(kind: .loadEarlier, highlightRegion: nil, loading: isLoadingEarlier, subagent: nil))
        }
        for it in items {
            rows.append(TranscriptRow(kind: .item(it),
                                      highlightRegion: highlightedItemId == it.id ? highlightedRegion : nil, loading: false,
                                      subagent: subagentByItemId[it.id]))
        }
        if showCodexHint {
            rows.append(TranscriptRow(kind: .codexHint, highlightRegion: nil, loading: false, subagent: nil))
        }
        return rows
    }

    /// 单行视图。`measuring` 时强制 highlighted=false(避免离屏 HaloRing 动画;halo 是 overlay,高度一致)。
    @ViewBuilder
    func view(for row: TranscriptRow, measuring: Bool) -> some View {
        switch row.kind {
        case .loadEarlier:
            loadEarlierButton(loading: row.loading)
        case .item(let it):
            AgentConversationRow(
                item: it,
                highlightRegion: measuring ? nil : row.highlightRegion,
                onExpandToSide: onExpandToSide.map { f in { f(it) } },
                subagentRef: row.subagent,
                onOpenSubagent: (row.subagent != nil && onOpenSubagent != nil) ? { onOpenSubagent?(it) } : nil,
                onOpenTurnSteps: onOpenTurnSteps.map { f in { f(it) } },
                onOpenWorkflow: onOpenWorkflow,
                onOpenImage: onOpenImage
            )
            .padding(.horizontal, 12)
        case .codexHint:
            codexHint.padding(.horizontal, 12)
        }
    }

    private func loadEarlierButton(loading: Bool) -> some View {
        Button(action: onLoadEarlierTap) {
            HStack(spacing: 5) {
                if loading {
                    ProgressView().controlSize(.mini)
                    Text("加载中…").font(.system(size: 11, weight: .medium, design: .rounded))
                } else {
                    Image(systemName: "arrow.up.circle").font(.system(size: 11, weight: .semibold))
                    Text("加载更早消息").font(.system(size: 11, weight: .medium, design: .rounded))
                }
            }
            .foregroundStyle(ChatCardTheme.accent.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Capsule().fill(ChatCardTheme.accent.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    private var codexHint: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 11))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.5))
                .frame(width: 13, height: 16)
            Text("Codex 无后台写回 —— 请在终端回答")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(ChatCardTheme.textPrimary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(ChatCardTheme.hairline, lineWidth: 0.5)
                )
        )
    }
}
