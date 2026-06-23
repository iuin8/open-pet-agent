import AgentSensing
import Foundation

/// picker 用的会话摘要 —— sessionId、项目名标签、最近活跃时间、是否选中,
/// 外加 P3.8 G3 文件元数据(标题 / 消息数 / 分支 / 文件改动时间),用于同项目多会话消歧。
public struct AgentSessionSummary: Identifiable, Equatable, Sendable {
    public let id: String
    /// 项目名(logs 取不到回退元数据项目名,再回退 sessionId 前 8 位)。
    public let label: String
    public let lastActivity: Date
    public let isSelected: Bool
    /// 人话标题(Claude ai-title / 首条 user 消息);无元数据 → nil,picker 回退 label。
    public let title: String?
    /// 消息数(user+assistant);大文件超扫描预算 → nil,picker 此时不显示数量。
    public let messageCount: Int?
    /// 上下文窗口占用 token(P3.8 F);无 → nil。
    public let contextTokens: Int?
    /// git 分支(同项目多会话的关键消歧位);无 → nil。
    public let gitBranch: String?
    /// 文件最后修改时间(picker 相对时间 + 活跃标识用);无元数据 → nil(回退 lastActivity)。
    public let lastModified: Date?
    /// 是否被用户钉住(历史浏览 P4 功能);默认 false。
    public let isPinned: Bool
    /// 钉住会话的文件不可用(被删/移,无任何元数据可加载)→ picker 行灰显 + 禁点(spec §5);默认 false。
    public let isUnavailable: Bool

    public init(
        id: String,
        label: String,
        lastActivity: Date,
        isSelected: Bool,
        title: String? = nil,
        messageCount: Int? = nil,
        contextTokens: Int? = nil,
        gitBranch: String? = nil,
        lastModified: Date? = nil,
        isPinned: Bool = false,
        isUnavailable: Bool = false
    ) {
        self.id = id
        self.label = label
        self.lastActivity = lastActivity
        self.isSelected = isSelected
        self.title = title
        self.messageCount = messageCount
        self.contextTokens = contextTokens
        self.gitBranch = gitBranch
        self.lastModified = lastModified
        self.isPinned = isPinned
        self.isUnavailable = isUnavailable
    }
}

/// 会话流行的**高亮子区**(2026-06-16:模型轮 item 有「元数据栏」+「总结」两个可点子区共用 item.id,
/// 高亮需区分点的是哪个 → 光圈亮在对应子区,不再错亮)。普通行(user/tool/thinking)只用 `.primary`。
public enum RowHighlightRegion: Sendable, Equatable {
    case primary    // 主内容:user/assistant 总结/tool/thinking 气泡
    case metadata   // 模型轮元数据栏
}

/// 统一陪伴卡片 Claude Code / Codex tab 的会话流 observable store。
///
/// 每 agent 持**多个**活跃会话各自的事件日志,用户可在 tab 顶部 picker 切换看哪个(P3.6 会话切换)。
/// 选中**粘滞**:首次初选最近活跃,之后**永不自动切换**(切会话是用户主动行为,见 `selectSession`)。
///
/// 用 `ObservableObject + @Published`(沿用历史;macOS 15 后可换 `@Observable`,但本类型够用未迁,同 `ChatCardState`)。
/// **Shell 感知-free**:只做值类型合并/折叠,不 tail/discovery;历史由 App 经 `SessionHistoryReader`
/// 读出后 `setHistory`,实时事件由 `AgentSensingService` sink 转发到 `appendLive`。
@MainActor
public final class AgentSessionStore: ObservableObject {

    /// 当前选中会话折叠后的会话流。
    @Published public private(set) var claudeItems: [ConversationItem] = []
    @Published public private(set) var codexItems: [ConversationItem] = []
    /// 给 picker 的会话列表(按最近活跃新→旧)。
    @Published public private(set) var claudeSessions: [AgentSessionSummary] = []
    @Published public private(set) var codexSessions: [AgentSessionSummary] = []
    /// Claude Code 待答**队列**(权限/问题)—— 多并发请求**并存**(各带 requestId),由 pet 旁权限侧卡堆叠展示。
    /// 不再单个顶替(旧设计新请求挤掉旧的);App 层 liveness 轮询把连接死的请求移除。Codex 无后台写回 → 永空。
    @Published public private(set) var claudePendingQueue: [PendingAction] = []
    /// 队列变化(增/删)回调 → App 据此 show/hide/重定位 pet 旁权限侧卡。
    public var onPendingQueueChanged: (() -> Void)?

    /// P3.7-③ 当前在侧宽卡里查看的 tool 项 id(源行据此画 accent halo 高亮)。
    /// App present 侧卡时设、收起时清(`onClose`)。跨会话 id 从 0 复用 → 切会话后无匹配行就不显示,无害。
    @Published public var highlightedItemId: Int?

    /// 高亮的**子区**(配合 `highlightedItemId`):点总结/气泡/工具 → `.primary`;点模型轮元数据栏 → `.metadata`。
    /// 让光圈亮在用户实际点的子区(模型轮 item 含两个可点子区共用 id,2026-06-16 用户反馈)。App present 侧卡时设。
    @Published public var highlightedRegion: RowHighlightRegion = .primary

    /// 高亮源行的全局 midY(SwiftUI top-down 窗口坐标),由 `AgentSessionTabView` 的 preference 写入。
    /// **仅调试入口**读它精确算 `sourceRowY`(真实点击走 `NSEvent.mouseLocation`,不依赖此值)。
    @Published public var highlightedRowMidY: CGFloat = 0

    /// P3.8 G4 正在「加载更早」的 agent 集(驱动按钮 spinner + 防重入)。`loadEarlier` 置入、
    /// `prependHistory` **一定移除**(即便空窗)→ 不会因空窗卡死(往返完成即复位,不靠「内容变了」)。
    @Published public private(set) var loadingEarlier: Set<AgentKind> = []
    public func isLoadingEarlier(for agent: AgentKind) -> Bool { loadingEarlier.contains(agent) }
    /// 加载更早**失败/无法进行**(App 端解析不到 URL 等)→ 解闸,免卡死按钮 + 阻塞后续触发。
    public func cancelLoadingEarlier(for agent: AgentKind) { loadingEarlier.remove(agent) }

    /// P2-10:选中会话**加载失败**(App 端找不到文件 / 文件不可读)的 agent 集 → 空态显「加载失败 + 重试」
    /// 而非永久空态。新一次加载(`selectSession`/`resetSession`)清旧失败标;`setHistory` 成功也清。
    @Published public private(set) var loadFailed: Set<AgentKind> = []
    public func loadDidFail(for agent: AgentKind) -> Bool { loadFailed.contains(agent) }
    /// App 在 `onSelectSession` 的真失败出口(URL 找不到 / 文件不可读)调用 → 置失败标。
    /// **带 `sessionId` 防竞态**:异步加载期间用户已切走(`selected[agent] != sid`)→ 不标,
    /// 否则旧 Task 会把**正在加载的新会话**误标失败(见 code review HIGH)。
    public func markLoadFailed(_ agent: AgentKind, sessionId sid: String) {
        guard selected[agent] == sid else { return }
        loadFailed.insert(agent)
    }

    /// 用户在 picker 手动选了会话 → App 据此拉那个会话的历史(sessionId → URL 在 App 接线层查)。
    public var onSelectSession: ((AgentKind, String) -> Void)?
    /// 用户点某会话行 📌 → App 据 sid 构 `PinnedSessionRef`(取文件 URL)后调 `togglePin`。
    public var onTogglePinRequested: ((AgentKind, String) -> Void)?
    /// 用户点「浏览历史…」→ App 开访达选目录 + 扫会话 + 弹浏览 sheet。
    public var onBrowseHistory: ((AgentKind) -> Void)?

    /// P3.8 G4 用户点「加载更早」→ App 据此从 `cursor` 字节偏移读上一个历史窗口往前接。
    /// 参数:agent、sessionId、当前最早字节游标(`endOffset`)。
    public var onLoadEarlier: ((AgentKind, String, UInt64) -> Void)?

    /// P3.7-③ 用户点大内容 tool 行(`detailAffordance == .sideCard`)→ App 弹侧宽卡看完整 input/output。
    /// 缺席(未注入)时,`AgentSessionTabView` 回退内联兜底展开(② 行为)。
    public var onExpandToSide: ((ConversationItem) -> Void)?

    /// D2:点 Task/Agent 工具行的「子 agent」入口 → App 加载子 agent transcript 弹子 agent 侧卡。
    public var onOpenSubagent: ((ConversationItem) -> Void)?

    /// 点模型一轮元数据栏 → App 弹「元数据行」侧卡(思考/工具,与总结详情分离,2026-06-16)。
    public var onOpenTurnSteps: ((ConversationItem) -> Void)?

    /// 点 workflow 🧩 → App 列出该 workflow 全部衍生 agent(`<sid>/subagents/workflows/<runId>/`,#9)。参数 = run id。
    public var onOpenWorkflow: ((String) -> Void)?

    /// 点会话流空白处(消息行下方 / 边距)→ App 关列容器(`ColumnContainerWindowController.close`)。
    public var onBackgroundClick: (() -> Void)?

    /// P1-5:点用户行图片缩略图 → App 开图片侧卡看全图。参数 = 被点附件。
    public var onOpenImage: ((ImageAttachment) -> Void)?

    /// D2:`toolUseId → SubagentRef`(App 扫各会话 `subagents/` 目录后并入,跨会话全局唯一 id → 平铺一张表)。
    private var claudeSubagents: [String: SubagentRef] = [:]
    /// 并入某次扫描结果(merge,不覆盖已有别会话的条目)。
    public func updateSubagentIndex(_ map: [String: SubagentRef]) {
        guard !map.isEmpty else { return }
        for (k, v) in map { claudeSubagents[k] = v }
        objectWillChange.send()   // Task 行的「子 agent」入口随索引到达刷新
    }
    /// 某 tool 行有无对应子 agent(`toolUseId` 命中索引)。
    public func subagentRef(for toolUseId: String?) -> SubagentRef? {
        guard let toolUseId else { return nil }
        return claudeSubagents[toolUseId]
    }

    /// agent → sessionId → 事件日志。
    private var logs: [AgentKind: [String: [AgentEvent]]] = [:]
    /// agent → sessionId → 最近事件时间(picker 排序 + 首次初选用)。
    private var lastActivity: [AgentKind: [String: Date]] = [:]
    /// agent → 当前选中 sessionId(粘滞,只由 selectSession / 首次初选改)。
    private var selected: [AgentKind: String] = [:]
    /// agent → sessionId → 文件元数据(标题/分支/消息数;App 扫 transcript 后经 `updateMetadata` 推入)。
    private var metadata: [AgentKind: [String: SessionMetadata]] = [:]
    /// agent → sessionId → **首条事件的 item id 基准**(P3.8 G4)。prepend 更早窗口时 `-= 更早事件数`,
    /// 使既有 item 的 id 恒定(`build(idStart:)`)→ 滚动锚定 / 展开集 / 高亮引用都不漂。
    private var seqBase: [AgentKind: [String: Int]] = [:]
    /// agent → sessionId → 已加载到的**最早字节偏移**(`loadEarlier` 的下一个 `endOffset` 游标)。
    private var historyCursor: [AgentKind: [String: UInt64]] = [:]
    /// agent → sessionId → 是否已读到文件头(没有更早内容了 → 隐藏「加载更早」)。
    private var historyReachedStart: [AgentKind: [String: Bool]] = [:]
    /// 钉住会话持久化(注入;nil = 未接线时退化为「只活跃」旧行为)。
    private var pinnedStore: PinnedSessionStore?
    /// agent → sessionId → 注入元数据(浏览/钉住加载某会话时存,**不被 poll 的 `updateMetadata` 全量替换冲掉**)
    /// → 选中/钉住的非活跃会话行能正常渲染标题/分支。
    private var injectedMeta: [AgentKind: [String: SessionMetadata]] = [:]

    public init() {}

    // MARK: - 读

    /// 某 agent 当前选中会话的会话流快照。
    public func items(for agent: AgentKind) -> [ConversationItem] {
        switch agent {
        case .claudeCode: return claudeItems
        case .codex:      return codexItems
        }
    }

    /// 某 agent 已知的全部会话(给 picker)。
    public func sessions(for agent: AgentKind) -> [AgentSessionSummary] {
        switch agent {
        case .claudeCode: return claudeSessions
        case .codex:      return codexSessions
        }
    }

    /// 某 agent 当前选中的 sessionId。
    public func selectedSession(for agent: AgentKind) -> String? { selected[agent] }

    /// tab 活动徽标:有待答 / 选中会话末条在等你 → `.awaiting`(强调);有活跃会话 → `.active`(点);
    /// 无会话 → `.none`。驱动 tab bar 红点。
    public func tabBadge(for agent: AgentKind) -> TabBadge {
        if agent == .claudeCode, !claudePendingQueue.isEmpty { return .awaiting }
        if items(for: agent).last?.isAwaiting == true { return .awaiting }   // 独立 awaiting 卡 / Codex 收尾问句折进轮
        return sessions(for: agent).isEmpty ? .none : .active
    }

    // MARK: - 写

    /// 一条实时事件(从 `AgentSensingService` sink 转发,按 `event.agent` + `sessionId` 路由进各自日志,
    /// **不再换会话就清空**)。**不自动切换选中** —— 仅首次无选中时初选最近活跃(见 `recomputeSelection`)。
    public func appendLive(_ event: AgentEvent) {
        let agent = event.agent
        let sid = event.sessionId
        var bySession = logs[agent] ?? [:]
        var log = bySession[sid] ?? []
        if log.last == event { return }   // 边界去重
        log.append(event)
        bySession[sid] = Self.enforceImageBudget(log)
        logs[agent] = bySession
        if seqBase[agent]?[sid] == nil { setSeqBase(agent, sid, 0) }   // 新会话基准 0(append 不漂既有 id)
        bump(agent, sid, event.timestamp)
        recomputeSelection(agent)
        rebuild(agent)
    }

    /// 设某 agent **指定会话**的历史(卡片弹出 / picker 选中时 App 读 transcript 尾部窗口后调)。
    /// 同会话已有实时日志:保留比历史末条更新的实时行(早于/等于历史的已含在历史里 → 丢弃,去边界重复)。
    /// `startOffset`/`reachedStart`:G4 增量加载游标 —— 该窗首条完整行的字节 + 是否已读到文件头。
    public func setHistory(
        _ events: [AgentEvent],
        agent: AgentKind,
        sessionId sid: String,
        startOffset: UInt64? = nil,
        reachedStart: Bool = false
    ) {
        var bySession = logs[agent] ?? [:]
        let existing = bySession[sid] ?? []
        let merged: [AgentEvent]
        if let lastHistoryTimestamp = events.last?.timestamp {
            merged = events + existing.filter { $0.timestamp > lastHistoryTimestamp }
        } else {
            merged = existing   // 历史空 → 保留已有实时
        }
        bySession[sid] = Self.enforceImageBudget(merged)
        logs[agent] = bySession
        loadFailed.remove(agent)    // P2-10:成功落历史 → 清失败标
        setSeqBase(agent, sid, 0)   // 新基线:首条 item id = 0(后续 prepend 才下移)
        if let startOffset { setCursor(agent, sid, startOffset) }
        setReachedStart(agent, sid, reachedStart)
        if let ts = merged.last?.timestamp { bump(agent, sid, ts) }
        recomputeSelection(agent)
        rebuild(agent)
    }

    /// P3.8 G4「加载更早」:把更早窗口的事件**前插**到指定会话日志头部。
    /// `seqBase -= earlier.count` → 既有 item 的 id 恒定(滚动/展开/高亮不漂);更新最早游标 + reachedStart。
    public func prependHistory(
        _ earlier: [AgentEvent],
        agent: AgentKind,
        sessionId sid: String,
        startOffset: UInt64,
        reachedStart: Bool
    ) {
        loadingEarlier.remove(agent)   // 往返完成 → 一定复位(空窗也算完成,不卡死)
        setCursor(agent, sid, startOffset)
        setReachedStart(agent, sid, reachedStart)
        guard !earlier.isEmpty else { rebuild(agent); return }   // 空窗只更游标/到顶标记
        var bySession = logs[agent] ?? [:]
        bySession[sid] = Self.enforceImageBudget(earlier + (bySession[sid] ?? []))
        logs[agent] = bySession
        setSeqBase(agent, sid, (seqBase[agent]?[sid] ?? 0) - earlier.count)
        rebuild(agent)
    }

    /// 选中会话是否还有更早历史可加载(未读到文件头)。无游标信息 → false(不显示「加载更早」)。
    public func canLoadEarlier(for agent: AgentKind) -> Bool {
        guard let sid = selected[agent],
              historyCursor[agent]?[sid] != nil,
              (historyReachedStart[agent]?[sid] ?? true) == false
        else { return false }
        return true
    }

    /// 触发「加载更早」:把当前最早游标交给 App 去读上一个窗口(App 读完调 `prependHistory`)。
    /// 防重入(已在加载 / 已到顶 → no-op);置 loading 态驱动按钮 spinner。
    public func loadEarlier(for agent: AgentKind) {
        guard !loadingEarlier.contains(agent), canLoadEarlier(for: agent),
              let sid = selected[agent], let cursor = historyCursor[agent]?[sid] else { return }
        loadingEarlier.insert(agent)
        onLoadEarlier?(agent, sid, cursor)
    }

    /// App 扫 transcript(`SessionMetadataScanner`)后推入某 agent 的会话元数据 → 刷新 picker 摘要。
    /// 元数据未变则跳过(避免轮询 1.5s 反复重建 published 摘要)。只更新 picker 列表,不动会话流 items。
    public func updateMetadata(_ meta: [String: SessionMetadata], agent: AgentKind) {
        if metadata[agent] == meta { return }
        metadata[agent] = meta
        rebuildSummaries(agent)
    }

    /// 用户在 picker 选了会话(**切会话是唯一改变选中的用户主动行为**)→ 触发 App 拉该会话历史。
    public func selectSession(agent: AgentKind, sessionId sid: String) {
        let switched = selected[agent] != sid
        selected[agent] = sid
        // P2-9:切到**不同**会话 → 清旧高亮。item id 每会话从 0 复用,旧 id 会命中新会话无关行(光圈错亮)。
        if switched { clearHighlight() }
        loadFailed.remove(agent)   // P2-10:新一次加载 → 先清旧失败标(加载完再由成功/失败出口定夺)
        rebuild(agent)
        onSelectSession?(agent, sid)
    }

    /// 清高亮状态(切会话 / 重置):高亮 id + 子区复位。
    public func clearHighlight() {
        if highlightedItemId != nil { highlightedItemId = nil }
        highlightedRegion = .primary
    }

    /// 重置当前选中会话:清空其日志 / 游标 / 加载态 / 高亮 → 经 `onSelectSession` 从磁盘**重新读取尾窗**。
    /// 用于卡死 / 漏消息 / 解析错乱时手动恢复(与「加载更早」区分:那是往前续读,这是整段重读)。无选中 → no-op。
    public func resetSession(agent: AgentKind) {
        guard let sid = selected[agent] else { return }
        logs[agent]?[sid] = nil
        setSeqBase(agent, sid, 0)
        historyCursor[agent]?[sid] = nil
        historyReachedStart[agent]?[sid] = nil
        loadingEarlier.remove(agent)
        loadFailed.remove(agent)       // P2-10:重试 = 新一次加载,先清旧失败标
        clearHighlight()               // 高亮 id + 子区复位 + 缩回连接线(P2-9 helper)
        rebuild(agent)                 // 先清空当前显示
        onSelectSession?(agent, sid)   // App 从磁盘重读尾窗(loadedSessionURLs 兜底静默会话)
    }

    // MARK: - 待答队列(权限/问题,pet 旁权限侧卡)

    /// 某 agent 的待答队列(Codex 永空)。
    public func pendingQueue(for agent: AgentKind) -> [PendingAction] {
        agent == .claudeCode ? claudePendingQueue : []
    }

    /// 入队一条待答请求(**不顶替**旧的,多并发并存)。同 id 已在队 → 忽略(去重)。
    public func addPending(_ action: PendingAction) {
        guard !claudePendingQueue.contains(where: { $0.id == action.id }) else { return }
        claudePendingQueue.append(action)
        onPendingQueueChanged?()
    }

    /// 出队一条(用户答完 / 连接死了)。
    public func removePending(id: String) {
        guard claudePendingQueue.contains(where: { $0.id == id }) else { return }
        claudePendingQueue.removeAll { $0.id == id }
        onPendingQueueChanged?()
    }

    /// 清空队列(全给 `onSuperseded` 弃权兜底)—— app 退出等收口用。
    public func clearAllPending() {
        for a in claudePendingQueue { a.onSuperseded() }
        claudePendingQueue.removeAll()
        onPendingQueueChanged?()
    }

    // MARK: - 私有

    private func bump(_ agent: AgentKind, _ sid: String, _ ts: Date) {
        var m = lastActivity[agent] ?? [:]
        if let cur = m[sid], cur >= ts { /* 保留更晚的 */ } else { m[sid] = ts }
        lastActivity[agent] = m
    }

    // G4 per-session 嵌套字典 setter(避免到处 `var d = dict[agent] ?? [:]` 样板)。
    private func setSeqBase(_ agent: AgentKind, _ sid: String, _ v: Int) {
        var m = seqBase[agent] ?? [:]; m[sid] = v; seqBase[agent] = m
    }
    private func setCursor(_ agent: AgentKind, _ sid: String, _ v: UInt64) {
        var m = historyCursor[agent] ?? [:]; m[sid] = v; historyCursor[agent] = m
    }
    private func setReachedStart(_ agent: AgentKind, _ sid: String, _ v: Bool) {
        var m = historyReachedStart[agent] ?? [:]; m[sid] = v; historyReachedStart[agent] = m
    }

    /// 选中**粘滞**:已选且会话还在 → 保持(**永不自动切换** —— 切会话是用户主动行为,见 selectSession)。
    /// 仅「无选中(首次)」或「选中会话消失」→ 初选/回退到最近活跃会话。
    /// 单会话图片 Data 常驻预算(P1-5 内存上界,堵对抗验证抓出的「无界累积」)。`logs` 只增不减,每事件
    /// 旁挂解码后图字节(~80KB/张),截图密集会话反复「加载更早」会让常驻内存越过 <200MB 预算且不回落。
    /// → 超预算时从**最老(index 0,文件最靠前/滚得最远)**起把图字节换占位(`strippingImageData`),保留近期上下文;
    /// 文本/元数据全留,只老图退兜底图标(要看回去 reset 重读)。**局限**:view-agnostic,极端「加载更早 600+ 张」
    /// 时刚载入的最老图可能即被瘦身 —— 但那是 600+ 张的非现实极端,常态(初载+实时)evict-oldest 正确。
    nonisolated static let imageDataBudget = 48 * 1024 * 1024   // 48MB ≈ 600 张 @80KB,远低于 200MB 总预算
    nonisolated static func enforceImageBudget(_ events: [AgentEvent], budget: Int = imageDataBudget) -> [AgentEvent] {
        var total = events.reduce(0) { $0 + $1.imageByteCount }
        guard total > budget else { return events }   // 早退:未超预算零开销(常态)
        var out = events
        for i in out.indices {
            guard total > budget else { break }
            let bytes = out[i].imageByteCount
            guard bytes > 0 else { continue }
            out[i] = out[i].strippingImageData()
            total -= bytes
        }
        return out
    }

    private func recomputeSelection(_ agent: AgentKind) {
        if let sel = selected[agent], logs[agent]?[sel] != nil { return }
        let old = selected[agent]
        selected[agent] = (lastActivity[agent] ?? [:]).max { $0.value < $1.value }?.key
        // 选中会话消失 → 回退到最近活跃 = 一次切会话 → 清旧会话残留高亮(P2-9;首次 nil→sid 无高亮,跳过)。
        if old != nil, selected[agent] != old { clearHighlight() }
    }

    private func rebuild(_ agent: AgentKind) {
        let sel = selected[agent]
        let log = sel.flatMap { logs[agent]?[$0] } ?? []
        let idStart = sel.flatMap { seqBase[agent]?[$0] } ?? 0   // G4:稳定 id 基准(prepend 后既有 id 不漂)
        // 2026-06-16 turn 模型:扁平流 → 轮次流(用户行 + 模型一轮行,思考/工具折进元数据栏)。
        let items = AgentConversation.buildTurnItems(from: log, idStart: idStart)
        switch agent {
        case .claudeCode: claudeItems = items
        case .codex:      codexItems = items
        }
        rebuildSummaries(agent)
    }

    private func rebuildSummaries(_ agent: AgentKind) {
        let summaries = makeSummaries(agent)
        switch agent {
        case .claudeCode: claudeSessions = summaries
        case .codex:      codexSessions = summaries
        }
    }

    private func makeSummaries(_ agent: AgentKind) -> [AgentSessionSummary] {
        let acts = lastActivity[agent] ?? [:]
        let meta = metadata[agent] ?? [:]
        let inj = injectedMeta[agent] ?? [:]
        let sel = selected[agent]
        let pins = pinnedStore?.pinned(for: agent) ?? []
        let pinById = Dictionary(pins.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        // 并集:活跃(logs/metadata) ∪ 注入(浏览/钉住加载) ∪ 钉住 ∪ 当前选中(恒在,不掉出列表)。
        var ids = Set((logs[agent] ?? [:]).keys).union(meta.keys).union(inj.keys).union(pinById.keys)
        if let sel { ids.insert(sel) }
        return ids.map { sid -> AgentSessionSummary in
            // 元数据:活跃 / 注入优先,其次钉住缓存(title/branch)兜底。时间:活跃 lastModified → 钉住 pinnedAt。
            let m = meta[sid] ?? inj[sid]
            let pin = pinById[sid]
            return AgentSessionSummary(
                id: sid,
                label: label(agent, sid, m),
                lastActivity: acts[sid] ?? m?.lastModified ?? pin?.pinnedAt ?? .distantPast,
                isSelected: sel == sid,
                title: m?.title ?? pin?.title,
                messageCount: m?.messageCount,
                contextTokens: m?.contextTokens,
                gitBranch: m?.gitBranch ?? pin?.gitBranch,
                lastModified: m?.lastModified ?? pin?.pinnedAt,
                isPinned: pin != nil,
                // 钉住但无任何活跃/注入元数据 = 文件被删/移(loadPinnedSessions 跳过未注入)→ 灰显禁点(spec §5)。
                isUnavailable: pin != nil && m == nil && acts[sid] == nil
            )
        }.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: - 钉住 / 浏览会话(spec §4 列表合成)

    /// 接线钉住持久化(启动注入)→ 列表纳入钉住会话(非活跃也留)。
    public func setPinnedStore(_ p: PinnedSessionStore) {
        pinnedStore = p
        rebuildSummaries(.claudeCode); rebuildSummaries(.codex)
    }

    /// 浏览/钉住加载某会话时注入其元数据(poll 的 `updateMetadata` 全量替换不动它 → 选中/钉住行能正常渲染)。
    public func noteLoadedSession(agent: AgentKind, sessionId: String, meta: SessionMetadata) {
        injectedMeta[agent, default: [:]][sessionId] = meta
        rebuildSummaries(agent)
    }

    /// 钉住态变更后(pin/unpin)→ 重算列表。
    public func refreshPinned(_ agent: AgentKind) { rebuildSummaries(agent) }

    /// 切换某会话钉住态(钉则存 `ref`,已钉则取消)→ 刷列表。
    public func togglePin(agent: AgentKind, sessionId: String, ref: PinnedSessionRef) {
        guard let pinnedStore else { return }
        if pinnedStore.isPinned(agent: agent, sessionId: sessionId) {
            pinnedStore.unpin(agent: agent, sessionId: sessionId)
        } else {
            pinnedStore.pin(ref)
        }
        rebuildSummaries(agent)
    }

    /// 会话标签 = 项目名(日志里第一条带 cwd 的事件 → 元数据项目名 → sessionId 前 8 位)。
    private func label(_ agent: AgentKind, _ sid: String, _ meta: SessionMetadata?) -> String {
        if let log = logs[agent]?[sid],
           let project = log.compactMap(\.projectName).first(where: { !$0.isEmpty }) {
            return project
        }
        if let project = meta?.projectName, !project.isEmpty { return project }
        return String(sid.prefix(8))
    }
}
