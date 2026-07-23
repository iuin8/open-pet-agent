import Testing
import Foundation
@testable import AgentSensing

/// `AgentConversation.buildTurns` —— 事件 → 轮次(turn 模型,借 claude-devtools AIGroup)。
@Suite("buildTurns — 事件折叠成轮次")
struct ConversationTurnTests {

    let t0 = Date(timeIntervalSince1970: 1000)
    func ev(_ kind: AgentEventKind, _ dt: Double, detail: String? = nil, tool: String? = nil,
            usage: TokenUsage? = nil, model: String? = nil, agent: AgentKind = .claudeCode) -> AgentEvent {
        AgentEvent(agent: agent, sessionId: "s", cwd: nil, kind: kind,
                   timestamp: t0.addingTimeInterval(dt), detail: detail, toolUseId: tool, usage: usage, model: model)
    }

    @Test("user → thinking → tool → result → final text:1 用户轮 + 1 助手轮")
    func basicTurn() {
        let usage = TokenUsage(input: 100, output: 50, cacheRead: 200, cacheCreation: 300)
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "改超时"), 0),
            ev(.thinking(text: "先看配置"), 1),
            ev(.toolUse(name: "Edit", summary: "Auth.swift"), 2, detail: "- a\n+ b"),
            ev(.toolResult(name: "", isError: false), 3, detail: "已改"),
            ev(.assistantText(text: "改完了,3 处"), 4, usage: usage, model: "claude-opus-4-8"),
        ])
        #expect(turns.count == 2)
        #expect(turns[0].kind == .user(text: "改超时"))
        guard case .assistant(let a) = turns[1].kind else { Issue.record("应是 assistant 轮"); return }
        #expect(a.finalText == "改完了,3 处")
        #expect(a.toolCount == 1)
        #expect(a.thinkingCount == 1)
        #expect(a.steps.count == 2)                    // thinking + tool(末条 text 提升为 finalText 不入 steps)
        #expect(a.model == "claude-opus-4-8")
        #expect(a.contextTokens == 100 + 200 + 300)    // input+cacheRead+cacheCreation
        #expect(a.hasError == false)
        #expect(a.isRunning == false)
        // tool step 收尾成 .ok + 带 output
        if case .tool(_, let n, _, let st, _, let out, _) = a.steps[1] {
            #expect(n == "Edit" && st == .ok && out == "已改")
        } else { Issue.record("steps[1] 应是收尾的 tool") }
    }

    @Test("**P0-2** 端到端:中间叙述(text+tool 同条 message 拆出)并入 finalText,不再丢/不被埋元数据")
    func midTurnNarrationSurvives() {
        // parser 把 [text, tool_use] 拆成 assistantText + toolUse 两事件 → 折叠后:
        // 本轮全部文字「让我跑下测试」+「测试通过了」都并入 finalText(2026-06-19 修:不再把中间叙述埋进元数据 step)。
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "跑下测试"), 0),
            ev(.assistantText(text: "让我跑下测试"), 1),     // 中间叙述(旧实现会被同条 toolUse 吞掉)
            ev(.toolUse(name: "Bash", summary: "swift test"), 1, detail: "swift test"),
            ev(.toolResult(name: "", isError: false), 2, detail: "all pass"),
            ev(.assistantText(text: "测试通过了"), 3),       // 末条 text
        ])
        guard case .assistant(let a) = turns[1].kind else { Issue.record("应是 assistant 轮"); return }
        #expect(a.finalText == "让我跑下测试\n\n测试通过了")   // 全部文字按序拼接,中间叙述不被埋
        // text 段全部移出 steps(不被工具吞、也不留在元数据时间线)→ steps 只剩工具
        #expect(!a.steps.contains { if case .text = $0 { return true }; return false })
        #expect(a.steps.count == 1)   // 仅 tool
    }

    @Test("**P0-2** 并行工具:tool_result 按 tool_use_id 精确配对(FIFO 回传也不张冠李戴)")
    func parallelToolsPairById() {
        // 一条 assistant message 并行两个 tool_use(t1,t2)→ 两 running 步;结果**按 FIFO** 回传
        // (t1 的 result 先到)。纯 LIFO 位置配对会把 t1 的 output 挂到 t2 → 这里验精确按 id 配对。
        let turns = AgentConversation.buildTurns(from: [
            ev(.toolUse(name: "Read", summary: "A.swift"), 0, detail: "/a/A.swift", tool: "t1"),
            ev(.toolUse(name: "Read", summary: "B.swift"), 0, detail: "/a/B.swift", tool: "t2"),
            ev(.toolResult(name: "", isError: false), 1, detail: "AAA", tool: "t1"),  // FIFO:t1 先回
            ev(.toolResult(name: "", isError: true), 1, detail: "BBB", tool: "t2"),
        ])
        guard case .assistant(let a) = turns[0].kind else { Issue.record("应是 assistant 轮"); return }
        #expect(a.steps.count == 2)
        // t1 → output AAA + ok;t2 → output BBB + error(不互换)
        for step in a.steps {
            guard case .tool(_, _, let summary, let state, _, let output, let tid) = step else { continue }
            if tid == "t1" { #expect(summary == "A.swift" && output == "AAA" && state == .ok) }
            if tid == "t2" { #expect(summary == "B.swift" && output == "BBB" && state == .error) }
        }
    }

    @Test("**Codex 双发去重**:相邻同文字 user/assistant(event_msg + response_item)折一条;非相邻/不同不折")
    func dedupAdjacentDoubleSend() {
        // 新版 codex 同段双发:assistant 「答」两次相邻 + user 「问」两次相邻 → 各保一条。
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "问"), 0),
            ev(.userPrompt(text: "问"), 1),            // 相邻重复(event_msg vs response_item)→ 去
            ev(.assistantText(text: "答"), 2),
            ev(.assistantText(text: "答"), 3),         // 相邻重复 → 去
        ])
        #expect(turns.count == 2)                      // 1 user 轮 + 1 assistant 轮(非 2+2)
        guard case .assistant(let a) = turns[1].kind else { Issue.record("应是 assistant 轮"); return }
        #expect(a.finalText == "答")
        // 非相邻(工具隔开)同文字 → **不**去重(是模型真说了两次)→ 两条都并入 finalText
        let t2 = AgentConversation.buildTurns(from: [
            ev(.assistantText(text: "在跑"), 0),
            ev(.toolUse(name: "exec", summary: "x"), 1),
            ev(.assistantText(text: "在跑"), 2),       // 被工具隔开 → 保留
        ])
        guard case .assistant(let a2) = t2[0].kind else { Issue.record("应是 assistant 轮"); return }
        #expect(a2.finalText == "在跑\n\n在跑")   // 两条「在跑」都在(全部文字拼进 finalText)
    }

    @Test("**P1-8** Codex:token_count(.sessionStart 携 usage)→ 进行中轮 attach contextTokens(统一口径)")
    func codexTokenCountAttachesContext() {
        let usage = TokenUsage(input: 38861, output: 54, cacheRead: 512, cacheCreation: 0)
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "q"), 0),
            ev(.assistantText(text: "答"), 1),            // 本轮可见事件 → firstId 置位
            ev(.sessionStart, 2, usage: usage),           // token_count 映射的 .sessionStart 携本轮 usage
        ])
        guard case .assistant(let a) = turns[1].kind else { Issue.record("应是 assistant 轮"); return }
        #expect(a.contextTokens == 38861 + 512)           // = input + cached(对齐 Claude input+cacheRead+cacheCreation)
    }

    @Test("P1-8:.sessionStart 携 usage 但无进行中轮(firstId nil)→ 不启空轮、不影响")
    func sessionStartUsageNoTurn() {
        let usage = TokenUsage(input: 100, output: 1, cacheRead: 0, cacheCreation: 0)
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "q"), 0),
            ev(.sessionStart, 1, usage: usage),   // 紧跟 user、无 assistant → firstId nil → 跳过
        ])
        #expect(turns.count == 1)                 // 只 user 轮,无空 assistant 轮
        #expect(turns[0].kind == .user(text: "q"))
    }

    @Test("**P1-6** 中断:进行中的轮(running 工具)被中断 → wasInterrupted + 不再 isRunning")
    func interruptedTurnMarked() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "跑测试"), 0),
            ev(.toolUse(name: "Bash", summary: "swift test"), 1, detail: "swift test"),  // 工具开跑没收尾
            ev(.interrupted, 2),                                                          // 用户中断
        ])
        guard case .assistant(let a) = turns[1].kind else { Issue.record("应是 assistant 轮"); return }
        #expect(a.wasInterrupted)
        #expect(a.isRunning == false)   // 被中断 → 不再永远「正在思考…」
        #expect(a.toolCount == 1)       // 工具步骤保留(那条 running 工具仍在时间线)
    }

    @Test("P1-6:bare 中断(无进行中的轮)→ 不造空标记轮(避免连续中断刷屏)")
    func bareInterruptionMakesNoTurn() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "q"), 0),
            ev(.interrupted, 1),        // 紧跟 user、无 assistant 进行中
            ev(.interrupted, 2),
        ])
        #expect(turns.count == 1)       // 只有那条 user 轮,没有空的中断标记轮
        #expect(turns[0].kind == .user(text: "q"))
    }

    @Test("无 toolUseId(Codex)→ 退 LIFO 配对(单 running 工具仍正确)")
    func noIdFallsBackToLIFO() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.toolUse(name: "exec", summary: "ls"), 0, detail: "ls"),          // 无 tool id
            ev(.toolResult(name: "", isError: false), 1, detail: "out"),          // 无 tool id → LIFO
        ])
        guard case .assistant(let a) = turns[0].kind else { Issue.record("应是 assistant 轮"); return }
        if case .tool(_, _, _, let state, _, let output, _) = a.steps[0] {
            #expect(state == .ok && output == "out")
        } else { Issue.record("应收尾 tool") }
    }

    @Test("turn.id = 轮首事件 id;idStart 透传(prepend 稳定)")
    func idStability() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "q"), 0),
            ev(.toolUse(name: "Bash", summary: "x"), 1),
            ev(.assistantText(text: "a"), 2),
        ], idStart: 10)
        #expect(turns[0].id == 10)   // user 轮 = userPrompt 事件 id
        #expect(turns[1].id == 11)   // assistant 轮 = 轮首(toolUse)事件 id
    }

    @Test("工具报错 → hasError;末步 running 无 final text → isRunning")
    func errorAndRunning() {
        let errTurns = AgentConversation.buildTurns(from: [
            ev(.toolUse(name: "Bash", summary: "x"), 0),
            ev(.toolResult(name: "", isError: true), 1),
            ev(.assistantText(text: "失败了"), 2),
        ])
        guard case .assistant(let a) = errTurns[0].kind else { Issue.record("assistant"); return }
        #expect(a.hasError == true && a.isRunning == false)

        let running = AgentConversation.buildTurns(from: [
            ev(.toolUse(name: "Bash", summary: "y"), 0),   // 未收尾、无 final text
        ])
        guard case .assistant(let b) = running[0].kind else { Issue.record("assistant"); return }
        #expect(b.isRunning == true && b.finalText.isEmpty)
    }

    @Test("Task 工具 → toolUseId 保留在具体 step item,不 hoist 到 assistant turn item")
    func subagentIdsStayOnToolStepItems() {
        let items = AgentConversation.buildTurnItems(from: [
            ev(.toolUse(name: "Task", summary: "审"), 0, tool: "toolu_1"),
            ev(.assistantText(text: "派完了"), 1),
        ])
        guard case .assistantTurn(let a) = items[0].kind else { Issue.record("assistantTurn"); return }
        #expect(items[0].toolUseId == nil)
        #expect(a.stepsItems().first?.toolUseId == "toolu_1")
    }

    @Test("本轮全部 text 段拼成 finalText(中间叙述不被埋进元数据 step)")
    func intermediateText() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.assistantText(text: "我先看看"), 0),
            ev(.toolUse(name: "Read", summary: "f"), 1),
            ev(.toolResult(name: "", isError: false), 2),
            ev(.assistantText(text: "看完了,结论是…"), 3),
        ])
        guard case .assistant(let a) = turns[0].kind else { Issue.record("assistant"); return }
        #expect(a.finalText == "我先看看\n\n看完了,结论是…")   // 中间叙述 + 末条都进 finalText
        #expect(!a.steps.contains { if case .text = $0 { return true }; return false })   // text 全不入 steps
        #expect(a.steps.count == 1)   // 仅 tool
    }

    @Test("/compact 边界事件 → 收尾当前轮 + 插独立 compactBoundary 分割线行")
    func compactBoundaryFlushesAndInserts() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "问"), 0),
            ev(.assistantText(text: "答"), 1),
            ev(.compactBoundary, 2),
            ev(.userPrompt(text: "压缩后再问"), 3),
        ])
        #expect(turns.count == 4)                       // user 轮 + assistant 轮 + 边界行 + user 轮
        #expect(turns[2].kind == .compactBoundary)      // 边界独立成行,不折进任何轮
        guard case .assistant(let a) = turns[1].kind else { Issue.record("轮1应是 assistant"); return }
        #expect(a.finalText == "答")                    // 边界前的轮正常收尾
    }

    @Test("/compact 命令紧跟 compactBoundary → 折成单条压缩边界行")
    func compactCommandFoldsIntoBoundary() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "/compact"), 0),
            ev(.compactBoundary, 1, detail: "旧上下文摘要"),
            ev(.assistantText(text: "继续"), 2),
        ])
        #expect(turns.count == 2)
        #expect(turns[0].kind == .compactBoundary)
        #expect(turns[0].compactSummary == "旧上下文摘要")
        guard case .assistant(let a) = turns[1].kind else { Issue.record("compact 后应保留 assistant 轮"); return }
        #expect(a.finalText == "继续")
    }

    @Test("/compact 命令出现在 compactBoundary 前后 → 只保留单条压缩边界")
    func compactCommandBeforeAndAfterBoundaryFoldsIntoOneBoundary() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "/compact"), 0),
            ev(.compactBoundary, 1, detail: "旧上下文摘要"),
            ev(.userPrompt(text: "/compact"), 2),
            ev(.assistantText(text: "继续"), 3),
        ])
        #expect(turns.count == 2)
        #expect(turns[0].kind == .compactBoundary)
        guard case .assistant(let a) = turns[1].kind else { Issue.record("compact 后应保留 assistant 轮"); return }
        #expect(a.finalText == "继续")
    }

    @Test("systemNotice 独立成中性通知轮,不打进 assistant finalText")
    func systemNoticeStaysSeparate() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.assistantText(text: "先说结论"), 0),
            ev(.systemNotice(text: "协作会话消息 · reviewer：APPROVE"), 1, detail: "<teammate-message>APPROVE</teammate-message>"),
            ev(.assistantText(text: "继续"), 2),
        ])
        #expect(turns.count == 3)
        guard case .assistant(let first) = turns[0].kind else { Issue.record("第一轮应是 assistant"); return }
        #expect(first.finalText == "先说结论")
        #expect(turns[1].kind == .systemNotice(text: "协作会话消息 · reviewer：APPROVE"))
        #expect(turns[1].systemNoticeDetail == "<teammate-message>APPROVE</teammate-message>")
        guard case .assistant(let second) = turns[2].kind else { Issue.record("第三轮应是 assistant"); return }
        #expect(second.finalText == "继续")
    }

    // MARK: - #9 workflow 衍生 agent

    @Test("#9:Workflow 工具 → 从 tool_result 输出抽 Run ID 到具体 step item")
    func workflowRunIdExtracted() {
        let items = AgentConversation.buildTurnItems(from: [
            ev(.toolUse(name: "Workflow", summary: "调研"), 0, detail: "export const meta = {...}"),
            ev(.toolResult(name: "", isError: false), 1, detail: "Workflow launched in background. Task ID: wpx\nRun ID: wf_fc74e832-5a5\nMore text"),
            ev(.assistantText(text: "已启动"), 2),
        ])
        guard case .assistantTurn(let a) = items[0].kind else { Issue.record("assistantTurn"); return }
        #expect(a.stepsItems().first?.workflowRunId == "wf_fc74e832-5a5")
    }

    @Test("#9:extractWorkflowRunId(有/无 Run ID / 非 wf_ 前缀)")
    func extractWorkflowRunIdHelper() {
        #expect(AgentConversation.extractWorkflowRunId("foo Run ID: wf_abc-123 bar") == "wf_abc-123")
        #expect(AgentConversation.extractWorkflowRunId("no run id here") == nil)
        #expect(AgentConversation.extractWorkflowRunId("Run ID: notawf") == nil)   // 非 wf_ 前缀
        #expect(AgentConversation.extractWorkflowRunId(nil) == nil)
    }

    @Test("非 workflow 工具 step → workflowRunId 空")
    func noWorkflowEmpty() {
        let items = AgentConversation.buildTurnItems(from: [ev(.toolUse(name: "Bash", summary: "ls"), 0), ev(.toolResult(name: "", isError: false), 1)])
        guard case .assistantTurn(let a) = items[0].kind else { Issue.record("assistantTurn"); return }
        #expect(a.stepsItems().first?.workflowRunId == nil)
    }

    // MARK: - Codex 收尾问句:awaiting 折进 assistant 轮(实机三重渲染 bug 修复)
    //
    // 实机:Codex 一句 `你好！今天想做什么?`(以 ? 结尾)渲了三遍 —— 1 文字气泡(agent_message)
    // + 2 重复「在等你回答」卡(response_item 双发 + task_complete 各产一 awaiting)。根因:同文字被
    // 提升成不同 kind(assistantText vs awaitingUser)→ 跨 kind 去重抓不到。修:agent_message/
    // response_item-assistant 统一 assistantText(双发折一条);**Codex 收尾问句的 awaiting 折进进行中
    // 轮标 `awaitingReply`,不另起重复卡**(awaiting 信号已由文字气泡承载;live pet 仍由 parser 事件驱动)。

    @Test("Codex 收尾问句双发 + task_complete awaiting → 单 assistant 轮(awaitingReply)无重复卡")
    func codexClosingQuestionFoldsIntoTurn() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "你好"), 0, agent: .codex),
            ev(.assistantText(text: "你好！今天想做什么?"), 1, agent: .codex),          // agent_message
            ev(.assistantText(text: "你好！今天想做什么?"), 2, agent: .codex),          // response_item 双发(相邻去重)
            ev(.awaitingUser(reason: .question(title: "你好！今天想做什么?")), 3, agent: .codex),  // task_complete
        ])
        #expect(turns.count == 2)                                  // 用户轮 + 1 助手轮(无独立 awaiting 卡)
        #expect(turns[0].kind == .user(text: "你好"))
        guard case .assistant(let a) = turns[1].kind else { Issue.record("应是 assistant 轮,不是 awaiting 卡"); return }
        #expect(a.finalText == "你好！今天想做什么?")               // 文字气泡只一条(双发去重)
        #expect(a.awaitingReply == true)                           // 折进轮的 awaiting 标记(驱动 footer/tab badge)
    }

    @Test("Codex awaiting 无进行中轮(裸 awaiting)→ 仍独立 awaiting 卡(无轮可折)")
    func codexBareAwaitingStandsAlone() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "继续"), 0, agent: .codex),
            ev(.awaitingUser(reason: .question(title: "选哪个?")), 1, agent: .codex),
        ])
        #expect(turns.count == 2)
        #expect(turns[1].kind == .awaiting(.question(title: "选哪个?")))   // 无 assistant 轮可折 → 独立卡
    }

    @Test("Claude AskUserQuestion awaiting **不折叠** → 独立 awaiting 卡(结构化问题非自身收尾)")
    func claudeAwaitingNotFolded() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.userPrompt(text: "改吗"), 0),                                  // 默认 .claudeCode
            ev(.assistantText(text: "我先分析下"), 1),
            ev(.awaitingUser(reason: .question(title: "选 A 还是 B?")), 2),
        ])
        #expect(turns.count == 3)                                              // 用户 + 助手 + 独立 awaiting 卡
        #expect(turns[2].kind == .awaiting(.question(title: "选 A 还是 B?")))
    }

    @Test("Claude AskUserQuestion turn item 保留 detail 并用同 id toolResult 追加已选答案")
    func claudeAwaitingTurnItemCarriesDetailAndSelectedAnswer() {
        let items = AgentConversation.buildTurnItems(from: [
            AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil,
                       kind: .awaitingUser(reason: .question(title: "发布策略")),
                       timestamp: Date(timeIntervalSince1970: 1),
                       detail: "问题：怎么发?\n选项：\n- 先推分支：推当前分支", toolUseId: "toolu_q"),
            AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil,
                       kind: .toolResult(name: "", isError: false),
                       timestamp: Date(timeIntervalSince1970: 2),
                       detail: #"{"answers":{"怎么发?":"先推分支"}}"#, toolUseId: "toolu_q"),
        ])
        #expect(items.count == 1)
        #expect(items[0].detailAffordance == .sideCard)
        #expect(items[0].awaitingDetail?.contains("问题：怎么发?") == true)
        #expect(items[0].awaitingDetail?.contains("已选：先推分支") == true)
    }

    @Test("Claude turn explicit id result 不误关无关 running tool")
    func claudeTurnExplicitResultDoesNotCloseUnrelatedRunningTool() {
        let items = AgentConversation.buildTurnItems(from: [
            AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil,
                       kind: .toolUse(name: "Bash", summary: "sleep"),
                       timestamp: Date(timeIntervalSince1970: 0), detail: "sleep 10", toolUseId: "toolu_bash"),
            AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil,
                       kind: .awaitingUser(reason: .question(title: "发布策略")),
                       timestamp: Date(timeIntervalSince1970: 1), detail: "问题：怎么发?", toolUseId: "toolu_q"),
            AgentEvent(agent: .claudeCode, sessionId: "s", cwd: nil,
                       kind: .toolResult(name: "", isError: false),
                       timestamp: Date(timeIntervalSince1970: 2),
                       detail: #"{"answers":{"怎么发?":"先推分支"}}"#, toolUseId: "toolu_q"),
        ])
        #expect(items.count == 2)
        guard case .assistantTurn(let turn) = items[0].kind else { Issue.record("第一行应是 assistantTurn"); return }
        guard case .tool(_, _, _, let state, _, let output, _) = turn.steps.first else { Issue.record("应保留 running tool step"); return }
        #expect(state == .running)
        #expect(output == nil)
        guard case .awaiting = items[1].kind else { Issue.record("第二行应是 awaiting"); return }
        #expect(items[1].awaitingDetail?.contains("已选：先推分支") == true)
    }

    @Test("Codex awaiting 是 .permission(非收尾问句)→ 不折叠,独立卡")
    func codexPermissionAwaitingNotFolded() {
        let turns = AgentConversation.buildTurns(from: [
            ev(.assistantText(text: "要跑 git push"), 0, agent: .codex),
            ev(.awaitingUser(reason: .permission(tool: "git push")), 1, agent: .codex),
        ])
        #expect(turns.count == 2)
        #expect(turns[1].kind == .awaiting(.permission(tool: "git push")))    // 权限是独立请求 → 卡
    }
}
