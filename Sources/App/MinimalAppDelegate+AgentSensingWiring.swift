import AgentSensing
import AppKit
import Rendering
import Shell
import os

extension MinimalAppDelegate {

    static let agentSensingLog = Logger(subsystem: "io.openpetagent", category: "AgentSensing.wiring")

    /// 感知层 ~1.5s 轮询间隔。比 30s 主动引擎密 —— 要的是「实时」感知编码会话。
    static let agentSensingPollInterval: TimeInterval = 1.5
    /// 「在跑什么」气泡节流:tool 事件可能每秒数颗,节流到这个间隔避免闪烁。
    static let agentSensingBubbleThrottle: TimeInterval = 2.5

    /// applicationDidFinishLaunching 末段调(bondedSession 就绪后)。构造感知 service、
    /// 把 transcript 事件接到桌宠气泡 + 一次性反应,起轮询 timer。
    ///
    /// **只读**:不改 settings.json、不起 server、与已装的其它 hook 工具零冲突。
    @MainActor
    func setupAgentSensing() {
        guard bondedSession != nil else { return }   // 气泡落点缺席 → 不构造

        let enabledNow = menuBarController.isAgentSensingEnabled
        let service = AgentSensingService(
            enabled: enabledNow,
            sink: { [weak self] output in
                // 跨 actor 边界:绑成 immutable let 再进 MainActor(Swift 6 SendableClosureCaptures)。
                let weakSelf = self
                await MainActor.run { weakSelf?.handleAgentSensingOutput(output) }
            }
        )
        self.agentSensingService = service
        Self.agentSensingLog.notice("AgentSensing 启动: enabled=\(enabledNow, privacy: .public)")

        // 陪伴卡片 Claude Code / Codex tab 的会话流:打开卡片时回填活跃会话历史(读 transcript 尾部)。
        // 文件读 off-main(Task.detached),拿到后在 MainActor 喂 store → tab 视图反应式更新。
        chatCardWindowController?.sessionHistoryLoader = { [weak self] in
            guard let self, let service = self.agentSensingService else { return }
            let urls = await service.activeSessionURLs()
            // 两个 agent 当前最活跃会话都回填历史尾部窗口(各用自己的 parser),带游标供 G4「加载更早」。
            for (agent, url) in urls {
                let window = await Task.detached { SessionHistoryReader.readRecentHistory(url: url, agent: agent) }.value
                guard !window.events.isEmpty else { continue }
                let sid = AgentSensingService.canonicalSessionId(from: url)
                self.loadedSessionURLs[agent, default: [:]][sid] = url   // 记住 URL 供「加载更早」(静默会话也能往前读)
                self.chatCardWindowController?.agentSessionStore.setHistory(
                    window.events,
                    agent: agent,
                    sessionId: sid,
                    startOffset: window.startOffset,
                    reachedStart: window.reachedStart
                )
                await self.scanSubagents(url: url, agent: agent)   // D2:扫该会话子 agent 索引
            }
        }

        // 会话切换:用户在 picker 选了某会话 → 把 sessionId 映射回 URL 读它的历史尾部窗口回填(带游标)。
        chatCardWindowController?.agentSessionStore.onSelectSession = { [weak self] agent, sid in
            // 切会话 → 关列容器(其内容/源行属旧会话,已失效)+ 清高亮。
            self?.columnContainerWindowController.close()
            self?.chatCardWindowController?.agentSessionStore.highlightedItemId = nil
            Task { @MainActor in
                guard let self else { return }
                // URL 优先用**记住的**(静默会话掉出 recentSessions 也能重读,同「加载更早」/「重置」)→ 回退 recentSessions。
                var url = self.loadedSessionURLs[agent]?[sid]
                if url == nil {
                    let refs = await self.agentSensingService?.recentSessions() ?? []
                    url = refs.first(where: { $0.agent == agent && $0.sessionId == sid })?.url
                }
                let store = self.chatCardWindowController?.agentSessionStore
                guard let url else { store?.markLoadFailed(agent, sessionId: sid); return }   // P2-10:找不到会话文件 → 失败态
                let window = await Task.detached { SessionHistoryReader.readRecentHistory(url: url, agent: agent) }.value
                guard !window.events.isEmpty else {
                    // P2-10:**文件不可读**(删除/权限)→ 真失败;可读但解析为空(全新/纯噪音会话)→ 中性空态,不误标失败。
                    if !FileManager.default.isReadableFile(atPath: url.path) { store?.markLoadFailed(agent, sessionId: sid) }
                    return
                }
                self.loadedSessionURLs[agent, default: [:]][sid] = url
                self.chatCardWindowController?.agentSessionStore.setHistory(
                    window.events, agent: agent, sessionId: sid,
                    startOffset: window.startOffset, reachedStart: window.reachedStart)
                await self.scanSubagents(url: url, agent: agent)   // D2:扫该会话子 agent 索引
            }
        }

        // P3.8 G4「加载更早」:从 store 给的最早游标往前读历史窗口,前插(prependHistory 保持稳定 id)。
        // **跳噪音窗**:attachment-heavy 文件某 256KB 窗口可能 0 可解析事件 → 在 off-main 循环往前读
        // 到拿到事件 / 到文件头 / 触上限(20 窗 ≈ 5MB),再一次 prepend,免「空窗但没到顶」卡住自动加载。
        chatCardWindowController?.agentSessionStore.onLoadEarlier = { [weak self] agent, sid, cursor in
            Task { @MainActor in
                guard let self else { return }
                // URL 优先用**记住的**(加载历史时存的)→ 静默会话(掉出 recentSessions)也能往前读;回退 recentSessions。
                var url = self.loadedSessionURLs[agent]?[sid]
                if url == nil {
                    let refs = await self.agentSensingService?.recentSessions() ?? []
                    url = refs.first(where: { $0.agent == agent && $0.sessionId == sid })?.url
                }
                guard let url else {
                    // 解析不到 URL(理论上不该发生)→ **解闸**,免卡死按钮 + 阻塞后续触发。
                    self.chatCardWindowController?.agentSessionStore.cancelLoadingEarlier(for: agent)
                    return
                }
                // 按**可见 turn 行**累积(非单字节窗):大型 agentic 日志一窗常只 ~1 个可见行(巨型 tool_result
                // 占字节却折进元数据),单窗加载只多 1 行、感官滚不动 → readEarlierRows 累到 ~minRows 行(2026-06-20)。
                let window = await Task.detached {
                    SessionHistoryReader.readEarlierRows(url: url, agent: agent, endOffset: cursor)
                }.value
                // 调试插桩(env-gated,生产零开销):量「每次加载更早多冒几个可见行 + 读多少字节」,验 32MB 预算效果。
                let debugLE = ProcessInfo.processInfo.environment["PETAGENT_DEBUG_LOADEARLIER"] != nil
                let before = debugLE ? (self.chatCardWindowController?.agentSessionStore.items(for: agent).count ?? 0) : 0
                self.chatCardWindowController?.agentSessionStore.prependHistory(
                    window.events, agent: agent, sessionId: sid,
                    startOffset: window.startOffset, reachedStart: window.reachedStart)
                if debugLE {
                    let after = self.chatCardWindowController?.agentSessionStore.items(for: agent).count ?? 0
                    let mb = Double(cursor >= window.startOffset ? cursor - window.startOffset : 0) / 1_048_576.0
                    NSLog("[SCROLLTEST] load-earlier: \(before)→\(after) 行 (+\(after - before)), 读 \(String(format: "%.1f", mb))MB, reachedStart=\(window.reachedStart)")
                }
            }
        }

        // 列容器(取代多窗口侧卡):主卡行点击 → openRoot 根列;列内行 → drillIn;切会话/点空白 → close;跟随主卡。
        columnContainerWindowController.onClosed = { [weak self] in
            self?.chatCardWindowController?.agentSessionStore.highlightedItemId = nil
        }
        // I-1:容器层级跟主卡钉住态(开容器时取当前态 + 主卡 toggle 时同步)→ 否则主卡浮顶、容器 .normal 切 Space 消失。
        columnContainerWindowController.mainPinnedProvider = { [weak self] in self?.chatCardWindowController?.isPinned ?? false }
        chatCardWindowController?.onPinChanged = { [weak self] pinned in self?.columnContainerWindowController.applyMainPinned(pinned) }
        // 列内列表行点击 → 据该列 subagentByItemId 算子列(Task/agent 行→子 agent transcript 子列;否则→detail 子列)。
        columnContainerWindowController.state.onListRowTapped = { [weak self] columnId, item in
            self?.drillIntoColumn(columnId: columnId, item: item)
        }

        // 点大内容 tool 行 / 长消息行 → detail 根列(总结轮转成 .assistant 全文)。
        chatCardWindowController?.agentSessionStore.onExpandToSide = { [weak self] rawItem in
            guard let self else { return }
            var item = rawItem
            if case .assistantTurn(let a) = rawItem.kind {
                guard !a.finalText.isEmpty else { return }
                item = ConversationItem(id: rawItem.id, kind: .assistant(text: a.finalText), timestamp: rawItem.timestamp)
            }
            self.chatCardWindowController?.agentSessionStore.highlightedItemId = item.id
            self.chatCardWindowController?.agentSessionStore.highlightedRegion = .primary
            self.columnContainerWindowController.openRoot(.detail(item: item), sourceKey: "detail:\(item.id)",
                besideMain: self.mainCardFrame(), screen: self.currentScreenFrame())
        }
        // 点元数据栏 → 元数据 steps 根列(思考/工具,不含总结)。
        chatCardWindowController?.agentSessionStore.onOpenTurnSteps = { [weak self] item in
            guard let self, case .assistantTurn(let a) = item.kind else { return }
            self.chatCardWindowController?.agentSessionStore.highlightedItemId = item.id
            self.chatCardWindowController?.agentSessionStore.highlightedRegion = .metadata
            let subtitle = "本轮 \(a.toolCount) 工具 · \(a.thinkingCount) 思考" + (a.durationText.map { " · " + $0 } ?? "")
            // 给 steps 列填子 agent 索引 → 列内 Task 行也挂 👥、点开经 drillIntoColumn 开子 agent 子列
            // (一轮多个子 agent 时,turn 行只携首个;steps 列才能逐个 drill)。
            let stepItems = a.stepsItems()
            var subBy: [Int: SubagentRef] = [:]
            if let store = self.chatCardWindowController?.agentSessionStore {
                for s in stepItems where s.toolUseId != nil {
                    if let ref = store.subagentRef(for: s.toolUseId) { subBy[s.id] = ref }
                }
            }
            self.columnContainerWindowController.openRoot(
                .list(items: stepItems, subagentByItemId: subBy, glyph: "sparkles",
                      title: a.shortModelName ?? "模型一轮", subtitle: subtitle),
                sourceKey: "steps:\(item.id)", besideMain: self.mainCardFrame(), screen: self.currentScreenFrame())
        }
        // #9:点 workflow 🧩 → workflow 衍生 agent 列表根列。
        chatCardWindowController?.agentSessionStore.onOpenWorkflow = { [weak self] runId in
            self?.openWorkflowColumn(runId: runId)
        }
        // 点主卡任意位置(空白/普通行)→ 关**所有**侧卡(列容器 + 浏览 sheet,统一 dismiss)。
        chatCardWindowController?.agentSessionStore.onBackgroundClick = { [weak self] in
            self?.dismissSideCards()
        }
        // P1-5:点用户行图片缩略图 → 图片根列。
        chatCardWindowController?.agentSessionStore.onOpenImage = { [weak self] att in
            guard let self else { return }
            self.columnContainerWindowController.openRoot(.image(data: att.data),
                sourceKey: "image:\(att.data.count):\(att.data.hashValue)",
                besideMain: self.mainCardFrame(), screen: self.currentScreenFrame())
        }
        // D2:点主卡 turn 行的 👥 子 agent 入口 → 开子 agent transcript **根列**。
        // (列容器重构 c470672 删多窗口侧卡时遗漏接线 → 此回调悬空、👥 入口被 gate 掉点不到;此处修复。)
        chatCardWindowController?.agentSessionStore.onOpenSubagent = { [weak self] item in
            guard let self,
                  let ref = self.chatCardWindowController?.agentSessionStore.subagentRef(for: item.toolUseId) else { return }
            self.openSubagentColumn(ref: ref, asRootSourceKey: "subagent:\(ref.toolUseId)", drillInto: nil, rowId: item.id)
        }

        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.agentSensingPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task {
                await self?.agentSensingService?.poll()
                await self?.refreshSessionMetadata()   // P3.8 G3:轮询后刷 picker 会话元数据
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.agentSensingTickTimer = timer
        wireSessionBrowseAndPin()          // 会话历史浏览 + 钉住:注入钉住 store + 接 picker 回调 + 启动加载钉住
        debugInjectSubagentIfRequested()   // env-gated:注入关联真实子 agent 的 Task 行,验 D2 pill + 卡
        debugOpenColumnIfRequested()       // env-gated:开 workflow / image 列,验这两条 drill-in 路径

        // 调试钩子(env `PETAGENT_DEBUG_LOADEARLIER`):启动后直接开 Claude Code tab,**走真实** sessionHistoryLoader
        // (读活跃会话尾部窗口带游标)→ 大会话(> 窗口)顶部出现「加载更早」可录。验 G4 增量加载 + 锚定不跳。
        if let leMode = ProcessInfo.processInfo.environment["PETAGENT_DEBUG_LOADEARLIER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.chatCardWindowController?.presentOnTab(.claudeCode)
                // `=auto`:会话载入后自动连点 4 次「加载更早」(每次间隔 1.5s 等上次 async 完成,re-entrancy 闸防叠)
                // → 每次 prependHistory 走上面插桩 NSLog 行数增量,免手动点击/像素定位。
                if leMode == "auto" {
                    for i in 1...4 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(i) * 1.5) { [weak self] in
                            self?.chatCardWindowController?.agentSessionStore.loadEarlier(for: .claudeCode)
                        }
                    }
                }
            }
        }

        // 调试钩子(env `PETAGENT_DEBUG_CODEX`):启动后直接开 **Codex tab**,**走真实** polling 加载的 codex
        // 会话(recomputeSelection 粘滞初选最近活跃)→ 验 Codex transcript 渲染(收尾问句不再三重渲染、
        // 注入噪音不再冒充用户消息等)。延迟 4s 等首两轮 poll 把真实会话载入。用法见 docs/development-guide.md。
        if ProcessInfo.processInfo.environment["PETAGENT_DEBUG_CODEX"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.chatCardWindowController?.presentOnTab(.codex)
            }
        }

        // 调试钩子(env `PETAGENT_DEBUG_SIDECARD`):启动后注入一条合成 sideCard 行 → 高亮它(触发它上报
        // 全局 midY)→ 按**精确源行 y** present 侧卡。**忠实**:beak 指向 = halo 行 = sourceRowY 三者重合
        // (用高亮行自报的 midY 算 sourceRowY,而非鼠标/猜测)。绕开「实时找 sideCard 行 + 像素点击」的脆弱验证。
        // 用法见 docs/development-guide.md。(注:注入的 DebugBash 行留在当前会话直到重启 app —— debug-only。)
        if ProcessInfo.processInfo.environment["PETAGENT_DEBUG_SIDECARD"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                self.chatCardWindowController?.presentOnTab(.claudeCode)
                let store = self.chatCardWindowController?.agentSessionStore
                let sid = store?.selectedSession(for: .claudeCode) ?? "debug-sidecard"
                let now = Date()
                func ev(_ k: AgentEventKind, _ dt: Double, _ detail: String? = nil) -> AgentEvent {
                    AgentEvent(agent: .claudeCode, sessionId: sid, cwd: nil, kind: k, timestamp: now.addingTimeInterval(dt), detail: detail)
                }
                // 注入小对话:全宽 user/assistant 气泡 + Edit diff(着色)+ 一条很长 assistant(折叠→侧卡)→ 验 G1/G2/diff。
                store?.appendLive(ev(.compactBoundary, -0.005))   // 验 /compact「上下文已压缩」分割线(置顶)
                store?.appendLive(ev(.userPrompt(text: "把计数器初始值从 0 改成 1,increment 改成 +2,顺便加个 reset()。这段说明也写长一点好测试消息行展开:lorem ipsum dolor sit amet, consectetur adipiscing elit."), 0))
                store?.appendLive(ev(.assistantText(text: "好的,我来改 `Counter.swift`:把 `count` 初值改成 1、`increment()` 步长改成 2,并新增 `reset()`。"), 0.01))
                let diff = ["- var count = 0", "+ var count = 1", "- func increment() {", "-     count += 1", "- }", "+ func increment() {", "+     count += 2", "+ }", "+ func reset() {", "+     count = 0", "+ }", "- // old comment", "+ // updated comment", "+ // extra line for sideCard"].joined(separator: "\n")
                store?.appendLive(ev(.toolUse(name: "Edit", summary: "Counter.swift"), 0.02, diff))
                store?.appendLive(ev(.toolResult(name: "", isError: false), 0.03, "已更新 Counter.swift(3 处改动)"))
                // 很长 assistant(markdown,>24 行)→ detailAffordance .sideCard → 主卡折叠 + ⤢,开它的侧卡看全文。
                let longMd = (["## 改动说明", "", "我已经完成了对 `Counter.swift` 的三处修改:", ""]
                    + (1...26).map { "\($0). 第 \($0) 条改动说明,这里写一些 **markdown** 文本来撑长内容,验证折叠与侧卡 markdown 渲染。" }).joined(separator: "\n")
                store?.appendLive(ev(.assistantText(text: longMd), 0.04))
                // P3.8 G3:再注入第二个会话 + 给两会话推元数据(标题/分支/消息数)→ 顶部 picker 可录。
                let sid2 = sid + "-b"
                store?.appendLive(AgentEvent(agent: .claudeCode, sessionId: sid2, cwd: "/Users/me/projects/sample",
                                             kind: .assistantText(text: "另一个会话在跑测试"), timestamp: now.addingTimeInterval(-300)))
                store?.updateMetadata([
                    sid: SessionMetadata(title: "改 Counter 初值与步长", projectName: "pet-agent",
                                         startTime: now.addingTimeInterval(-600), gitBranch: "feature/proactive",
                                         messageCount: 42, lastModified: now),
                    sid2: SessionMetadata(title: "修复登录流程超时", projectName: "other-proj",
                                          startTime: now.addingTimeInterval(-1200), gitBranch: "main",
                                          messageCount: 17, lastModified: now.addingTimeInterval(-300)),
                ], agent: .claudeCode)
                // 列容器验证:开元数据 steps 根列 → +0.7s drill-in 一条真实 tool 行成 detail 子列(横向平铺)。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard let row = store?.items(for: .claudeCode).last, case .assistantTurn(let a) = row.kind else { return }
                    store?.onOpenTurnSteps?(row)
                    let toolStep = a.stepsItems().first { if case .tool = $0.kind { return true }; return false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        if let toolStep, let col = self.columnContainerWindowController.state.stack.columns.first {
                            self.columnContainerWindowController.drillIn(columnId: col.id, rowId: toolStep.id, into: .detail(item: toolStep))
                        }
                    }
                }
            }
        }
    }

    /// P3.8 G3:轮询后刷 picker 会话元数据(标题/分支/消息数)。扫描在 `SessionMetadataScanner` actor
    /// 上跑(off-main,await 期间不阻塞主线程),按 (path,mtime,size) 缓存 → 文件没变只 stat。
    /// 结果推给 store **只刷 picker 列表**(不动会话流 items)。无活跃会话 → 推空(picker 回退裸 sessionId)。
    @MainActor
    func refreshSessionMetadata() async {
        // 调试模式注入的是合成会话(无真实文件)→ 跳过实时刷新,免 replace 语义冲掉注入的 picker 元数据。
        if ProcessInfo.processInfo.environment["PETAGENT_DEBUG_SIDECARD"] != nil { return }
        guard let service = agentSensingService,
              let store = chatCardWindowController?.agentSessionStore else { return }
        let refs = await service.recentSessions()
        var byAgent: [AgentKind: [String: SessionMetadata]] = [:]
        for ref in refs {
            // 缓存 URL:会话还活跃时就记住,**转静默掉出 `recentSessions` 后**切过去/刷新仍能解析加载
            // (#3「激活会话变未激活 → 切过去刷新加载不了」根因:URL 只在「最活跃/已选中」时才记,普通活跃会话漏记)。
            loadedSessionURLs[ref.agent, default: [:]][ref.sessionId] = ref.url
            if let meta = await agentSessionMetadataScanner.metadata(for: ref.url, agent: ref.agent) {
                byAgent[ref.agent, default: [:]][ref.sessionId] = meta
            }
        }
        store.updateMetadata(byAgent[.claudeCode] ?? [:], agent: .claudeCode)
        store.updateMetadata(byAgent[.codex] ?? [:], agent: .codex)
    }

    /// 调试钩子(env `PETAGENT_DEBUG_SUBAGENT`):找磁盘上**真实有子 agent 的会话**,注入一条 Task 行(toolUseId
    /// 对上真实 ref)+ 并入索引 → 会话流 Task 行出现「子 agent」入口,点开加载**真实子 agent transcript**。
    /// 值=`open` 时注入后 +2s 自动点开子 agent 卡(免坐标点击)。用法见 dev-guide。
    @MainActor
    func debugInjectSubagentIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["PETAGENT_DEBUG_SUBAGENT"] else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let store = self.chatCardWindowController?.agentSessionStore,
                  let ref = await Task.detached(operation: { MinimalAppDelegate.findAnySubagent() }).value else { return }
            let sid = "dbg-subagent"
            let base = Date()
            store.appendLive(AgentEvent(agent: .claudeCode, sessionId: sid, cwd: "/Users/me/projects/sample",
                kind: .userPrompt(text: "派个子 agent 审一下这块代码"), timestamp: base))
            store.appendLive(AgentEvent(agent: .claudeCode, sessionId: sid, cwd: "/Users/me/projects/sample",
                kind: .toolUse(name: "Task", summary: ref.description.isEmpty ? ref.agentType : ref.description),
                timestamp: base.addingTimeInterval(0.01), detail: "subagent_type: \(ref.agentType)", toolUseId: ref.toolUseId))
            store.updateSubagentIndex([ref.toolUseId: ref])
            self.chatCardWindowController?.presentOnTab(.claudeCode)
            if mode == "open" {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                store.onOpenSubagent?(store.items(for: .claudeCode).last { if case .tool = $0.kind { return true }; return false } ?? store.items(for: .claudeCode).last!)
            }
        }
    }

    /// 扫 `~/.claude/projects/*/<sid>/subagents/` 找任意一个真实子 agent(给调试用)。nonisolated 供 off-main。
    nonisolated static func findAnySubagent() -> SubagentRef? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projDirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for proj in projDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let map = SubagentIndex.scan(sessionURL: dir.appendingPathExtension("jsonl"))
                if let ref = map.values.first(where: { FileManager.default.fileExists(atPath: $0.transcriptURL.path) }) { return ref }
            }
        }
        return nil
    }

    /// 调试钩子(env `PETAGENT_DEBUG_COLUMN`):`image` → 合成图片开**图片列**;`workflow` → 扫盘找真实
    /// workflow run 开**衍生 agent 列表列**。验列容器这两条 drill-in 路径(子 agent 路径走 `PETAGENT_DEBUG_SUBAGENT`)。
    @MainActor
    func debugOpenColumnIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["PETAGENT_DEBUG_COLUMN"] else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self else { return }
            self.chatCardWindowController?.presentOnTab(.claudeCode)
            let mainF = self.mainCardFrame(), screen = self.currentScreenFrame()
            if mode == "image", let data = Self.debugSyntheticPNG() {
                self.columnContainerWindowController.openRoot(.image(data: data),
                    sourceKey: "dbg-image", besideMain: mainF, screen: screen)
            } else if mode == "workflow",
                      let found = await Task.detached(operation: { MinimalAppDelegate.findAnyWorkflowRun() }).value {
                let refs = await Task.detached { SubagentIndex.scanWorkflowRun(sessionURL: found.0, runId: found.1) }.value
                var items: [ConversationItem] = []; var subBy: [Int: SubagentRef] = [:]
                for (i, ref) in refs.enumerated() {
                    items.append(ConversationItem(id: i, kind: .tool(name: "Agent", summary: ref.agentType, state: .ok, input: nil, output: nil),
                                                  timestamp: Date(timeIntervalSince1970: TimeInterval(i)), toolUseId: ref.toolUseId))
                    subBy[i] = ref
                }
                self.columnContainerWindowController.openRoot(
                    .list(items: items, subagentByItemId: subBy, glyph: "puzzlepiece.extension.fill",
                          title: "Workflow", subtitle: "\(refs.count) 个衍生 agent"),
                    sourceKey: "dbg-workflow", besideMain: mainF, screen: screen)
            }
        }
    }

    /// 调试用合成 PNG(青色块 + 白内框),验图片列渲染。直接画进 `NSBitmapImageRep`(离屏可靠,
    /// 不用 `NSImage.lockFocus` —— 后者无窗口上下文时常产出空白)。
    nonisolated static func debugSyntheticPNG() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 400, height: 300).fill()
        NSColor.white.setFill(); NSRect(x: 40, y: 40, width: 320, height: 220).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// 扫盘找任意一个真实 workflow run(含 ≥1 个 agent-*.jsonl)→ (会话 jsonl url, runId)。给调试。
    nonisolated static func findAnyWorkflowRun() -> (URL, String)? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projDirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for proj in projDirs {
            guard let sessions = try? FileManager.default.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for sess in sessions where (try? sess.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let wfDir = sess.appendingPathComponent("subagents").appendingPathComponent("workflows")
                guard let runs = try? FileManager.default.contentsOfDirectory(at: wfDir, includingPropertiesForKeys: nil) else { continue }
                for run in runs where run.lastPathComponent.hasPrefix("wf_") {
                    if let files = try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil),
                       files.contains(where: { $0.lastPathComponent.hasPrefix("agent-") }) {
                        return (sess.appendingPathExtension("jsonl"), run.lastPathComponent)
                    }
                }
            }
        }
        return nil
    }

    /// 主卡窗口 frame（列容器贴它定位）。
    @MainActor
    func mainCardFrame() -> NSRect { chatCardWindowController?.window?.frame ?? .zero }

    /// 列内列表行点击 → 算子列并 drillIn:该列 `subagentByItemId` 命中(Task/agent 行)→ 子 agent transcript 子列(异步);
    /// 否则(tool / 长文本行)→ detail 子列。
    @MainActor
    func drillIntoColumn(columnId: Int, item: ConversationItem) {
        let col = columnContainerWindowController.state.stack.columns.first { $0.id == columnId }
        if case .list(_, let subBy, _, _, _) = col?.kind, let ref = subBy[item.id] {
            openSubagentColumn(ref: ref, asRootSourceKey: nil, drillInto: columnId, rowId: item.id)
            return
        }
        columnContainerWindowController.drillIn(columnId: columnId, rowId: item.id, into: .detail(item: item))
    }

    /// 开子 agent transcript 列(off-main 读+解析）。`asRootSourceKey != nil` → openRoot 根列;否则 drillInto 指定列追加。
    @MainActor
    func openSubagentColumn(ref: SubagentRef, asRootSourceKey: String?, drillInto columnId: Int?, rowId: Int) {
        let mainF = mainCardFrame(), screen = currentScreenFrame()
        let url = ref.transcriptURL
        Task { @MainActor in
            let events = await Task.detached { MinimalAppDelegate.readSubagentEvents(url: url) }.value
            let items = AgentConversation.build(from: events)
            let kind = ColumnKind.list(items: items, subagentByItemId: [:],
                                       glyph: "person.2.fill", title: ref.agentType, subtitle: ref.description)
            if let key = asRootSourceKey {
                self.chatCardWindowController?.agentSessionStore.highlightedItemId = nil
                self.columnContainerWindowController.openRoot(kind, sourceKey: key, besideMain: mainF, screen: screen)
            } else if let columnId {
                // I-3:columnId 在 await 前捕获,异步期间用户可能 openRoot/截断栈使其失效 → drillIn 内 firstIndex 找不到则静默丢弃(安全)。
                self.columnContainerWindowController.drillIn(columnId: columnId, rowId: rowId, into: kind)
            }
        }
    }

    /// 开 workflow 衍生 agent 列表列(#9)。列的 `subagentByItemId` 挂各衍生 agent ref → 点行经 `drillIntoColumn` 开其 transcript 子列。
    @MainActor
    func openWorkflowColumn(runId: String) {
        let agent = AgentKind.claudeCode
        guard let store = chatCardWindowController?.agentSessionStore,
              let sid = store.selectedSession(for: agent),
              let url = loadedSessionURLs[agent]?[sid] else { return }
        let mainF = mainCardFrame(), screen = currentScreenFrame()
        Task { @MainActor in
            let refs = await Task.detached { SubagentIndex.scanWorkflowRun(sessionURL: url, runId: runId) }.value
            var items: [ConversationItem] = []
            var subBy: [Int: SubagentRef] = [:]
            for (i, ref) in refs.enumerated() {
                items.append(ConversationItem(id: i, kind: .tool(name: "Agent", summary: ref.agentType, state: .ok, input: nil, output: nil),
                                              timestamp: Date(timeIntervalSince1970: TimeInterval(i)), toolUseId: ref.toolUseId))
                subBy[i] = ref
            }
            self.columnContainerWindowController.openRoot(
                .list(items: items, subagentByItemId: subBy, glyph: "puzzlepiece.extension.fill",
                      title: "Workflow", subtitle: "\(refs.count) 个衍生 agent"),
                sourceKey: "workflow:\(runId)", besideMain: mainF, screen: screen)
        }
    }

    /// D2:扫某 Claude 会话的 `subagents/` 目录(off-main)→ 并入 store 子 agent 索引。Codex 无此结构 → 跳过。
    @MainActor
    func scanSubagents(url: URL, agent: AgentKind) async {
        guard agent == .claudeCode else { return }
        let map = await Task.detached { SubagentIndex.scan(sessionURL: url) }.value
        chatCardWindowController?.agentSessionStore.updateSubagentIndex(map)
    }

    /// D2:读子 agent transcript(`agent-{id}.jsonl`)→ 解析成事件(有界 2000 行,防超大)。nonisolated 供 off-main。
    nonisolated static func readSubagentEvents(url: URL) -> [AgentEvent] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let parser = ClaudeTranscriptParser()
        var events: [AgentEvent] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            // 一行可能多事件(assistant 既叙述又调工具,P0-2)。子 agent transcript 每行都是 isSidechain,
            // 走 `parseSubagentLine`(保留 sidechain),否则被主流过滤器滤光、body 全空(2026-06-19 修)。
            events.append(contentsOf: parser.parseSubagentLine(String(line)))
            if events.count >= 2000 { break }   // 有界,防超大子 agent 卡死
        }
        return events
    }

    /// 一条感知产出 → 桌宠反应:气泡说「在干嘛」+ 状态跃迁触发一次性招牌动作。
    @MainActor
    func handleAgentSensingOutput(_ output: AgentSensingService.Output) {
        // 静默检测合成的 idle 不是真 transcript 事件:**只**把活动视觉态切回 idle,
        // 不进会话流 / 不发招牌 / 不出气泡(否则每次会话停手都注入假「✅ 完成一轮」)。
        if output.isSilenceIdle {
            applyActivityEvent(output.event)   // 合成 .done 事件 → idle 视觉态
            return
        }
        Self.agentSensingLog.debug("感知: \(String(describing: output.event.kind), privacy: .public) [\(output.event.projectName ?? "?", privacy: .public)]")
        // 实时事件转发给陪伴卡片会话流 store(按 event.agent 路由 claude/codex,卡片关着也照常累积)。
        chatCardWindowController?.agentSessionStore.appendLive(output.event)
        dispatchAgentSignature(for: output.transition)
        // 把**原始事件**映射成 petdex 状态行(原汁原味:read/grep→review、出错→failed、user prompt→jumping、
        //  生成文本不改态)。transient 边沿(awaitingUser→acknowledge / idle→celebrate)仍由 dispatchAgentSignature 处理。
        applyActivityEvent(output.event)
        guard let text = Self.agentBubbleText(for: output.event) else { return }
        injectAgentBubble(text, projectName: output.event.projectName, kind: output.event.kind)
    }

    /// 把**原始 AgentEvent** 经 petdex 官方映射成视觉态(防抖后)推给当前形象。真事件 / 静默合成 idle 共用。
    @MainActor
    private func applyActivityEvent(_ event: AgentEvent) {
        guard let visual = AgentActivityVisualMapper.visual(forEvent: event) else { return }   // nil = 不改态
        if let shown = activityCoalescer.submit(visual, now: ProcessInfo.processInfo.systemUptime) {
            shellController?.applyPetActivity(shown)
        }
    }

    // MARK: - 气泡

    /// 事件 → 一行气泡文案。只展示「具体动作」(工具 / 等你 / 完成),`nil` = 不出气泡
    /// (userPrompt 是你自己敲的、assistantText 太碎 —— 留给状态/动作通道)。
    static func agentBubbleText(for event: AgentEvent) -> String? {
        switch event.kind {
        case .toolUse(_, let summary):
            return "⚡ " + summary
        case .awaitingUser(let reason):
            switch reason {
            case .question(let title):    return "🔔 在等你回答:" + title
            case .permission(let tool):   return "🔔 在等你确认:" + tool
            case .notification(let msg):  return "🔔 " + msg
            }
        case .done:
            return "✅ 完成一轮"
        case .userPrompt, .assistantText, .thinking, .toolResult, .sessionStart, .interrupted, .compactBoundary:
            return nil   // 思考/中断/压缩边界不出 pet 气泡(太碎/无动作语义)
        }
    }

    /// 注入气泡。tool 事件高频 → 节流;等你/完成是关键事件 → 不节流,立刻显示。
    @MainActor
    private func injectAgentBubble(_ text: String, projectName: String?, kind: AgentEventKind) {
        let isImportant: Bool
        switch kind {
        case .awaitingUser, .done: isImportant = true
        default:                   isImportant = false
        }
        let now = Date()
        if !isImportant, let last = agentSensingLastBubbleAt,
           now.timeIntervalSince(last) < Self.agentSensingBubbleThrottle {
            return   // 节流期内的普通 tool 气泡丢弃(签名/状态已照常走)
        }
        agentSensingLastBubbleAt = now
        let context = projectName ?? "编码会话"
        bondedSession?.injectProactiveSuggestion(context: context, reply: text) { _ in }
    }

    // MARK: - 一次性招牌动作(不抢 chat 状态机,只发不持久的瞬时反应)

    @MainActor
    private func dispatchAgentSignature(for transition: AgentActivityTracker.Transition?) {
        guard let transition, let shell = shellController else { return }
        switch transition.to {
        case .awaitingUser:
            shell.dispatchSignature(.acknowledge)   // 抬头看你:有事等你
        case .idle where transition.from != nil:
            shell.dispatchSignature(.celebrate)      // 从忙转闲 = 干完一轮,庆祝
        default:
            break
        }
    }
}
