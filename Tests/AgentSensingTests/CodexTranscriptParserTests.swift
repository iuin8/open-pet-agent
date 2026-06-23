import Testing
import Foundation
@testable import AgentSensing

/// Codex transcript 行 → AgentEvent。**本机无 codex 会话 → 这套测试就是 parser 的规格**。
/// schema:两层 `{type, payload}`,event_msg 还有内嵌 payload.type。
@Suite("CodexTranscriptParser — Codex 行 → AgentEvent")
struct CodexTranscriptParserTests {

    let parser = CodexTranscriptParser()

    // MARK: - session_meta

    @Test("session_meta → sessionStart,取 payload.id / cwd")
    func sessionMeta() {
        let line = #"{"type":"session_meta","payload":{"id":"sess-1","cwd":"/Users/me/proj","source":"cli"}}"#
        let e = parser.parse(line: line)
        #expect(e?.agent == .codex)
        #expect(e?.kind == .sessionStart)
        #expect(e?.sessionId == "sess-1")
        #expect(e?.projectName == "proj")
    }

    // MARK: - event_msg 消息类

    @Test("user_message → userPrompt")
    func userMessage() {
        let line = #"{"type":"event_msg","payload":{"type":"user_message","message":"帮我加个测试"}}"#
        #expect(parser.parse(line: line)?.kind == .userPrompt(text: "帮我加个测试"))
    }

    @Test("agent_message(普通)→ assistantText")
    func agentMessage() {
        let line = #"{"type":"event_msg","payload":{"type":"agent_message","message":"好的我来改"}}"#
        #expect(parser.parse(line: line)?.kind == .assistantText(text: "好的我来改"))
    }

    @Test("agent_message(问句)→ assistantText(不再提升 awaiting:收尾 awaiting 信号统一由 task_complete 出,避免同句重复渲染)")
    func agentMessageQuestion() {
        let line = #"{"type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"要我直接 push 吗?"}}"#
        #expect(parser.parse(line: line)?.kind == .assistantText(text: "要我直接 push 吗?"))
    }

    @Test("agent_message(commentary 但非问句)→ assistantText")
    func agentMessageCommentaryNotQuestion() {
        let line = #"{"type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"我先看下代码"}}"#
        #expect(parser.parse(line: line)?.kind == .assistantText(text: "我先看下代码"))
    }

    @Test("response_item message(assistant + 问句)→ assistantText(与 agent_message 双发同 kind,buildTurns 才能去重)")
    func responseAssistantQuestion() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"你好！今天想做什么?"}]}}"#
        #expect(parser.parse(line: line)?.kind == .assistantText(text: "你好！今天想做什么?"))
    }

    // MARK: - event_msg 任务收尾

    @Test("task_complete(普通)→ done")
    func taskComplete() {
        let line = #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"改完了"}}"#
        #expect(parser.parse(line: line)?.kind == .done)
    }

    @Test("task_complete(收尾是问句)→ awaitingUser(.question)")
    func taskCompleteQuestion() {
        let line = #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"要继续下一步吗？"}}"#
        #expect(parser.parse(line: line)?.kind == .awaitingUser(reason: .question(title: "要继续下一步吗？")))
    }

    @Test("turn_aborted → done")
    func turnAborted() {
        let line = #"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
        #expect(parser.parse(line: line)?.kind == .done)
    }

    // MARK: - event_msg 等用户(核心)

    @Test("request_user_input → awaitingUser(.question),标题取 questions[0].question")
    func requestUserInput() {
        let line = #"{"type":"event_msg","payload":{"type":"request_user_input","call_id":"c1","questions":[{"id":"q1","question":"选哪个方案?","options":[]}]}}"#
        #expect(parser.parse(line: line)?.kind == .awaitingUser(reason: .question(title: "选哪个方案?")))
    }

    @Test("request_permissions → awaitingUser(.permission)")
    func requestPermissions() {
        let line = #"{"type":"event_msg","payload":{"type":"request_permissions","call_id":"c2","tool":"write_file"}}"#
        #expect(parser.parse(line: line)?.kind == .awaitingUser(reason: .permission(tool: "write_file")))
    }

    @Test("exec_approval_request → awaitingUser(.permission),工具=命令摘要")
    func execApprovalRequest() {
        let line = #"{"type":"event_msg","payload":{"type":"exec_approval_request","call_id":"c3","command":["git","push"],"reason":"需要联网"}}"#
        #expect(parser.parse(line: line)?.kind == .awaitingUser(reason: .permission(tool: "git push")))
    }

    // MARK: - event_msg 命令执行

    @Test("exec_command_begin → toolUse(exec),摘要=命令拼接")
    func execBegin() {
        let line = #"{"type":"event_msg","payload":{"type":"exec_command_begin","call_id":"c4","command":["swift","build"]}}"#
        #expect(parser.parse(line: line)?.kind == .toolUse(name: "exec", summary: "swift build"))
    }

    @Test("exec_command_end(exit_code 0)→ toolResult 成功")
    func execEndOK() {
        let line = #"{"type":"event_msg","payload":{"type":"exec_command_end","call_id":"c4","exit_code":0,"status":"completed"}}"#
        #expect(parser.parse(line: line)?.kind == .toolResult(name: "exec", isError: false))
    }

    @Test("exec_command_end(exit_code 非0)→ toolResult 出错")
    func execEndFail() {
        let line = #"{"type":"event_msg","payload":{"type":"exec_command_end","call_id":"c4","exit_code":1,"status":"failed"}}"#
        #expect(parser.parse(line: line)?.kind == .toolResult(name: "exec", isError: true))
    }

    @Test("mcp_tool_call_begin → toolUse,名取 invocation.tool_name")
    func mcpBegin() {
        let line = #"{"type":"event_msg","payload":{"type":"mcp_tool_call_begin","call_id":"c5","invocation":{"tool_name":"search_docs"}}}"#
        #expect(parser.parse(line: line)?.kind == .toolUse(name: "search_docs", summary: ""))
    }

    // MARK: - response_item(新格式)

    @Test("response_item message(assistant)→ assistantText,拼 content[].text")
    func responseAssistantMessage() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"已完成重构"}]}}"#
        #expect(parser.parse(line: line)?.kind == .assistantText(text: "已完成重构"))
    }

    @Test("response_item message(user)→ userPrompt")
    func responseUserMessage() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"修一下这个 bug"}]}}"#
        #expect(parser.parse(line: line)?.kind == .userPrompt(text: "修一下这个 bug"))
    }

    @Test("response_item message(developer/system)→ nil 噪声")
    func responseDeveloperIgnored() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"text","text":"system prompt"}]}}"#
        #expect(parser.parse(line: line) == nil)
    }

    @Test("response_item function_call → toolUse,摘要从 arguments JSON 串解")
    func responseFunctionCall() {
        let line = #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"c6","arguments":"{\"command\":[\"ls\",\"-la\"]}"}}"#
        #expect(parser.parse(line: line)?.kind == .toolUse(name: "exec_command", summary: "ls -la"))
    }

    @Test("response_item custom_tool_call_output(失败)→ toolResult isError")
    func responseToolOutputFail() {
        let line = #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c6","output":"{\"metadata\":{\"exit_code\":2}}","status":"failed"}}"#
        #expect(parser.parse(line: line)?.kind == .toolResult(name: "", isError: true))
    }

    @Test("response_item web_search_call → toolUse(web_search),摘要=query")
    func webSearch() {
        let line = #"{"type":"response_item","payload":{"type":"web_search_call","call_id":"c7","action":{"type":"search","query":"swift actor"}}}"#
        #expect(parser.parse(line: line)?.kind == .toolUse(name: "web_search", summary: "swift actor"))
    }

    // MARK: - 噪声 / 边界 / fallback

    @Test("噪声类型 → nil(turn_context / agent_reasoning / reasoning)")
    func noiseReturnsNil() {
        #expect(parser.parse(line: #"{"type":"turn_context","payload":{"cwd":"/x"}}"#) == nil)
        #expect(parser.parse(line: #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"thinking"}}"#) == nil)
        #expect(parser.parse(line: #"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#) == nil)
        // 注:token_count 不再是噪音 → 升不可见 .sessionStart 携 per-turn usage(P1-8),单独测见 tokenCountCarriesUsage。
    }

    @Test("非 JSON / 缺 type → nil")
    func malformed() {
        #expect(parser.parse(line: "nope") == nil)
        #expect(parser.parse(line: #"{"payload":{}}"#) == nil)
    }

    @Test("**P1-8**:token_count → 不可见 .sessionStart 但携 per-turn 上下文占用(last_token_usage,真实 schema)")
    func tokenCountCarriesUsage() {
        let line = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":99999,"cached_input_tokens":0,"output_tokens":100,"total_tokens":100099},"last_token_usage":{"input_tokens":38861,"cached_input_tokens":512,"output_tokens":54,"total_tokens":39427},"model_context_window":950000}}}"#
        let e = parser.parse(line: line)
        #expect(e?.kind == .sessionStart)                          // 不可见载体(不出项、无 pet 副作用)
        #expect(e?.usage?.contextTokens == 38861 + 512)            // 取 last(本轮)非 total(累计):input+cached
        #expect(e?.usage?.output == 54)
    }

    @Test("P1-8:非 token_count 行无 usage(回归保护)")
    func nonTokenCountNoUsage() {
        #expect(parser.parse(line: #"{"type":"event_msg","payload":{"type":"agent_message","message":"hi"}}"#)?.usage == nil)
        #expect(parser.parse(line: #"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#)?.usage == nil)  // 缺 last → nil
    }

    @Test("非 session_meta 行用 fallback sessionId/cwd 兜底")
    func fallbackContext() {
        let line = #"{"type":"event_msg","payload":{"type":"exec_command_begin","command":["ls"]}}"#
        let e = parser.parse(line: line, fallbackSessionId: "file-uuid", fallbackCwd: "/Users/me/work").first
        #expect(e?.sessionId == "file-uuid")
        #expect(e?.projectName == "work")
    }

    // MARK: - detail 全文抓取(给会话流「展开看详情」P3.7;摘要短、detail 全)

    @Test("exec_command_begin detail = 完整命令(不截断,长于摘要上限)")
    func execBeginDetail() {
        let line = #"{"type":"event_msg","payload":{"type":"exec_command_begin","call_id":"c","command":["git","commit","-m","一条很长的提交信息长到肯定超过五十六个字符的摘要上限好让我们验证 detail 不被截断"]}}"#
        let e = parser.parse(line: line)
        #expect(e?.detail == "git commit -m 一条很长的提交信息长到肯定超过五十六个字符的摘要上限好让我们验证 detail 不被截断")
    }

    @Test("exec_command_end detail = 完整输出(aggregated_output)")
    func execEndDetail() {
        let line = #"{"type":"event_msg","payload":{"type":"exec_command_end","call_id":"c","exit_code":0,"aggregated_output":"line1\nline2\nline3"}}"#
        #expect(parser.parse(line: line)?.detail == "line1\nline2\nline3")
    }

    @Test("function_call detail = 完整命令(arguments JSON 里的 command 数组)")
    func functionCallCommandDetail() {
        let line = #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"command\":[\"ls\",\"-la\",\"/tmp\"]}"}}"#
        #expect(parser.parse(line: line)?.detail == "ls -la /tmp")
    }

    @Test("function_call detail = 非命令参数 → pretty JSON 保留全字段")
    func functionCallJSONDetail() {
        let line = #"{"type":"response_item","payload":{"type":"function_call","name":"apply_patch","arguments":"{\"path\":\"A.swift\",\"content\":\"x\"}"}}"#
        let detail = parser.parse(line: line)?.detail
        #expect(detail?.contains("\"path\"") == true)
        #expect(detail?.contains("A.swift") == true)
        #expect(detail?.contains("\"content\"") == true)
    }

    @Test("function_call_output detail = 内层 output 文本(JSON 包裹时抽出)")
    func functionCallOutputInnerDetail() {
        // 内层换行在真实 wire 格式里是双重转义 \\n(外层 JSON 解析后内层仍是合法 JSON)。
        let line = #"{"type":"response_item","payload":{"type":"function_call_output","output":"{\"output\":\"build succeeded\\nall green\",\"metadata\":{\"exit_code\":0}}"}}"#
        #expect(parser.parse(line: line)?.detail == "build succeeded\nall green")
    }

    @Test("function_call_output detail = 纯文本输出原样")
    func functionCallOutputPlainDetail() {
        let line = #"{"type":"response_item","payload":{"type":"custom_tool_call_output","output":"plain text result"}}"#
        #expect(parser.parse(line: line)?.detail == "plain text result")
    }

    @Test("mcp_tool_call_begin detail = invocation 参数(含 query)")
    func mcpBeginDetail() {
        let line = #"{"type":"event_msg","payload":{"type":"mcp_tool_call_begin","invocation":{"tool_name":"search","arguments":{"query":"swift"}}}}"#
        let detail = parser.parse(line: line)?.detail
        #expect(detail?.contains("query") == true)
        #expect(detail?.contains("swift") == true)
    }

    @Test("mcp_tool_call_end detail = result 文本")
    func mcpEndDetail() {
        let line = #"{"type":"event_msg","payload":{"type":"mcp_tool_call_end","invocation":{"tool_name":"search"},"result":"found 3 results"}}"#
        #expect(parser.parse(line: line)?.detail == "found 3 results")
    }

    @Test("web_search_call detail = 完整 query(摘要截 40,detail 不截)")
    func webSearchDetail() {
        let line = #"{"type":"response_item","payload":{"type":"web_search_call","action":{"type":"search","query":"swift concurrency best practices 一条足够长的查询用来验证 detail 不被截断"}}}"#
        #expect(parser.parse(line: line)?.detail == "swift concurrency best practices 一条足够长的查询用来验证 detail 不被截断")
    }

    @Test("非工具事件 detail = nil(user/agent/session_meta 不带详情)")
    func nonToolNoDetail() {
        #expect(parser.parse(line: #"{"type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#)?.detail == nil)
        #expect(parser.parse(line: #"{"type":"event_msg","payload":{"type":"agent_message","message":"好的"}}"#)?.detail == nil)
        #expect(parser.parse(line: #"{"type":"session_meta","payload":{"id":"s","cwd":"/x"}}"#)?.detail == nil)
    }

    // MARK: - 问题1:Codex harness 注入噪音过滤(role=user 夹带 AGENTS.md/skill/环境上下文)
    //
    // Codex 把 harness 注入(AGENTS.md 上下文 / $skill 展开的 SKILL.md 全文 / 环境上下文 / 沙箱权限说明)
    // 以 `role:user` 的 `response_item/message` 混进对话流 —— Codex 无 Claude 的 `isMeta` 标记区分,
    // 旧 parser 当用户消息整段渲染。样本据 `~/.codex/sessions` 全量扫描(见 docs/companion-card-plan.md)。
    // **真实用户 prompt 绝不以注入前缀开头**;`<task>`(slash 命令展开)两路径都出现 → 是真 prompt,不过滤。

    @Test("response_item user — `# AGENTS.md instructions` 注入 → nil(最常见,×17)")
    func injectionAgentsMd() {
        let line = ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /Users/me/projects/openpetagent\n\n<INSTRUCTIONS> 编码注释用中文 </INSTRUCTIONS>"}]}}"##
        #expect(parser.parse(line: line) == nil)
    }

    @Test("response_item user — `<skill>` 注入(SKILL.md 全文)→ nil")
    func injectionSkill() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<skill> <name>skill-installer</name> <path>/Users/me/.codex/skills/.system/skill-installer/SKILL.md</path> --- name: skill-installer </skill>"}]}}"#
        #expect(parser.parse(line: line) == nil)
    }

    @Test("response_item user — `<environment_context>` 注入 → nil")
    func injectionEnvironmentContext() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <current_date>2026-06-17</current_date>\n  <timezone>Asia/Shanghai</timezone>\n</environment_context>"}]}}"#
        #expect(parser.parse(line: line) == nil)
    }

    @Test("response_item user — `<permissions instructions>`(role=user 变体)→ nil(防御)")
    func injectionPermissionsAsUser() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<permissions instructions> Filesystem sandboxing defines which files can be read or written. </permissions instructions>"}]}}"#
        #expect(parser.parse(line: line) == nil)
    }

    @Test("response_item user — Codex CLI 启动 banner(`Tip: New Build…`+TOML 告警)→ nil(对抗审查补,×2 漏网)")
    func injectionTipBanner() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Tip: New Build faster with the Codex App. Run 'codex app' or visit https://chatgpt.com/codex\n\n⚠ Ignoring malformed agent role definition: TOML parse error at line 91"}]}}"#
        #expect(parser.parse(line: line) == nil)
    }

    @Test("event_msg user_message — `Tip: New Build…` banner 也过滤(双路径)")
    func injectionTipBannerEventMsg() {
        let line = #"{"type":"event_msg","payload":{"type":"user_message","message":"Tip: New Build faster with the Codex App. Run 'codex app' or visit https://chatgpt.com/codex"}}"#
        #expect(parser.parse(line: line) == nil)
    }

    @Test("response_item user — `<user_instructions>` 不再误杀(零样本 + 通用脚手架标签,删防御项后保留)")
    func userInstructionsKeptNoFalsePositive() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<user_instructions> Always respond in Chinese. </user_instructions>"}]}}"#
        if case .userPrompt = parser.parse(line: line)?.kind {} else { Issue.record("期望保留为 .userPrompt(不误杀粘贴的 prompt 模板)") }
    }

    @Test("response_item user — 用户粘贴的游戏 `<skill>` XML(无 SKILL.md)不误杀 → 保留(对抗审查反例)")
    func skillGameXmlKept() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<skill><name>Fireball</name><damage>50</damage></skill> 帮我解析这个技能配置"}]}}"#
        if case .userPrompt = parser.parse(line: line)?.kind {} else { Issue.record("期望保留为 .userPrompt(游戏 skill XML 无 SKILL.md 不是 Codex 注入)") }
    }

    @Test("response_item user — `<task>`(slash 命令展开)是真 prompt → 保留(关键反例)")
    func taskBlockIsRealPrompt() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<task> Repo: /Users/me/projects/sample — 帮我看看构建为什么挂了 </task>"}]}}"#
        let e = parser.parse(line: line)
        if case .userPrompt = e?.kind {} else { Issue.record("期望 .userPrompt,实得 \(String(describing: e?.kind))") }
    }

    @Test("response_item user — slash 命令 `$skill-installer hatch-pet` 是真 prompt → 保留")
    func dollarCommandIsRealPrompt() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"$skill-installer hatch-pet"}]}}"#
        #expect(parser.parse(line: line)?.kind == .userPrompt(text: "$skill-installer hatch-pet"))
    }

    @Test("response_item user — 自然语言 prompt 不误伤(回归保护)")
    func naturalPromptKept() {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"里面的Java文件都是用来干嘛的?"}]}}"#
        #expect(parser.parse(line: line)?.kind == .userPrompt(text: "里面的Java文件都是用来干嘛的?"))
    }

    @Test("event_msg user_message — AGENTS.md 注入也过滤(防御:版本变体可能改走此路径)")
    func injectionViaEventMsgFiltered() {
        let line = ##"{"type":"event_msg","payload":{"type":"user_message","message":"# AGENTS.md instructions for /Users/me/x\n\n<INSTRUCTIONS></INSTRUCTIONS>"}}"##
        #expect(parser.parse(line: line) == nil)
    }

    // MARK: - 端到端:真实「你好」会话原始行序 → 干净 2 轮(实机三重渲染 bug 的集成层回归)

    @Test("端到端:真实 rollout 行序(双发 + task_complete)→ 用户轮 + 单助手轮(awaitingReply),无重复 awaiting 卡")
    func realSessionFoldsToTwoTurns() {
        // 取自实机 rollout-2026-06-17T18-37(注入/reasoning 噪音行已被过滤;此处只列产可见事件的行)。
        let lines = [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"你好"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"你好"}}"#,                                  // 双发
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"你好！今天想做什么?"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"你好！今天想做什么?"}]}}"#,  // 双发
            #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"你好！今天想做什么?"}}"#,
        ]
        let events = lines.flatMap { parser.parse(line: $0, fallbackSessionId: "s", fallbackCwd: nil) }
        let turns = AgentConversation.buildTurns(from: events)
        #expect(turns.count == 2)                                  // 实机原来是 用户 + 文字气泡 + 2 重复 awaiting 卡(共 4)
        #expect(turns[0].kind == .user(text: "你好"))
        guard case .assistant(let a) = turns[1].kind else { Issue.record("应是 assistant 轮"); return }
        #expect(a.finalText == "你好！今天想做什么?")
        #expect(a.awaitingReply == true)
    }
}
