import Testing
import Foundation
import AgentSensing
@testable import Shell

@MainActor
@Suite("AgentSessionStore — 历史+实时合并 / 去重 / 多会话切换 / 待答")
struct AgentSessionStoreTests {

    func e(_ kind: AgentEventKind, _ t: TimeInterval, agent: AgentKind = .claudeCode, session: String = "s", detail: String? = nil) -> AgentEvent {
        AgentEvent(agent: agent, sessionId: session, cwd: nil, kind: kind, timestamp: Date(timeIntervalSince1970: t), detail: detail)
    }

    // turn 模型 helper:取轮 / 取轮内首个 tool step。
    func turn(_ k: ConversationItem.Kind?) -> AssistantTurn? {
        if case .assistantTurn(let a)? = k { return a }; return nil
    }
    func firstTool(_ a: AssistantTurn?) -> (state: ConversationItem.ToolState, input: String?, output: String?)? {
        for s in a?.steps ?? [] { if case .tool(_, _, _, let st, let i, let o, _) = s { return (st, i, o) } }
        return nil
    }

    // MARK: - resetSession(#11 重置按钮)

    @Test("resetSession:清空当前会话 + 触发 onSelectSession 重读 + 保留其他会话 + 清高亮")
    func resetSessionClearsAndReloads() {
        let store = AgentSessionStore()
        var reloaded: (AgentKind, String)?
        store.onSelectSession = { agent, sid in reloaded = (agent, sid) }
        store.appendLive(e(.userPrompt(text: "会话A消息"), 1, session: "A"))
        store.appendLive(e(.userPrompt(text: "会话B消息"), 2, session: "B"))
        store.selectSession(agent: .claudeCode, sessionId: "A")
        #expect(!store.claudeItems.isEmpty)
        store.highlightedItemId = 0
        reloaded = nil
        store.resetSession(agent: .claudeCode)
        #expect(store.claudeItems.isEmpty)                          // A 清空显示
        #expect(store.highlightedItemId == nil)                     // 高亮清零
        #expect(reloaded?.0 == .claudeCode && reloaded?.1 == "A")   // 触发从磁盘重读 A
        store.selectSession(agent: .claudeCode, sessionId: "B")
        #expect(!store.claudeItems.isEmpty)                         // B 日志未受影响,切回仍在
    }

    @Test("**P2-9** selectSession 切到**不同**会话 → 清高亮(防旧 id 命中新会话无关行);同会话 → 保留")
    func selectSessionClearsHighlightOnSwitch() {
        let store = AgentSessionStore()
        store.appendLive(e(.userPrompt(text: "A 消息"), 1, session: "A"))
        store.appendLive(e(.userPrompt(text: "B 消息"), 2, session: "B"))
        store.selectSession(agent: .claudeCode, sessionId: "A")
        store.highlightedItemId = 0
        store.highlightedRegion = .metadata
        // 切到不同会话 B → 清高亮 + 子区复位
        store.selectSession(agent: .claudeCode, sessionId: "B")
        #expect(store.highlightedItemId == nil)
        #expect(store.highlightedRegion == .primary)
        // 再设高亮,选**同一**会话 B → 不清(非切会话)
        store.highlightedItemId = 5
        store.selectSession(agent: .claudeCode, sessionId: "B")
        #expect(store.highlightedItemId == 5)
    }

    @Test("**P1-5** 图片内存预算:超预算从最老起把图字节换占位,文本/元数据/近期图保留")
    func imageBudgetEvictsOldest() {
        func imgEvent(_ ts: Double, bytes: Int) -> AgentEvent {
            AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil, kind: .userPrompt(text: "msg\(Int(ts))"),
                       timestamp: Date(timeIntervalSince1970: ts),
                       attachments: [ImageAttachment(id: 0, data: Data(count: bytes), mediaType: "image/png")])
        }
        // 4 张图各 100 字节,预算 250 → 应丢最老两张(回到 ≤250),保留最近两张。
        let events = [imgEvent(1, bytes: 100), imgEvent(2, bytes: 100), imgEvent(3, bytes: 100), imgEvent(4, bytes: 100)]
        let out = AgentSessionStore.enforceImageBudget(events, budget: 250)
        #expect(out[0].imageByteCount == 0)   // 最老 → 占位
        #expect(out[1].imageByteCount == 0)
        #expect(out[2].imageByteCount == 100) // 近期保留
        #expect(out[3].imageByteCount == 100)
        #expect(out.allSatisfy { $0.attachments.count == 1 })   // 附件结构在(只字节没了),文本保留
        if case .userPrompt(let t) = out[0].kind { #expect(t == "msg1") } else { Issue.record("文本应保留") }
        // 未超预算 → 原样
        #expect(AgentSessionStore.enforceImageBudget(events, budget: 10_000).allSatisfy { $0.imageByteCount == 100 })
    }

    @Test("**P2-10** loadFailed:标当前选中会话置位;setHistory 成功清;切走后旧 sid 失败标被忽略(防竞态)")
    func loadFailedLifecycle() {
        let store = AgentSessionStore()
        store.appendLive(e(.userPrompt(text: "x"), 1, session: "s"))
        store.selectSession(agent: .claudeCode, sessionId: "s")
        store.markLoadFailed(.claudeCode, sessionId: "s")
        #expect(store.loadDidFail(for: .claudeCode))
        #expect(!store.loadDidFail(for: .codex))                    // 按 agent 隔离
        // 成功落历史 → 清失败标
        store.setHistory([e(.userPrompt(text: "y"), 2)], agent: .claudeCode, sessionId: "s")
        #expect(!store.loadDidFail(for: .claudeCode))
        // **竞态**:已切到别的会话后,旧 sid 的失败标被忽略 → 不误标正在加载的新会话
        store.appendLive(e(.userPrompt(text: "z"), 3, session: "other"))
        store.selectSession(agent: .claudeCode, sessionId: "other")
        store.markLoadFailed(.claudeCode, sessionId: "s")           // 旧 sid,已切走 → 应忽略
        #expect(!store.loadDidFail(for: .claudeCode))
    }

    @Test("setHistory:相同 fingerprint 跳过重复 rebuild")
    func setHistorySkipsUnchangedFingerprint() {
        let store = AgentSessionStore()
        let ts = Date(timeIntervalSince1970: 1)
        let fp = SessionFileFingerprint(mtime: ts, size: 10)
        let first = [e(.assistantText(text: "first"), 1)]
        let second = [e(.assistantText(text: "second"), 2)]

        store.setHistory(first, agent: .claudeCode, sessionId: "s", fingerprint: fp)
        store.setHistory(second, agent: .claudeCode, sessionId: "s", fingerprint: fp)

        #expect(store.items(for: .claudeCode).count == 1)
        if case .assistantTurn(let turn)? = store.items(for: .claudeCode).first?.kind {
            #expect(turn.finalText == "first")
        } else {
            Issue.record("应保留第一次 history")
        }
    }

    @Test("setHistory:reset 后相同 fingerprint 仍可重载")
    func setHistorySameFingerprintReloadsAfterReset() {
        let store = AgentSessionStore()
        let ts = Date(timeIntervalSince1970: 1)
        let fp = SessionFileFingerprint(mtime: ts, size: 10)
        let history = [e(.assistantText(text: "first"), 1)]

        store.setHistory(history, agent: .claudeCode, sessionId: "s", fingerprint: fp)
        store.resetSession(agent: .claudeCode)
        store.setHistory(history, agent: .claudeCode, sessionId: "s", fingerprint: fp)

        #expect(store.items(for: .claudeCode).isEmpty == false)
    }

    @Test("resetSession:无选中会话 → no-op(不触发 onSelectSession)")
    func resetSessionNoSelection() {
        let store = AgentSessionStore()
        var called = false
        store.onSelectSession = { _, _ in called = true }
        store.resetSession(agent: .codex)
        #expect(called == false)
    }

    @Test("appendLive 空起步 → 折叠成轮次(user 轮 + assistant 轮含 tool step)")
    func appendLiveFromEmpty() {
        let store = AgentSessionStore()
        store.appendLive(e(.userPrompt(text: "改个 bug"), 1))
        store.appendLive(e(.toolUse(name: "Bash", summary: "npm test"), 2))
        store.appendLive(e(.toolResult(name: "", isError: false), 3))
        #expect(store.claudeItems.count == 2)   // user 轮 + assistant 轮
        let a = turn(store.claudeItems.last?.kind)
        #expect(a?.toolCount == 1)
        #expect(firstTool(a)?.state == .ok)     // toolResult 收尾成 .ok
    }

    @Test("toolUse/Result 的 detail 折叠进轮内 tool step input/output → 轮可展开侧卡")
    func detailFlowsIntoToolItem() {
        let store = AgentSessionStore()
        let bigInput = String(repeating: "x\n", count: 30)
        store.appendLive(e(.toolUse(name: "exec", summary: "ls"), 1, agent: .codex, detail: bigInput))
        store.appendLive(e(.toolResult(name: "", isError: false), 2, agent: .codex, detail: "完整输出"))
        let item = store.codexItems.last
        let t = firstTool(turn(item?.kind))
        #expect(t?.input == bigInput)               // toolUse detail → step input
        #expect(t?.output == "完整输出")             // toolResult detail → step output
        #expect(item?.detailAffordance == .sideCard) // 带工具的轮 → 可点开时间线侧卡
    }

    @Test("仅 detail 不同的两条 toolUse → 不去重,折进同一轮的两个 tool step")
    func detailDifferenceDefeatsDedup() {
        let store = AgentSessionStore()
        store.appendLive(e(.toolUse(name: "exec", summary: "ls"), 1, agent: .codex, detail: nil))
        store.appendLive(e(.toolUse(name: "exec", summary: "ls"), 1, agent: .codex, detail: "ls -la"))
        #expect(store.codexItems.count == 1)              // 同轮(无 user/text 边界)
        #expect(turn(store.codexItems.first?.kind)?.toolCount == 2)   // 两个 tool step 都在(detail 不同非重复)
    }

    @Test("同事件连续两次 → 边界去重,只留一条")
    func dedupConsecutive() {
        let store = AgentSessionStore()
        let evt = e(.assistantText(text: "在想"), 1)
        store.appendLive(evt)
        store.appendLive(evt)
        #expect(store.claudeItems.count == 1)
    }

    @Test("选中粘滞:首次初选最近活跃,之后别的会话来新事件**不自动切换**")
    func stickySelectionNoAutoSwitch() {
        let store = AgentSessionStore()
        store.appendLive(e(.assistantText(text: "首会话"), 1, session: "first"))   // 首次初选 first
        #expect(store.selectedSession(for: .claudeCode) == "first")
        store.appendLive(e(.assistantText(text: "别的会话"), 2, session: "other")) // 另一会话来新事件
        // **不自动切换** —— 仍停在 first(切会话是用户主动行为)。
        #expect(store.selectedSession(for: .claudeCode) == "first")
        #expect(turn(store.claudeItems.first?.kind)?.finalText == "首会话")
        #expect(store.sessions(for: .claudeCode).count == 2)              // 两个都在 picker
    }

    @Test("选中会话消失 → 回退到最近活跃(仅此一种自动改选)")
    func fallbackWhenSelectedGone() {
        let store = AgentSessionStore()
        store.appendLive(e(.assistantText(text: "A1"), 1, session: "A"))
        store.selectSession(agent: .claudeCode, sessionId: "A")
        store.appendLive(e(.assistantText(text: "B1"), 2, session: "B"))
        #expect(store.selectedSession(for: .claudeCode) == "A")           // 粘滞,B 不抢
    }

    @Test("selectSession 触发 onSelectSession(App 据此拉历史)")
    func selectFiresCallback() {
        let store = AgentSessionStore()
        store.appendLive(e(.assistantText(text: "x"), 1, session: "s1"))
        store.appendLive(e(.assistantText(text: "y"), 2, session: "s2"))
        var picked: (AgentKind, String)?
        store.onSelectSession = { picked = ($0, $1) }
        store.selectSession(agent: .claudeCode, sessionId: "s1")
        #expect(picked?.0 == .claudeCode)
        #expect(picked?.1 == "s1")
    }

    @Test("sessions(for:) 按最近活跃新→旧排序")
    func sessionsSortedByActivity() {
        let store = AgentSessionStore()
        store.appendLive(e(.assistantText(text: "老"), 10, session: "older"))
        store.appendLive(e(.assistantText(text: "新"), 30, session: "newer"))
        store.appendLive(e(.assistantText(text: "中"), 20, session: "mid"))
        let ids = store.sessions(for: .claudeCode).map(\.id)
        #expect(ids == ["newer", "mid", "older"])
    }

    @Test("setHistory 新会话 → items 由历史构建")
    func setHistoryNewSession() {
        let store = AgentSessionStore()
        store.setHistory([
            e(.userPrompt(text: "历史问"), 1),
            e(.assistantText(text: "历史答"), 2),
        ], agent: .claudeCode, sessionId: "s")
        #expect(store.claudeItems.count == 2)
        #expect(store.claudeItems.first?.kind == .user(text: "历史问"))
    }

    @Test("setHistory 同会话 → 保留比历史末条更新的实时行,丢弃重叠")
    func setHistoryMergesNewerLive() {
        let store = AgentSessionStore()
        // 先有实时:t=2(与历史重叠)+ t=5(历史之后)。
        store.appendLive(e(.assistantText(text: "重叠行"), 2))
        store.appendLive(e(.assistantText(text: "更新行"), 5))
        // 历史窗口到 t=3 为止。
        store.setHistory([
            e(.userPrompt(text: "历史问"), 1),
            e(.assistantText(text: "重叠行"), 2),
            e(.assistantText(text: "历史末"), 3),
        ], agent: .claudeCode, sessionId: "s")
        // 历史 3 条 + 仅 t>3 的实时(更新行)= 4 事件;turn 模型折成 user 轮 + assistant 轮。
        // finalText = 本轮全部 text 拼接(2026-06-19):验「重叠行只一条(实时重叠被丢不重复)+ 更新行存活」。
        #expect(store.claudeItems.count == 2)
        #expect(turn(store.claudeItems.last?.kind)?.finalText == "重叠行\n\n历史末\n\n更新行")
    }

    @Test("items(for:) 按 agent 路由,claude / codex 互不串")
    func routesByAgent() {
        let store = AgentSessionStore()
        store.appendLive(e(.assistantText(text: "C"), 1, agent: .claudeCode, session: "c"))
        store.appendLive(e(.assistantText(text: "X"), 1, agent: .codex, session: "x"))
        #expect(store.items(for: .claudeCode).count == 1)
        #expect(store.items(for: .codex).count == 1)
        #expect(turn(store.items(for: .claudeCode).first?.kind)?.finalText == "C")
        #expect(turn(store.items(for: .codex).first?.kind)?.finalText == "X")
    }

    // MARK: - G3 会话元数据(标题/分支/消息数)

    func meta(title: String?, branch: String? = nil, count: Int? = nil, modified: TimeInterval = 100) -> SessionMetadata {
        SessionMetadata(title: title, projectName: nil, startTime: nil, gitBranch: branch,
                        messageCount: count, lastModified: Date(timeIntervalSince1970: modified))
    }

    @Test("updateMetadata 把标题/分支/消息数合进对应会话摘要")
    func metadataEnrichesSummary() {
        let store = AgentSessionStore()
        store.appendLive(e(.assistantText(text: "x"), 1, session: "s1"))
        store.updateMetadata(["s1": meta(title: "修复登录", branch: "feature/x", count: 12)], agent: .claudeCode)
        let s = store.sessions(for: .claudeCode).first { $0.id == "s1" }
        #expect(s?.title == "修复登录")
        #expect(s?.gitBranch == "feature/x")
        #expect(s?.messageCount == 12)
    }

    @Test("metadata-only 会话(尚无事件)也进 picker 列表(并集)")
    func metadataOnlySessionAppears() {
        let store = AgentSessionStore()
        store.appendLive(e(.assistantText(text: "x"), 1, session: "live"))
        store.updateMetadata([
            "live": meta(title: "活跃会话", modified: 5),
            "quiet": meta(title: "安静会话", modified: 50),     // 无事件,仅元数据
        ], agent: .claudeCode)
        let ids = Set(store.sessions(for: .claudeCode).map(\.id))
        #expect(ids == ["live", "quiet"])
        #expect(store.sessions(for: .claudeCode).first?.id == "quiet")   // modified 更新 → 排前
    }

    @Test("updateMetadata 不影响会话流 items(只刷 picker)")
    func metadataDoesNotTouchItems() {
        let store = AgentSessionStore()
        store.appendLive(e(.assistantText(text: "正文"), 1, session: "s"))
        let before = store.claudeItems
        store.updateMetadata(["s": meta(title: "标题")], agent: .claudeCode)
        #expect(store.claudeItems == before)
    }

    // MARK: - G4 增量加载(prepend / 游标 / 稳定 id)

    @Test("prependHistory 前插更早事件 + 既有 item 的 id 恒定(不漂)")
    func prependKeepsIdsStable() {
        let store = AgentSessionStore()
        store.setHistory([e(.userPrompt(text: "尾1"), 10), e(.assistantText(text: "尾2"), 11)],
                         agent: .claudeCode, sessionId: "s", startOffset: 500, reachedStart: false)
        let idsBefore = store.claudeItems.map(\.id)
        #expect(idsBefore == [0, 1])
        store.prependHistory([e(.userPrompt(text: "早1"), 1), e(.assistantText(text: "早2"), 2)],
                             agent: .claudeCode, sessionId: "s", startOffset: 200, reachedStart: false)
        #expect(store.claudeItems.count == 4)
        #expect(store.claudeItems.map(\.kind).first == .user(text: "早1"))   // 更早的排前
        #expect(store.claudeItems.suffix(2).map(\.id) == idsBefore)           // 原尾部两条 id 不变
    }

    @Test("canLoadEarlier:有游标且未到顶 → true;reachedStart → false")
    func canLoadEarlierReflectsCursor() {
        let store = AgentSessionStore()
        store.setHistory([e(.userPrompt(text: "x"), 1)], agent: .claudeCode, sessionId: "s",
                         startOffset: 300, reachedStart: false)
        #expect(store.canLoadEarlier(for: .claudeCode))
        store.prependHistory([e(.userPrompt(text: "更早"), 0)], agent: .claudeCode, sessionId: "s",
                             startOffset: 0, reachedStart: true)
        #expect(!store.canLoadEarlier(for: .claudeCode))   // 到顶
    }

    @Test("无游标信息(纯 live)→ canLoadEarlier false")
    func liveOnlyNoLoadEarlier() {
        let store = AgentSessionStore()
        store.appendLive(e(.assistantText(text: "实时"), 1))
        #expect(!store.canLoadEarlier(for: .claudeCode))
    }

    @Test("loadEarlier 把当前最早游标交给 onLoadEarlier")
    func loadEarlierFiresWithCursor() {
        let store = AgentSessionStore()
        store.setHistory([e(.userPrompt(text: "x"), 1)], agent: .claudeCode, sessionId: "s",
                         startOffset: 777, reachedStart: false)
        var got: (AgentKind, String, UInt64)?
        store.onLoadEarlier = { got = ($0, $1, $2) }
        store.loadEarlier(for: .claudeCode)
        #expect(got?.0 == .claudeCode)
        #expect(got?.1 == "s")
        #expect(got?.2 == 777)
    }

    @Test("prepend 空窗只更到顶标记,不改 items")
    func prependEmptyWindowJustMarksTop() {
        let store = AgentSessionStore()
        store.setHistory([e(.userPrompt(text: "x"), 1)], agent: .claudeCode, sessionId: "s",
                         startOffset: 100, reachedStart: false)
        let before = store.claudeItems
        store.prependHistory([], agent: .claudeCode, sessionId: "s", startOffset: 100, reachedStart: true)
        #expect(store.claudeItems == before)
        #expect(!store.canLoadEarlier(for: .claudeCode))
    }

    @Test("loadingEarlier:loadEarlier 置位 + 防重入;prependHistory(含空窗)一定复位")
    func loadingEarlierFlagLifecycle() {
        let store = AgentSessionStore()
        store.setHistory([e(.userPrompt(text: "x"), 1)], agent: .claudeCode, sessionId: "s",
                         startOffset: 500, reachedStart: false)
        var fires = 0
        store.onLoadEarlier = { _, _, _ in fires += 1 }
        store.loadEarlier(for: .claudeCode)
        #expect(store.isLoadingEarlier(for: .claudeCode))
        store.loadEarlier(for: .claudeCode)                  // 重入被挡
        #expect(fires == 1)
        // 空窗(未到顶)也必须复位 loading,否则按钮卡「加载中」。
        store.prependHistory([], agent: .claudeCode, sessionId: "s", startOffset: 300, reachedStart: false)
        #expect(!store.isLoadingEarlier(for: .claudeCode))
        store.loadEarlier(for: .claudeCode)                  // 复位后可再次触发
        #expect(fires == 2)
    }

    @Test("增量加载循环:反复 loadEarlier→prependHistory 单调推进游标,到文件头自然停(view level 触发的契约)")
    func repeatedLoadTerminatesAtStart() {
        // view 改成 level 触发(距顶 ≤ margin 就反复调 triggerLoadEarlier)后,新依赖这条契约:
        // 反复 loadEarlier 必须**单调推进游标 + 到 reachedStart 自然停** —— 既不死锁(卡在第 1 窗)也不无限(永不停)。
        let store = AgentSessionStore()
        store.setHistory([e(.userPrompt(text: "尾"), 100)], agent: .claudeCode, sessionId: "s",
                         startOffset: 300, reachedStart: false)
        // 模拟 App:每次 onLoadEarlier 喂一个更早窗,游标递减 100,到 0 即 reachedStart(同步回喂 = 快加载)。
        var loads = 0
        store.onLoadEarlier = { agent, sid, cursor in
            loads += 1
            let next: UInt64 = cursor >= 100 ? cursor - 100 : 0
            let ev = AgentEvent(agent: agent, sessionId: sid, cwd: nil,
                                kind: .userPrompt(text: "早\(cursor)"),
                                timestamp: Date(timeIntervalSince1970: Double(cursor)))
            store.prependHistory([ev], agent: agent, sessionId: sid, startOffset: next, reachedStart: next == 0)
        }
        var guardCount = 0
        while store.canLoadEarlier(for: .claudeCode), guardCount < 100 {
            store.loadEarlier(for: .claudeCode)   // 幂等:在途时 no-op;同步回喂 → 每轮复位后续下一窗
            guardCount += 1
        }
        #expect(loads == 3)                                  // 300→200→100→0,正好三窗(不死锁=非 1,不无限=非 100)
        #expect(!store.canLoadEarlier(for: .claudeCode))     // 终止在文件头
        #expect(!store.isLoadingEarlier(for: .claudeCode))   // flag 干净复位
        #expect(store.claudeItems.count == 4)                // 尾 + 3 更早
        #expect(store.claudeItems.first?.kind == .user(text: "早100"))   // 最后那窗(cursor=100)最早,排最前
    }

    @Test("cancelLoadingEarlier 解闸(App 端解析不到 URL 的兜底)→ 不卡死")
    func cancelLoadingEarlierUnsticks() {
        let store = AgentSessionStore()
        store.setHistory([e(.userPrompt(text: "x"), 1)], agent: .claudeCode, sessionId: "s",
                         startOffset: 500, reachedStart: false)
        store.onLoadEarlier = { _, _, _ in }   // 模拟 App 不调 prependHistory(URL 解析失败)
        store.loadEarlier(for: .claudeCode)
        #expect(store.isLoadingEarlier(for: .claudeCode))
        store.cancelLoadingEarlier(for: .claudeCode)         // App 兜底解闸
        #expect(!store.isLoadingEarlier(for: .claudeCode))
    }

    @Test("items rebuilt 回调携带 awaiting detail 回填后的最新 item")
    func itemsRebuiltCallbackCarriesUpdatedAwaitingDetail() {
        let store = AgentSessionStore()
        var rebuilt: [ConversationItem] = []
        store.onItemsRebuilt = { agent, items in
            if agent == .claudeCode { rebuilt = items }
        }
        store.appendLive(AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil,
                                    kind: .awaitingUser(reason: .question(title: "发布策略")),
                                    timestamp: Date(timeIntervalSince1970: 1),
                                    detail: "问题：怎么发?", toolUseId: "toolu_q"))
        store.appendLive(AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil,
                                    kind: .toolResult(name: "", isError: false),
                                    timestamp: Date(timeIntervalSince1970: 2),
                                    detail: #"{"answers":{"怎么发?":"先推分支"}}"#, toolUseId: "toolu_q"))

        #expect(rebuilt.count == 1)
        #expect(rebuilt[0].awaitingDetail?.contains("已选：先推分支") == true)
    }

    // MARK: - 待答队列(权限/问题,pet 旁权限侧卡)

    func makePending(id: String = UUID().uuidString, superseded: @escaping () -> Void = {}) -> PendingAction {
        PendingAction(
            id: id,
            model: PermissionCardModel(kind: .standard, title: "Bash", detail: "npm test"),
            onAllow: {}, onDeny: {}, onSelectOption: { _ in }, onSubmit: { _ in },
            onSuperseded: superseded
        )
    }

    @Test("addPending 入队,pendingQueue 取回;codex 永空")
    func addPending() {
        let store = AgentSessionStore()
        store.addPending(makePending())
        #expect(store.pendingQueue(for: .claudeCode).count == 1)
        #expect(store.pendingQueue(for: .codex).isEmpty)
    }

    @Test("多并发请求**并存不顶替**(旧的不被弃权;同 id 去重)")
    func multiplePendingCoexist() {
        let store = AgentSessionStore()
        var firstSuperseded = false
        let a = makePending(id: "a", superseded: { firstSuperseded = true })
        store.addPending(a)
        store.addPending(makePending(id: "b"))
        #expect(store.pendingQueue(for: .claudeCode).count == 2)   // 两个并存
        #expect(firstSuperseded == false)                          // 旧的不被顶替弃权
        store.addPending(makePending(id: "a"))                     // 同 id → 去重
        #expect(store.pendingQueue(for: .claudeCode).count == 2)
    }

    @Test("removePending 按 id 出队;clearAllPending 全弃权清空")
    func removeAndClearPending() {
        let store = AgentSessionStore()
        store.addPending(makePending(id: "a"))
        store.addPending(makePending(id: "b"))
        store.removePending(id: "a")
        #expect(store.pendingQueue(for: .claudeCode).map(\.id) == ["b"])
        var bSuperseded = false
        store.addPending(makePending(id: "c", superseded: { bSuperseded = true }))
        store.clearAllPending()
        #expect(store.pendingQueue(for: .claudeCode).isEmpty)
        #expect(bSuperseded)                                       // clearAll 给各 responder 弃权
    }

    @Test("tabBadge:无会话→none / 有活跃会话→active / 待答 / 末条 awaiting→awaiting")
    func tabBadgeStates() {
        let store = AgentSessionStore()
        #expect(store.tabBadge(for: .claudeCode) == .none)
        store.appendLive(e(.assistantText(text: "干活中"), 1))
        #expect(store.tabBadge(for: .claudeCode) == .active)
        store.appendLive(e(.awaitingUser(reason: .question(title: "选哪个")), 2))
        #expect(store.tabBadge(for: .claudeCode) == .awaiting)   // 末条在等你
        // 待答项也算 awaiting。
        let s2 = AgentSessionStore()
        s2.appendLive(e(.assistantText(text: "x"), 1))
        s2.addPending(makePending())
        #expect(s2.tabBadge(for: .claudeCode) == .awaiting)
    }

    @Test("P3.7-③ highlightedItemId 不被 rebuild 清掉(侧卡开着时新事件涌入仍保留源行高亮)")
    func highlightSurvivesRebuild() {
        let store = AgentSessionStore()
        store.highlightedItemId = 42
        // appendLive / setHistory 都会 rebuild —— 不该顺手清掉 highlightedItemId(由 App 侧卡生命周期管)。
        store.appendLive(e(.assistantText(text: "新事件"), 1))
        #expect(store.highlightedItemId == 42)
        store.setHistory([e(.userPrompt(text: "历史"), 0)], agent: .claudeCode, sessionId: "s")
        #expect(store.highlightedItemId == 42)
    }
}
