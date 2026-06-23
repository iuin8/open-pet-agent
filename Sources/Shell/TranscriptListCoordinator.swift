import AgentSensing
import AppKit
import SwiftUI

/// `TranscriptListView` 的 datasource/delegate + 滚动协调器。见 `TranscriptListView` 类型注释的机制说明。
/// `@MainActor`:所有 NSTableView 回调/通知都在主线程,且要引用 `@MainActor` 的 `ChatCardTheme`。
@MainActor
final class TranscriptListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private weak var table: NSTableView?
    private weak var scroll: NSScrollView?

    private(set) var rows: [TranscriptRow] = []
    var builder = TranscriptRowBuilder()
    var onReachTop: () -> Void = {}
    /// 高亮行的 **top-down 窗口 midY**(对齐旧 `.global` preference 语义,= `cardFrame.height - 底→上 midY`)。
    /// **必经此路**:NSTableView 重写后行是独立 `NSHostingView`,SwiftUI preference 跨不过容器边界,改由
    /// 协调器用 `rect(ofRow:)`(可靠几何)算 → 供侧卡/权限卡 beak 精确对准源行 Y。仅有高亮行时回调(不清零,免双 tab 互踩)。
    var onHighlightedRowMidY: ((CGFloat) -> Void)?
    /// 高亮行的当前**屏幕矩形**(Y-up;无高亮 / 行滚出可视区 → nil)→ 供侧卡连接线源端跟随行(#3)。
    /// 逐帧滚动(boundsDidChange)+ apply 后广播;纯读 `rect(ofRow:)`+`convert`,**绝不**触发 load/scroll。
    var onHighlightedRowRect: ((NSRect?) -> Void)?

    /// 高度缓存:id → (签名, 高度)。签名变(展开/内容/宽度)即失效重测。
    private var heightCache: [Int: (sig: String, h: CGFloat)] = [:]
    private var lastMeasureWidth: CGFloat = 0
    /// 上次 apply 的会话 id —— 与本次不同 = 切会话(整表重建);**用显式 id 判定取代 diff 形状猜测**(§5.11)。
    private var lastSessionId: String?
    /// **每会话滚动位置存档**(sessionId → 视口顶锚行)—— 切走时存、切回时恢复 → 「上次看到哪」不丢(claude-devtools 同款)。
    /// 切回若锚行不在(首次/重置/锚行已滚出当前窗)→ 回退到底。
    private var savedScroll: [String: RowAnchor] = [:]
    /// 离屏测量宿主(复用,免每次分配)。
    private let measuringHost = NSHostingView(rootView: AnyView(EmptyView()))

    /// 调试(env `PETAGENT_DEBUG_SCROLLJIT`):prepend 后量「锚行落点 delta + 逐行缓存测高 vs 真实列宽现场测高 +
    /// measureWidth vs 真实列宽」→ 实锤抖动主因(H1 测高累积 / H3 触顶 clamp)。纯只读 NSLog,零行为改动。
    private static let debugScrollJit = ProcessInfo.processInfo.environment["PETAGENT_DEBUG_SCROLLJIT"] != nil

    func attach(table: NSTableView, scroll: NSScrollView) {
        self.table = table
        self.scroll = scroll
        // **只在用户主动滚动时检测到顶 → 加载更早**:`willStart/didLiveScroll` 仅用户手势(滚轮/触控板)才发,
        // 内容变化(live 事件 insertRows)/ 程序化补偿滚动**不发** liveScroll → 不会被误判成「用户滚到顶」而自动加载
        // (根治:之前用 `boundsDidChange` 会被 live 事件的 insertRows 误触发 → 触顶自动上滚)。
        for name in [NSScrollView.willStartLiveScrollNotification,
                     NSScrollView.didLiveScrollNotification,
                     NSScrollView.didEndLiveScrollNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(userDidLiveScroll), name: name, object: scroll)
        }
        // #3 连接线:订阅逐帧滚动(含惯性/程序化补偿)→ **只读**广播高亮行屏幕矩形。**独立 selector**,
        // 绝不调 onReachTop/scroll/reloadData(boundsDidChange 当年因触发 load 被弃;此处仅读几何重画线,无此风险,§5.11)。
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(highlightedRowGeometryChanged),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - DataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let host = (tableView.makeView(withIdentifier: .transcriptRow, owner: self) as? RowHostingView) ?? {
            let v = RowHostingView()
            v.identifier = .transcriptRow
            return v
        }()
        host.configure(AnyView(builder.view(for: rows[row], measuring: false)))
        return host
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        let r = rows[row]
        let sig = r.heightSignature
        if let cached = heightCache[r.id], cached.sig == sig { return cached.h }
        let h = max(1, measure(r, width: measureWidth(tableView)))
        heightCache[r.id] = (sig, h)
        return h
    }

    /// 不要行选中(会话流是只读流,选中高亮多余)。
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: - 应用一帧:reloadData + 锚点恢复 / 跟随到底

    func apply(rows newRows: [TranscriptRow], sessionId: String?) {
        guard let table, let scroll else { rows = newRows; return }

        // 宽度变了(卡片定宽,理论上不变)→ 高度缓存全失效。
        let width = measureWidth(table)
        if width != lastMeasureWidth { heightCache.removeAll(); lastMeasureWidth = width }

        let oldRows = rows
        let clip = scroll.contentView
        let oldOrigin = clip.bounds.origin
        let oldHeight = table.frame.height
        // 变更**前**测「是否贴底」(纳入底 contentInset + 放宽容差,流式刚追加一行时 maxY 短暂落后,4pt 太紧会漏跟随)。
        let atBottom = isAtBottom(table: table, scroll: scroll, oldRowsEmpty: oldRows.isEmpty)
        // 变更**前**锚定「视口顶第一条真实内容行」(跳过哨兵)+ 其相对 clip 的偏移 → 变更后摆回原位(对 refresh 污染免疫)。
        let anchor = captureAnchor(table: table, clip: clip, oldRows: oldRows)

        // **会话切换用显式 sessionId 判定**(不再靠 diff 形状猜「整体换」——那会把「顶部按钮移除 + prepend 同帧」
        // 误判成切换 → reloadData+到底,即「上滑莫名回弹到底」根因,§5.11)。仅首帧/真切会话才整表重建。
        let previousSessionId = lastSessionId
        let switchedSession = (sessionId != nil && sessionId != previousSessionId)   // 真切会话(非首帧/重置)
        let isSessionSwitch = oldRows.isEmpty || switchedSession
        lastSessionId = sessionId

        // 结构 diff(纯函数,按稳定 id 求公共前/后缀)→ 中段增删量 + 尾部是否变化。
        let diff = RowDiff.classify(oldIds: oldRows.map(\.id), newIds: newRows.map(\.id))

        rows = newRows
        pruneHeightCache()

        if isSessionSwitch {
            // 切走旧会话 → 存其滚动位置(变更前 oldRows + 当前滚动算的锚)。
            if switchedSession, let prev = previousSessionId, let a = anchor { savedScroll[prev] = a }
            table.reloadData()
            table.layoutSubtreeIfNeeded()
            // 切回**有存档且锚行还在** → 恢复上次看到的位置;否则(首次/重置/锚行不在当前窗)→ 到底看最新。
            if switchedSession, let sid = sessionId, let saved = savedScroll[sid],
               rows.contains(where: { $0.id == saved.id }) {
                scrollToAnchor(saved)
            } else {
                scrollToBottom()
            }
            reportHighlightedRowMidY()
            return
        }

        // 结构增删(prepend/append / 顶部「加载更早」按钮增删)→ insertRows/removeRows(非 reloadData → 零闪,
        // 参考 MantleData / SO #41965201)。**不再**因 diff 形状走 reloadData+到底。
        if diff.oldMid > 0 || diff.newMid > 0 {
            table.beginUpdates()
            if diff.oldMid > 0 { table.removeRows(at: IndexSet(integersIn: diff.prefix ..< diff.prefix + diff.oldMid), withAnimation: []) }
            if diff.newMid > 0 { table.insertRows(at: IndexSet(integersIn: diff.prefix ..< diff.prefix + diff.newMid), withAnimation: []) }
            table.endUpdates()
        }
        // 公共区里内容/高度变了的行(展开 / 加载态 / 高亮 / 运行中轮次增长)→ 只刷那几行。
        refreshChangedRows(oldRows: oldRows, newRows: newRows, table: table)
        table.layoutSubtreeIfNeeded()

        // **滚动决策(数据与滚动正交)**:仅当「变化触及尾部(suffix==0)且本就贴底」才跟随到底
        //(含运行中轮次增长 at-bottom 跟随 —— 修旧 refreshChangedRows 不跟随缺陷);
        // 其余一律把锚行摆回原屏幕位置 → 视口纹丝不动(prepend / 中段 / 顶部按钮增删 / 读历史时尾部追加 / 上方行变高)。
        // **绝不在此处自动续读**:加载只由用户主动滚动驱动(`userDidLiveScroll`),否则触顶自动上滚(§5.10/§5.11 反复栽)。
        if atBottom && diff.changeAtBottom {
            scrollToBottom()
        } else {
            restoreAnchor(anchor, table: table, scroll: scroll, oldOrigin: oldOrigin, oldHeight: oldHeight)
        }
        if Self.debugScrollJit, diff.newMid > 0, !diff.changeAtBottom {   // prepend(顶部插入)→ 量抖动根因
            debugLogScrollJitter(anchor: anchor, diff: diff, table: table, scroll: scroll)
        }
        reportHighlightedRowMidY()
    }

    /// prepend 后实测:① measureWidth vs 真实列宽差(H1 宽度漂移源);② 前几条新插入行的缓存测高 vs 真实列宽现场测高
    /// (逐行 delta 累加 = 锚偏);③ 下一拍重测锚行实际 offsetInClip vs 期望(delta≈0 排除 H1 转查 H2/H3;delta 大 = 实锤)。
    private func debugLogScrollJitter(anchor: RowAnchor?, diff: RowDiff, table: NSTableView, scroll: NSScrollView) {
        let mw = measureWidth(table)
        let colW = table.rect(ofRow: 0).width
        NSLog("[SCROLLJIT] prepend newMid=\(diff.newMid) prefix=\(diff.prefix) measureWidth=\(String(format: "%.1f", mw)) colW=\(String(format: "%.1f", colW)) widthDelta=\(String(format: "%.2f", mw - colW))")
        var accum: CGFloat = 0
        for idx in diff.prefix ..< min(diff.prefix + diff.newMid, rows.count) where idx - diff.prefix < 6 {
            let r = rows[idx]
            let cached = heightCache[r.id]?.h ?? -1
            let fresh = measure(r, width: colW)   // 用真实列宽现场测
            accum += (cached - fresh)
            NSLog("[SCROLLJIT]   row#\(idx) id=\(r.id) cachedH=\(String(format: "%.1f", cached)) freshH@colW=\(String(format: "%.1f", fresh)) rowDelta=\(String(format: "%.2f", cached - fresh)) accum=\(String(format: "%.2f", accum))")
        }
        guard let anchor else { NSLog("[SCROLLJIT] anchor=nil(无内容行可锚)"); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let table = self.table, let scroll = self.scroll,
                  let newIdx = self.rows.firstIndex(where: { $0.id == anchor.id }) else { return }
            let actual = table.rect(ofRow: newIdx).minY - scroll.contentView.bounds.origin.y
            let landDelta = actual - anchor.offsetInClip
            NSLog("[SCROLLJIT] ANCHOR id=\(anchor.id) expectedOffset=\(String(format: "%.1f", anchor.offsetInClip)) actualOffset=\(String(format: "%.1f", actual)) landDelta=\(String(format: "%.2f", landDelta)) ← 抖动量(px)")
        }
    }

    /// 算高亮行的 top-down 窗口 midY → 回调(供侧卡/权限卡 beak 对准源行)。布局后下一拍跑(几何已定)。
    /// **async 块内重新查 idx**(同步阶段取的 idx 在 prepend 后会指向漂移的行)+ 必有 window(无则跳,bounds 基不匹配)。
    private func reportHighlightedRowMidY() {
        let hasHighlight = rows.contains(where: { $0.highlighted })
        if !hasHighlight { onHighlightedRowRect?(nil) }   // 无高亮 → 收连接线
        guard onHighlightedRowMidY != nil || onHighlightedRowRect != nil, hasHighlight else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let table = self.table, let window = table.window,
                  let idx = self.rows.firstIndex(where: { $0.highlighted }) else { return }
            let inWindow = table.convert(table.rect(ofRow: idx), to: nil)   // 窗口 base 坐标(AppKit 下→上)
            self.onHighlightedRowMidY?(window.frame.height - inWindow.midY) // → top-down(对齐旧 preference 语义)
            self.onHighlightedRowRect?(self.currentHighlightedRowScreenRect())   // #3:连接线源端跟随行
        }
    }

    /// 逐帧滚动时只读广播高亮行屏幕矩形(无监听 → 零成本)。**绝不**触发 load/scroll/reload。
    @objc private func highlightedRowGeometryChanged() {
        guard onHighlightedRowRect != nil else { return }
        onHighlightedRowRect?(currentHighlightedRowScreenRect())
    }

    /// 高亮行当前屏幕矩形(Y-up);无高亮 / 行完全滚出可视区 → nil。纯读,不改任何状态。
    private func currentHighlightedRowScreenRect() -> NSRect? {
        guard let table, let window = table.window,
              let idx = rows.firstIndex(where: { $0.highlighted }) else { return nil }
        let rowRect = table.rect(ofRow: idx)
        guard table.visibleRect.intersects(rowRect) else { return nil }   // 行完全滚出 → nil(连接线暂收)
        let inWindow = table.convert(rowRect, to: nil)
        return window.convertToScreen(inWindow)
    }

    /// 刷新公共区里 `renderSignature` 变了的行(展开 / 加载更早↔加载中 / 高亮)→ 重测高度 + reload 那几行,**不动滚动**。
    private func refreshChangedRows(oldRows: [TranscriptRow], newRows: [TranscriptRow], table: NSTableView) {
        var oldSig: [Int: String] = [:]
        for r in oldRows { oldSig[r.id] = r.renderSignature }
        var changed = IndexSet()
        for (i, r) in newRows.enumerated() where oldSig[r.id].map({ $0 != r.renderSignature }) ?? false {
            changed.insert(i)
        }
        guard !changed.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0   // 不动画高度变化,免「抖一下」
            table.noteHeightOfRows(withIndexesChanged: changed)
        }
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
    }

    // MARK: - 滚动(贴底检测 / 锚点恢复 / 到底,全程禁隐式动画去抖)

    /// 贴底检测:可见矩形底沿(算上底 contentInset)触及文档底,容差放宽到约一行半
    ///(流式追加瞬间 maxY 短暂落后一行,4pt 太紧会判「没贴底」→ 漏跟随;Telegram/iTerm2 容差皆按行高量级)。
    private func isAtBottom(table: NSTableView, scroll: NSScrollView, oldRowsEmpty: Bool) -> Bool {
        if oldRowsEmpty { return true }
        let visibleMaxY = scroll.contentView.documentVisibleRect.maxY
        let tolerance = scroll.contentInsets.bottom + 24
        return visibleMaxY >= table.frame.height - tolerance
    }

    /// 锚:视口顶第一条**真实内容行**(跳过 id<0 的哨兵:加载更早 / codex 提示)+ 其顶相对 clip 原点的偏移。
    /// 哨兵恒在第 0 行,prepend 后被推走,锚它=丢位置(§5.11 坑)→ 必须锚真实内容行。
    private func captureAnchor(table: NSTableView, clip: NSClipView, oldRows: [TranscriptRow]) -> RowAnchor? {
        // 顶部 `contentInsets.top`(8)使滚到顶时 `visMinY≈-8` → `visMinY+2=-6` 落进 inset 间隙 → `row(at:)=-1`
        // → 锚失效 → 落 fallback 跳变。而 load-earlier **恰在触顶触发**(margin 120) → 锚在最需要时反而总失效。
        // clamp 探针 Y 到 ≥2(进首行) → 触顶也能锚到首条真实行(实测此路 landDelta=0,根治抖动)。
        let visMinY = clip.documentVisibleRect.minY
        let rawIdx = table.row(at: NSPoint(x: 4, y: max(visMinY + 2, 2)))
        var idx = rawIdx
        while idx >= 0, idx < oldRows.count, oldRows[idx].id < 0 { idx += 1 }   // 跳过哨兵
        if Self.debugScrollJit {
            NSLog("[SCROLLJIT] captureAnchor visMinY=\(String(format: "%.1f", visMinY)) rawRow(at:)=\(rawIdx) skippedTo=\(idx) oldRows=\(oldRows.count) docVisH=\(String(format: "%.1f", clip.documentVisibleRect.height))")
        }
        guard idx >= 0, idx < oldRows.count else { return nil }
        return RowAnchor(id: oldRows[idx].id, offsetInClip: table.rect(ofRow: idx).minY - clip.bounds.origin.y)
    }

    /// 把锚行摆回它变更前的屏幕位置 → 视口内容像素级不动(对 prepend/refresh 同帧污染免疫,Telegram saveScrollState 范式)。
    /// 锚失效(无内容行可锚)→ 兜底退回 content-height-delta 补偿(SO #41965201)。
    private func restoreAnchor(_ anchor: RowAnchor?, table: NSTableView, scroll: NSScrollView, oldOrigin: NSPoint, oldHeight: CGFloat) {
        if let anchor, rows.contains(where: { $0.id == anchor.id }) {
            scrollToAnchor(anchor)
        } else {
            let dy = table.frame.height - oldHeight
            var o = oldOrigin; o.y = max(0, o.y + dy)
            if Self.debugScrollJit {
                NSLog("[SCROLLJIT] restore-FALLBACK(anchor 失效) oldOrigin.y=\(String(format: "%.1f", oldOrigin.y)) dy(newH-oldH)=\(String(format: "%.1f", dy)) → newOrigin.y=\(String(format: "%.1f", o.y))")
            }
            setScrollOrigin(o)
        }
    }

    /// 滚到「锚行回到其存档的视口偏移」—— prepend 锚点恢复 + 切会话恢复上次位置共用(单一真相)。
    private func scrollToAnchor(_ anchor: RowAnchor) {
        guard let table, let scroll, let idx = rows.firstIndex(where: { $0.id == anchor.id }) else { return }
        let newRowMinY = table.rect(ofRow: idx).minY
        var o = scroll.contentView.bounds.origin
        o.y = max(0, newRowMinY - anchor.offsetInClip)
        setScrollOrigin(o)
    }

    private func scrollToBottom() {
        guard let table, let scroll, !rows.isEmpty else { return }
        let clip = scroll.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height + scroll.contentInsets.bottom)
        setScrollOrigin(NSPoint(x: clip.bounds.origin.x, y: maxY))
    }

    /// 设 clip 原点 + 反射,全程 `CATransaction.setDisableActions` 禁隐式动画 → 去掉补偿/到底的「抖一下」。
    private func setScrollOrigin(_ o: NSPoint) {
        guard let scroll else { return }
        let clip = scroll.contentView
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.scroll(to: o)
        scroll.reflectScrolledClipView(clip)
        CATransaction.commit()
    }

    // MARK: - 到顶检测(NSScrollView 可靠滚动事件)

    @objc private func userDidLiveScroll() {
        maybeTriggerLoadAtTop()
    }

    private func maybeTriggerLoadAtTop() {
        guard let table else { return }
        if table.visibleRect.minY <= TranscriptListView.loadEarlierMargin { onReachTop() }
    }

    // MARK: - 测量

    private func measureWidth(_ table: NSTableView) -> CGFloat {
        let w = scroll?.contentView.bounds.width ?? table.bounds.width
        return w > 1 ? w : ChatCardTheme.cardWidth - 24   // 首帧未布局兜底
    }

    private func measure(_ row: TranscriptRow, width: CGFloat) -> CGFloat {
        measuringHost.rootView = AnyView(builder.view(for: row, measuring: true).frame(width: width))
        measuringHost.layoutSubtreeIfNeeded()
        return measuringHost.fittingSize.height
    }

    /// 丢弃已不在当前行集里的高度缓存条目(id 稳定且有界,顺手清理防长期累积)。
    private func pruneHeightCache() {
        let live = Set(rows.map(\.id))
        heightCache = heightCache.filter { live.contains($0.key) }
    }
}

// MARK: - 滚动锚 / 行 diff(纯值类型,可无头单测)

/// 锚行:稳定 id + 其顶相对 clip 原点的偏移。变更后据此把锚行摆回原屏幕位置(视口不动)。
struct RowAnchor: Equatable {
    let id: Int
    let offsetInClip: CGFloat
}

/// 行序列结构 diff 分类(纯函数 → 可无头单测)。按稳定 id 求公共前缀/后缀,推出中段增删量。
struct RowDiff: Equatable {
    let prefix: Int
    let suffix: Int
    let oldMid: Int
    let newMid: Int
    /// 变化是否触及尾部(无稳定后缀)→ 追加 / 末行变化;用于「仅贴底才跟随到底」。
    var changeAtBottom: Bool { suffix == 0 }

    static func classify(oldIds: [Int], newIds: [Int]) -> RowDiff {
        let n = min(oldIds.count, newIds.count)
        var p = 0
        while p < n, oldIds[p] == newIds[p] { p += 1 }
        let cap = n - p
        var s = 0
        while s < cap, oldIds[oldIds.count - 1 - s] == newIds[newIds.count - 1 - s] { s += 1 }
        return RowDiff(prefix: p, suffix: s, oldMid: oldIds.count - p - s, newMid: newIds.count - p - s)
    }
}

// MARK: - 复用行宿主

/// 托管单行 SwiftUI 视图的可复用 `NSView`。`sizingOptions = []` → 不施加内在尺寸约束,
/// 由 `heightOfRow` 决定行高、宿主填满给定 rect(测量走 `fittingSize` 另一路径)。
final class RowHostingView: NSView {
    private let host: NSHostingView<AnyView>

    override init(frame frameRect: NSRect) {
        host = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: frameRect)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ view: AnyView) { host.rootView = view }
}
