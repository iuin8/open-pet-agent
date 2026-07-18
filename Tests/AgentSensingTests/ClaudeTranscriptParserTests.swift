import Testing
import Foundation
@testable import AgentSensing

/// 用**实测 schema** 的 transcript 样本行驱动 parser:每行 JSON → 期望 AgentEvent。
/// schema 来自真实 ~/.claude/projects/*.jsonl(顶层 type/cwd/sessionId/timestamp +
/// message.content 的 string / [tool_use|text|tool_result] 形态)。
@Suite("ClaudeTranscriptParser — transcript 行 → AgentEvent")
struct ClaudeTranscriptParserTests {

    let parser = ClaudeTranscriptParser()

    // MARK: - assistant: tool_use

    @Test("Bash 工具 → toolUse,摘要取 description")
    func bashToolUse() {
        let line = """
        {"type":"assistant","sessionId":"abc123","cwd":"/Users/me/dev/pet-agent","timestamp":"2026-06-12T10:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test","description":"跑测试"}}]}}
        """
        let e = parser.parse(line: line)
        #expect(e?.agent == .claudeCode)
        #expect(e?.sessionId == "abc123")
        #expect(e?.kind == .toolUse(name: "Bash", summary: "跑测试"))
        #expect(e?.projectName == "pet-agent")
    }

    @Test("Task 工具 → 捕获 tool_use id(D2:关联子 agent)")
    func taskToolUseId() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01XYZ","name":"Task","input":{"description":"审代码","subagent_type":"code-reviewer"}}]}}"#
        let e = parser.parse(line: line)
        #expect(e?.toolUseId == "toolu_01XYZ")
        #expect(e?.kind == .toolUse(name: "Task", summary: "审代码"))
    }

    @Test("无 id 的 tool_use → toolUseId nil")
    func toolUseNoId() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#
        #expect(parser.parse(line: line)?.toolUseId == nil)
    }

    @Test("thinking block → .thinking 事件,存全文")
    func thinkingBlock() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"先看一下登录流程的超时配置","signature":"abc"}]}}"#
        #expect(parser.parse(line: line)?.kind == .thinking(text: "先看一下登录流程的超时配置"))
    }

    @Test("assistant message.usage → TokenUsage(contextTokens = input+cache)")
    func usageCapture() {
        let line = #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":21134,"output_tokens":900,"cache_read_input_tokens":25429,"cache_creation_input_tokens":29935},"content":[{"type":"text","text":"好的"}]}}"#
        let e = parser.parse(line: line)
        #expect(e?.usage == TokenUsage(input: 21134, output: 900, cacheRead: 25429, cacheCreation: 29935))
        #expect(e?.usage?.contextTokens == 21134 + 25429 + 29935)
        #expect(e?.model == "claude-opus-4-8")
    }

    @Test("无 usage → nil;全 0 usage → nil")
    func usageAbsent() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#
        #expect(parser.parse(line: line)?.usage == nil)
        #expect(parser.parse(line: line)?.model == nil)
    }

    // MARK: - 详情全文(P3.7:展开看详情)

    @Test("toolUse 抓完整 input detail —— Bash 全命令(摘要短、detail 全)")
    func toolUseDetailBash() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hi && ls -la /tmp","description":"列目录"}}]}}"#
        let e = parser.parse(line: line)
        #expect(e?.kind == .toolUse(name: "Bash", summary: "列目录"))   // 摘要 = description
        #expect(e?.detail == "echo hi && ls -la /tmp")                  // detail = 完整 command
    }

    @Test("Edit toolUse detail —— old/new 前后对照")
    func toolUseDetailEdit() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a/Foo.swift","old_string":"let x = 1","new_string":"let x = 2"}}]}}"#
        #expect(parser.parse(line: line)?.detail == "- let x = 1\n+ let x = 2")
    }

    @Test("tool_result 抓完整 output detail")
    func toolResultDetail() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","is_error":false,"content":"line1\nline2\nline3"}]}}"#
        let e = parser.parse(line: line)
        #expect(e?.kind == .toolResult(name: "", isError: false))
        #expect(e?.detail == "line1\nline2\nline3")
    }

    @Test("Bash 无 description → 摘要回退命令")
    func bashFallbackCommand() {
        let line = #"{"type":"assistant","sessionId":"s","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift build"}}]}}"#
        #expect(parser.parse(line: line)?.kind == .toolUse(name: "Bash", summary: "swift build"))
    }

    @Test("Edit 工具 → 摘要取文件名(不含目录)")
    func editToolUse() {
        let line = #"{"type":"assistant","sessionId":"s","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/me/dev/pet-agent/Sources/Foo.swift"}}]}}"#
        #expect(parser.parse(line: line)?.kind == .toolUse(name: "Edit", summary: "Foo.swift"))
    }

    @Test("AskUserQuestion → awaitingUser(.question),标题取 header")
    func askUserQuestion() {
        let line = #"{"type":"assistant","sessionId":"s","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"header":"发布范围","question":"怎么发?","options":[]}]}}]}}"#
        #expect(parser.parse(line: line)?.kind == .awaitingUser(reason: .question(title: "发布范围")))
    }

    @Test("assistant 纯 text → assistantText(P3.8 G2:存全文,保留换行)")
    func assistantText() {
        let line = #"{"type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"我先看一下这个文件\n然后改"}]}}"#
        // G2 后存全文(换行保留),不再 snippet 折成单行 —— 给会话流多行展示/展开。
        #expect(parser.parse(line: line)?.kind == .assistantText(text: "我先看一下这个文件\n然后改"))
    }

    // MARK: - P0-2 一行多事件(text+tool_use 共存,narration 不再被吞)

    /// 直接拿数组(完整多事件),便捷 `parse(line:)` 只取首事件。
    func events(_ line: String) -> [AgentEvent] {
        parser.parse(line: line, fallbackSessionId: "", fallbackCwd: nil)
    }

    @Test("**P0-2**:text + tool_use 同条 message → 两事件按文档顺序(叙述不再被工具吞)")
    func narrationAndToolBothEmit() {
        let line = #"{"type":"assistant","sessionId":"s","message":{"content":[{"type":"text","text":"让我跑下测试"},{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}"#
        let es = events(line)
        #expect(es.count == 2)
        #expect(es[0].kind == .assistantText(text: "让我跑下测试"))   // 叙述在前(文档顺序),保留
        #expect(es[1].kind == .toolUse(name: "Bash", summary: "swift test"))
        #expect(es[1].detail == "swift test")                        // 工具 detail 仍随事件
    }

    @Test("P0-2:thinking + text + tool_use → 三事件按文档顺序(思考 → 叙述 → 工具)")
    func thinkingTextToolAllEmit() {
        let line = #"{"type":"assistant","sessionId":"s","message":{"content":[{"type":"thinking","thinking":"先想想"},{"type":"text","text":"我先读文件"},{"type":"tool_use","name":"Read","input":{"file_path":"/a/B.swift"}}]}}"#
        let es = events(line)
        #expect(es.count == 3)
        #expect(es[0].kind == .thinking(text: "先想想"))
        #expect(es[1].kind == .assistantText(text: "我先读文件"))
        #expect(es[2].kind == .toolUse(name: "Read", summary: "B.swift"))
    }

    @Test("P0-2:同条 message 两个 tool_use → 两事件都出(旧 first(where:) 会丢第二个)")
    func twoToolUsesBothEmit() {
        let line = #"{"type":"assistant","sessionId":"s","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a/A.swift"}},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/a/B.swift"}}]}}"#
        let es = events(line)
        #expect(es.count == 2)
        #expect(es[0].kind == .toolUse(name: "Read", summary: "A.swift"))
        #expect(es[0].toolUseId == "t1")
        #expect(es[1].kind == .toolUse(name: "Read", summary: "B.swift"))
        #expect(es[1].toolUseId == "t2")
    }

    @Test("P0-2:消息级 usage/model 附到拆分出的每个事件(元数据栏不论命中哪块都拿得到)")
    func usageAttachedToAllSplitEvents() {
        let line = #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"叙述"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#
        let es = events(line)
        #expect(es.count == 2)
        #expect(es.allSatisfy { $0.model == "claude-opus-4-8" })
        #expect(es.allSatisfy { $0.usage?.input == 100 })
    }

    @Test("P0-2:纯 text 仍单事件;空 content → 空数组(回归保护)")
    func singleAndEmptyStillHold() {
        #expect(events(#"{"type":"assistant","message":{"content":[{"type":"text","text":"只说一句"}]}}"#).count == 1)
        #expect(events(#"{"type":"assistant","message":{"content":[]}}"#).isEmpty)
        // 便捷 parse(line:) 取首事件:[text, tool] → 首个是 text
        #expect(parser.parse(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"A"},{"type":"tool_use","name":"Bash","input":{"command":"x"}}]}}"#)?.kind == .assistantText(text: "A"))
    }

    // MARK: - user

    @Test("user 字符串 content → userPrompt")
    func userPrompt() {
        let line = #"{"type":"user","sessionId":"s","message":{"role":"user","content":"帮我修个 bug"}}"#
        #expect(parser.parse(line: line)?.kind == .userPrompt(text: "帮我修个 bug"))
    }

    @Test("user tool_result(出错) → toolResult(isError: true)")
    func toolResultError() {
        let line = #"{"type":"user","sessionId":"s","message":{"content":[{"type":"tool_result","is_error":true,"content":"boom"}]}}"#
        #expect(parser.parse(line: line)?.kind == .toolResult(name: "", isError: true))
    }

    @Test("user tool_result(成功,无 is_error 字段) → isError false")
    func toolResultOK() {
        let line = #"{"type":"user","sessionId":"s","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
        #expect(parser.parse(line: line)?.kind == .toolResult(name: "", isError: false))
    }

    @Test("**P0-2**:tool_result 透传 tool_use_id(给并行工具精确配对,不张冠李戴)")
    func toolResultCarriesToolUseId() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_01ABC","content":"done"}]}}"#
        #expect(parser.parse(line: line)?.toolUseId == "toolu_01ABC")
        // 无 tool_use_id(如 Codex / 旧行)→ nil,buildTurns 自然退 LIFO
        #expect(parser.parse(line: #"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#)?.toolUseId == nil)
    }

    // MARK: - user 消息分类 / 过滤(#30 噪音过滤 + #31 漏显修复,对照 claude-devtools)

    @Test("**P1-5**:图+文 prompt → 文字(去 [图片] 占位)+ attachments 携图(source.data 格式)")
    func userImageTextPrompt() {
        let line = #"{"type":"user","sessionId":"s","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","data":"aGVsbG8=","media_type":"image/png"}},{"type":"text","text":"你看看这个截图跟你说的不一样"}]}}"#
        let e = parser.parse(line: line)
        #expect(e?.kind == .userPrompt(text: "你看看这个截图跟你说的不一样"))   // 不再 [图片] 占位
        #expect(e?.attachments.count == 1)
        #expect(e?.attachments.first?.mediaType == "image/png")
        #expect(e?.attachments.first?.data.isEmpty == false)
    }

    @Test("P1-5:纯图片 prompt → 空文本 + attachments(行只渲缩略图)")
    func userImageOnlyPrompt() {
        let line = #"{"type":"user","message":{"content":[{"type":"image","source":{"type":"base64","data":"aGVsbG8="}}]}}"#
        let e = parser.parse(line: line)
        #expect(e?.kind == .userPrompt(text: ""))
        #expect(e?.attachments.count == 1)
    }

    @Test("P1-5:file.base64 变体格式也抽出")
    func userImageFileFormat() {
        let line = #"{"type":"user","message":{"content":[{"type":"image","file":{"base64":"aGVsbG8=","media_type":"image/jpeg"}},{"type":"text","text":"图"}]}}"#
        let e = parser.parse(line: line)
        #expect(e?.attachments.count == 1)
        #expect(e?.attachments.first?.mediaType == "image/jpeg")
    }

    @Test("P1-5:image 块无 base64 数据(空 source)+ 无文字 → 整条丢(免空行)")
    func userImageNoDataDropped() {
        #expect(parser.parse(line: #"{"type":"user","message":{"content":[{"type":"image","source":{}}]}}"#) == nil)
        // 多张图:一张有 data 一张空 → 只抽出有 data 的
        let mixed = #"{"type":"user","message":{"content":[{"type":"image","source":{}},{"type":"image","source":{"type":"base64","data":"aGVsbG8="}},{"type":"text","text":"x"}]}}"#
        #expect(parser.parse(line: mixed)?.attachments.count == 1)
    }

    @Test("#30:/compact 后 isCompactSummary 超长摘要 → compactBoundary 保留摘要给展开")
    func compactSummaryFiltered() {
        let summary = "This session is being continued from a previous conversation that ran out of context. The summary below covers..."
        let line = #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"\#(summary)"}}"#
        #expect(parser.parse(line: line)?.kind == .compactBoundary)
        #expect(parser.parse(line: line)?.detail == summary)
    }

    @Test("**P1-6**:中断标记 [Request interrupted by user] → .interrupted(标记轮,非整条丢弃)")
    func interruptionBecomesMarker() {
        #expect(parser.parse(line: #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#)?.kind == .interrupted)
        // 单 text block 形态(`for tool use` 变体)也升标记
        #expect(parser.parse(line: #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#)?.kind == .interrupted)
        // 其余 harness 硬噪音仍整条丢弃(回归保护)
        #expect(parser.parse(line: #"{"type":"user","message":{"content":"<system-reminder>x</system-reminder>"}}"#) == nil)
    }

    @Test("#30:harness 噪音标签(system-reminder / local-command-stdout / task-notification / caveat)→ nil")
    func harnessNoiseFiltered() {
        #expect(parser.parse(line: #"{"type":"user","message":{"content":"<system-reminder>do this</system-reminder>"}}"#) == nil)
        #expect(parser.parse(line: #"{"type":"user","message":{"content":"<local-command-stdout>build ok</local-command-stdout>"}}"#) == nil)
        #expect(parser.parse(line: #"{"type":"user","message":{"content":"<task-notification>done</task-notification>"}}"#) == nil)
        #expect(parser.parse(line: #"{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>x</local-command-caveat>"}}"#) == nil)
    }

    @Test("后台 agent 被用户停止通知 → nil(系统生命周期,不冒充用户消息)")
    func backgroundAgentStoppedFiltered() {
        let line = #"{"type":"user","message":{"content":"Background agent \"目标：只读审查 /tmp/project\" was stopped by the user."}}"#
        #expect(parser.parse(line: line) == nil)
    }

    @Test("普通 Background agent 开头文本仍是用户消息")
    func backgroundAgentTextStillUserPrompt() {
        let line = #"{"type":"user","message":{"content":"Background agent design notes"}}"#
        #expect(parser.parse(line: line)?.kind == .userPrompt(text: "Background agent design notes"))
    }

    @Test("#30:slash 命令注入 → 清洗成可读 /cmd args")
    func slashCommandCleaned() {
        let line = #"{"type":"user","message":{"content":"<command-name>/effort</command-name><command-message>effort</command-message><command-args>ultracode</command-args>"}}"#
        #expect(parser.parse(line: line)?.kind == .userPrompt(text: "/effort ultracode"))
        // 无参数 → 只 /cmd
        let compact = #"{"type":"user","message":{"content":"<command-name>compact</command-name><command-args></command-args>"}}"#
        #expect(parser.parse(line: compact)?.kind == .userPrompt(text: "/compact"))
    }

    @Test("#30/缺口5:isMeta 内部注入(array text-only,如 skill base-dir / Continue)→ nil")
    func metaArrayInjectionFiltered() {
        let line = #"{"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"Base directory for this skill: /x/y"}]}}"#
        #expect(parser.parse(line: line) == nil)
    }

    @Test("#32 安全:isSidechain 子 agent 消息不混入主流 → nil(经子 agent 侧卡看)")
    func sidechainFilteredFromMainFlow() {
        let line = #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"子 agent 在干活"}]}}"#
        #expect(parser.parse(line: line) == nil)
    }

    @Test("子 agent 自身 transcript(整文件 isSidechain)→ parseSubagentLine 保留内容(修 body 全空)")
    func subagentLineKeepsSidechain() {
        // 子 agent transcript 每行都是 isSidechain:true;主流 parse 滤掉、parseSubagentLine 保留。
        let line = #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"子 agent 在干活"}]}}"#
        #expect(parser.parse(line: line) == nil)                              // 主流:仍滤(回归保护)
        let evs = parser.parseSubagentLine(line)                              // 子 agent 自身:保留
        #expect(evs.count == 1)
        #expect(evs.first?.kind == .assistantText(text: "子 agent 在干活"))
        // user 行同样保留
        let u = parser.parseSubagentLine(#"{"type":"user","isSidechain":true,"message":{"content":"去查下这个"}}"#)
        #expect(u.first?.kind == .userPrompt(text: "去查下这个"))
    }

    @Test("普通 user 纯文字 prompt 不受影响(回归保护)")
    func normalUserPromptStillWorks() {
        #expect(parser.parse(line: #"{"type":"user","message":{"content":"帮我修个 bug"}}"#)?.kind == .userPrompt(text: "帮我修个 bug"))
        // array 纯 text(无图无 tool_result,isMeta=false)也显示
        let arr = #"{"type":"user","message":{"content":[{"type":"text","text":"继续"}]}}"#
        #expect(parser.parse(line: arr)?.kind == .userPrompt(text: "继续"))
    }

    // MARK: - 噪声 / 边界

    @Test("噪声行(attachment / mode)→ nil")
    func noiseLinesReturnNil() {
        #expect(parser.parse(line: #"{"type":"attachment","content":"..."}"#) == nil)
        #expect(parser.parse(line: #"{"type":"mode","mode":"default"}"#) == nil)
        #expect(parser.parse(line: #"{"type":"file-history-snapshot"}"#) == nil)
    }

    @Test("非 JSON / 空行 → nil")
    func nonJSONReturnsNil() {
        #expect(parser.parse(line: "not json at all") == nil)
        #expect(parser.parse(line: "") == nil)
    }

    @Test("缺 type → nil")
    func missingTypeReturnsNil() {
        #expect(parser.parse(line: #"{"sessionId":"s","cwd":"/x"}"#) == nil)
    }

    @Test("ISO8601 timestamp 解析正确")
    func timestampParsed() {
        let line = #"{"type":"assistant","sessionId":"s","timestamp":"2026-06-12T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b/X.swift"}}]}}"#
        let e = parser.parse(line: line)
        #expect(e?.timestamp == ISO8601DateFormatter().date(from: "2026-06-12T10:00:00Z"))
    }
}

/// AgentActivityTracker:事件流 → 每会话状态 + 跃迁识别。
@Suite("AgentActivityTracker — 状态折叠 + 跃迁")
struct AgentActivityTrackerTests {

    func event(_ kind: AgentEventKind, session: String = "s") -> AgentEvent {
        AgentEvent(agent: .claudeCode, sessionId: session, cwd: nil, kind: kind, timestamp: Date(timeIntervalSince1970: 0))
    }

    @Test("toolUse → working 跃迁")
    func toolUseToWorking() {
        var t = AgentActivityTracker()
        let tr = t.ingest(event(.toolUse(name: "Bash", summary: "x")))
        #expect(tr == AgentActivityTracker.Transition(sessionId: "s", from: nil, to: .working))
        #expect(t.states["s"] == .working)
        #expect(t.anyActive)
    }

    @Test("同状态连续事件 → 无跃迁(nil)")
    func sameStateNoTransition() {
        var t = AgentActivityTracker()
        _ = t.ingest(event(.toolUse(name: "Bash", summary: "x")))
        #expect(t.ingest(event(.toolResult(name: "", isError: false))) == nil)  // 还是 working
    }

    @Test("working → done = idle 跃迁(供触发庆祝)")
    func workingToIdle() {
        var t = AgentActivityTracker()
        _ = t.ingest(event(.toolUse(name: "Bash", summary: "x")))
        let tr = t.ingest(event(.done))
        #expect(tr == AgentActivityTracker.Transition(sessionId: "s", from: .working, to: .idle))
    }

    @Test("awaitingUser 被 anyAwaitingUser 命中")
    func awaitingUserTracked() {
        var t = AgentActivityTracker()
        _ = t.ingest(event(.awaitingUser(reason: .question(title: "q"))))
        #expect(t.anyAwaitingUser)
        #expect(t.states["s"] == .awaitingUser)
    }

    @Test("sessionStart 不改状态(impliedState nil)")
    func sessionStartNoState() {
        var t = AgentActivityTracker()
        #expect(t.ingest(event(.sessionStart)) == nil)
        #expect(t.states.isEmpty)
    }

    @Test("多会话各自独立")
    func multiSession() {
        var t = AgentActivityTracker()
        _ = t.ingest(event(.toolUse(name: "Bash", summary: "x"), session: "a"))
        _ = t.ingest(event(.awaitingUser(reason: .notification(message: "m")), session: "b"))
        #expect(t.states["a"] == .working)
        #expect(t.states["b"] == .awaitingUser)
    }
}
