import AgentSensing
import SwiftUI

/// Claude Code / Codex tab 的内容区:渲染感知到的外部会话**完整会话流**(历史 + 实时),空态显示「无活跃会话」。
///
/// 数据来自 `AgentSessionStore`(App 接线层喂:`SessionHistoryReader` 历史 + `AgentSensingService` 实时 events)。
/// 本视图**只读渲染**,不碰感知/文件。滚动容器用 `TranscriptListView`(AppKit `NSTableView` 包装)——
/// SwiftUI `ScrollView` 做「双向加载 + prepend 不跳」反复失败,换 30 年成熟原语根治(lessons §5.11)。
struct AgentSessionTabView: View {
    @ObservedObject var store: AgentSessionStore
    let agent: AgentKind

    private var items: [ConversationItem] { store.items(for: agent) }
    private var sessions: [AgentSessionSummary] { store.sessions(for: agent) }
    /// D2:item.id → 子 agent(命中索引的 Task 行挂入口)。在 MainActor 侧据 store 索引预算,传纯数据进 TranscriptListView。
    private var subagentByItemId: [Int: SubagentRef] {
        guard agent == .claudeCode else { return [:] }
        var map: [Int: SubagentRef] = [:]
        for it in items where it.toolUseId != nil {
            if let ref = store.subagentRef(for: it.toolUseId) { map[it.id] = ref }
        }
        return map
    }
    /// 所选会话的上下文窗口占用 token(给顶部占用条;无 → 占位「统计中」)。
    private var selectedContextTokens: Int? { sessions.first(where: \.isSelected)?.contextTokens }

    /// 会话流末条是否在「等你」(给 Codex 只读提示用)。
    private var isAwaitingLast: Bool { items.last?.isAwaiting == true }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 slim 条:多会话 → picker 切换 + 重置;单会话 → 仅重置(右对齐)。无会话不显示。
            // 上下文占用 2026-06-16 turn 模型起**移到每轮元数据栏**(per-turn),不再顶部全局一条。
            if !sessions.isEmpty { headerBar }
            content
        }
    }

    /// 顶部 slim 条:统一 tinted 底 + hairline,左 picker(多会话)右重置按钮。
    private var headerBar: some View {
        HStack(spacing: 4) {
            // 只要有会话就显 picker(即使单会话)—— 「浏览历史…」入口在 picker 底,需恒可达去找历史会话钉住。
            SessionPickerView(
                sessions: sessions,
                agent: agent,
                onSelect: { sid in store.selectSession(agent: agent, sessionId: sid) },
                onTogglePin: { sid in store.onTogglePinRequested?(agent, sid) },
                onBrowse: { store.onBrowseHistory?(agent) }
            )
            resetButton
        }
        .background(
            Rectangle().fill(ChatCardTheme.accent.opacity(0.05))
                .overlay(alignment: .bottom) { Rectangle().fill(ChatCardTheme.hairline).frame(height: 0.5) }
        )
    }

    /// 重置:清空当前会话并从磁盘重新读取(卡死 / 漏消息 / 解析错乱时手动恢复;与「加载更早」区分)。
    private var resetButton: some View {
        Button { store.resetSession(agent: agent) } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ChatCardTheme.accent.opacity(0.7))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("重置:清空并从磁盘重新读取当前会话消息")
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            emptyState
        } else {
            transcript
        }
    }

    // MARK: - 会话流(AppKit NSTableView 容器)
    //
    // **滚动主权归用户**:仅用户本就停在底部时才让新消息跟随到底;上滑读历史 → 新消息/加载更早都不动视口。
    // 「滚到顶加载更早」走 NSScrollView 的可靠滚动事件 + store 幂等闸,既不死锁也不无限(细节见 TranscriptListView)。

    private var transcript: some View {
        TranscriptListView(
            items: items,
            highlightedItemId: store.highlightedItemId,
            highlightedRegion: store.highlightedRegion,   // 子区高亮:点元数据栏光圈亮在元数据栏(非总结行)
            canLoadEarlier: store.canLoadEarlier(for: agent),
            isLoadingEarlier: store.isLoadingEarlier(for: agent),
            showCodexHint: agent == .codex && isAwaitingLast,
            sessionId: store.selectedSession(for: agent),   // 协调器据此判「切会话」(整表重建+到底),同会话只增量不跳
            onExpandToSide: store.onExpandToSide != nil ? { store.onExpandToSide?($0) } : nil,
            onLoadEarlierTap: triggerLoadEarlier,
            onReachTop: triggerLoadEarlier,
            onHighlightedRowMidY: { store.highlightedRowMidY = $0 },   // 协调器算的源行 midY → 供权限卡 beak 对准源行
            subagentByItemId: subagentByItemId,
            onOpenSubagent: store.onOpenSubagent != nil ? { store.onOpenSubagent?($0) } : nil,   // D2:Task 行 → 子 agent 侧卡
            onOpenTurnSteps: store.onOpenTurnSteps != nil ? { store.onOpenTurnSteps?($0) } : nil,   // 元数据栏 → 元数据行侧卡
            onOpenWorkflow: store.onOpenWorkflow != nil ? { store.onOpenWorkflow?($0) } : nil,   // #9:🧩 → workflow agent 列表卡
            onBackgroundClick: store.onBackgroundClick != nil ? { store.onBackgroundClick?() } : nil,   // #2:点空白关侧卡
            onOpenImage: store.onOpenImage != nil ? { store.onOpenImage?($0) } : nil   // P1-5:点缩略图开图片侧卡
        )
    }

    /// 触发加载更早(到顶/手动点共用)。store 内 `!isLoadingEarlier && canLoadEarlier` 双闸幂等:
    /// 在途重复调 = no-op;读到文件头 `canLoadEarlier` 为假自然停 → 不死锁、不无限。
    private func triggerLoadEarlier() {
        guard !store.isLoadingEarlier(for: agent), store.canLoadEarlier(for: agent) else { return }
        store.loadEarlier(for: agent)
    }

    // MARK: - 空态

    @ViewBuilder
    private var emptyState: some View {
        if store.loadDidFail(for: agent) {
            loadFailedState   // P2-10:选中会话读失败 → 提示 + 重试,而非永久空态
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: agent == .claudeCode ? "terminal" : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 22))
                    .foregroundStyle(ChatCardTheme.accent.opacity(0.4))
                Text(emptyText)
                    .font(ChatCardTheme.body)
                    .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.4))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// P2-10:加载失败态 —— 警示图标 + 文案 + 重试(走 `resetSession` 从磁盘重读)。
    private var loadFailedState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(ChatCardTheme.accent.opacity(0.55))
            Text("未能加载会话消息")
                .font(ChatCardTheme.body)
                .foregroundStyle(ChatCardTheme.textPrimary.opacity(0.55))
            Button { store.resetSession(agent: agent) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    Text("重试").font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(ChatCardTheme.accent.opacity(0.9))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(ChatCardTheme.accent.opacity(0.12)))
                .overlay(Capsule().stroke(ChatCardTheme.accent.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyText: String {
        switch agent {
        case .claudeCode: return "无活跃 Claude Code 会话"
        case .codex:      return "无活跃 Codex 会话"
        }
    }
}
