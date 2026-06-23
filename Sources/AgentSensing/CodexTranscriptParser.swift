import Foundation

/// 把 Codex 会话(`~/.codex/sessions/**/rollout-<ts>-<uuid>.jsonl`)的**一行 JSON** 解析成
/// `AgentEvent`。Codex schema 与 Claude **不同** —— 两层结构 `{type, payload}`,`event_msg`
/// 还有内嵌 `payload.type`。映射只学 Codex 事件 schema → 用自己的 `AgentEventKind` 重映一遍。
///
/// **本机无 codex 会话 → 无法实机验,单测即规格**(`CodexTranscriptParserTests`)。
///
/// sessionId/cwd:多数行不带 → 用 service 从文件名/首个 `session_meta` 推得的 `fallback` 兜底。
public struct CodexTranscriptParser: TranscriptParser {

    public init() {}

    public let agent: AgentKind = .codex

    /// 便捷重载(**测试用**):取首事件。Codex 一行一事件 → 等价单事件。
    public func parse(line: String) -> AgentEvent? {
        parse(line: line, fallbackSessionId: "", fallbackCwd: nil).first
    }

    /// Codex schema 一行一事件(无 Claude 的 content 多块结构)→ 返 0 或 1 个事件,统一进协议数组形态。
    public func parse(line: String, fallbackSessionId: String, fallbackCwd: String?) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return parse(object: obj, fallbackSessionId: fallbackSessionId, fallbackCwd: fallbackCwd)
    }

    public func parse(
        object obj: [String: Any],
        fallbackSessionId: String = "",
        fallbackCwd: String? = nil
    ) -> [AgentEvent] {
        guard let type = obj["type"] as? String else { return [] }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        guard let parsed = parseKind(type: type, payload: payload) else { return [] }

        // sessionId:session_meta 带 payload.id;其余行用 fallback。
        let lineSession = (payload["id"] as? String) ?? (obj["id"] as? String)
        let sid = (lineSession?.isEmpty == false ? lineSession! : fallbackSessionId)
        // cwd:session_meta / turn_context 可能带;其余用 fallback。
        let lineCwd = (payload["cwd"] as? String)
            ?? (payload["working_dir"] as? String)
            ?? (payload["current_dir"] as? String)

        return [AgentEvent(
            agent: .codex,
            sessionId: sid,
            cwd: lineCwd ?? fallbackCwd,
            kind: parsed.kind,
            timestamp: ParserHelpers.parseTimestamp(obj["timestamp"] as? String),
            detail: parsed.detail,
            usage: Self.contextUsage(payload: payload)   // P1-8:token_count 行携 per-turn 上下文占用
        )]
    }

    /// Codex `token_count.info.last_token_usage` → `TokenUsage`(对齐 Claude `contextTokens` 口径 =
    /// input + cacheRead + cacheCreation;Codex 映射 input_tokens + cached_input_tokens,output 也带上备用)。
    /// 非 token_count / 缺字段 / 全 0 → nil。`last_token_usage` 是**本轮**用量(非 `total_token_usage` 累计)。
    static func contextUsage(payload: [String: Any]) -> TokenUsage? {
        guard (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return nil }
        func n(_ k: String) -> Int { (last[k] as? Int) ?? Int((last[k] as? Double) ?? 0) }
        let u = TokenUsage(input: n("input_tokens"), output: n("output_tokens"),
                           cacheRead: n("cached_input_tokens"), cacheCreation: 0)
        return (u.input | u.output | u.cacheRead) == 0 ? nil : u
    }

    // MARK: - 顶层 type 分发(连同详情展开用的完整 input/output;非工具事件 detail = nil)

    private func parseKind(type: String, payload: [String: Any]) -> (kind: AgentEventKind, detail: String?)? {
        switch type {
        case "session_meta":
            return (.sessionStart, nil)
        case "event_msg":
            guard let inner = payload["type"] as? String else { return nil }
            return eventMsgKind(inner, payload: payload)
        case "response_item":
            guard let inner = payload["type"] as? String else { return nil }
            return responseItemKind(inner, payload: payload)
        case "function_call":                     // 旧式顶层
            return toolUseKind(payload)
        case "function_call_output":              // 旧式顶层
            return toolResultKind(payload)
        default:
            return nil                            // turn_context / compacted / token 噪声 / 未知
        }
    }

    // MARK: - event_msg.payload.type

    private func eventMsgKind(_ inner: String, payload: [String: Any]) -> (kind: AgentEventKind, detail: String?)? {
        switch inner {
        case "user_message":
            // P3.8 G2:存全文(capped)给会话流展示/展开(同 Claude parser)。
            // 问题1 防御:event_msg 路径实测零注入,但版本变体可能改走此路 → 同样过滤 harness 注入。
            guard let msg = text(payload, "message"),
                  !ParserHelpers.isCodexInjectionNoise(msg) else { return nil }
            return (.userPrompt(text: ParserHelpers.capped(msg) ?? msg), nil)

        case "agent_message":
            // 一律 assistantText(末句问号的「等用户」信号统一由 task_complete 出 —— 避免同一句问候
            // 既走 agent_message 又走 response_item 双发、各被提升成不同 kind 而去重不掉、重复渲染)。
            guard let msg = text(payload, "message") else { return nil }
            return (.assistantText(text: ParserHelpers.capped(msg) ?? msg), nil)

        case "task_complete":
            // 收尾消息以「?」结尾 = 其实在等用户答(把这种 stop suppress 掉)。
            if let last = text(payload, "last_agent_message"), ParserHelpers.looksLikeQuestion(last) {
                return (.awaitingUser(reason: .question(title: ParserHelpers.snippet(last, limit: 48))), nil)
            }
            return (.done, nil)

        case "turn_aborted":
            return (.done, nil)

        case "request_user_input":
            return (.awaitingUser(reason: .question(title: firstCodexQuestion(payload))), nil)

        case "request_permissions":
            return (.awaitingUser(reason: .permission(tool: permissionTool(payload))), nil)

        case "exec_command_begin":
            return (.toolUse(name: "exec", summary: commandSummary(payload)),
                    ParserHelpers.capped(fullCommand(payload)))

        case "exec_command_end":
            return (.toolResult(name: "exec", isError: execFailed(payload)),
                    ParserHelpers.capped(execOutput(payload)))

        case "exec_approval_request":
            return (.awaitingUser(reason: .permission(tool: commandSummary(payload, limit: 40))), nil)

        case "mcp_tool_call_begin":
            return (.toolUse(name: mcpToolName(payload), summary: ""),
                    ParserHelpers.capped(mcpInvocationDetail(payload)))

        case "mcp_tool_call_end":
            // 假设:成功带顶层 `result`,失败缺失。P1 下游不消费 isError(toolResult 不出气泡、
            // 一律折叠成 working),误判无害;若后续阶段要显示失败,需对真实 codex 会话校字段名。
            return (.toolResult(name: mcpToolName(payload), isError: payload["result"] == nil),
                    ParserHelpers.capped(mcpResultDetail(payload)))

        case "token_count":
            // P1-8:不可见载体(映射 `.sessionStart` —— build/buildTurns 不产可见项、impliedState=nil 无 pet 副作用),
            // 真正的 per-turn 上下文占用经 `parse(object:)` 从 `info.last_token_usage` 抽成 `usage` 挂事件上,
            // buildTurns 把它 attach 到进行中的轮(统一与 Claude `message.usage` 的 contextTokens 口径)。
            return (.sessionStart, nil)

        default:
            return nil  // agent_reasoning / item_completed / *review_mode / context_compacted 噪声
        }
    }

    // MARK: - response_item.payload.type

    private func responseItemKind(_ inner: String, payload: [String: Any]) -> (kind: AgentEventKind, detail: String?)? {
        switch inner {
        case "message":
            let role = (payload["role"] as? String) ?? "assistant"
            guard let body = messageText(payload) else { return nil }
            if role == "user" {
                // 问题1:role=user 夹带 harness 注入(AGENTS.md / skill / 环境上下文 / 权限)→ 整条丢弃,
                // 不当真用户消息渲染(Codex 无 isMeta,只能按内容前缀判定;`<task>` 是真 prompt 不在名单)。
                if ParserHelpers.isCodexInjectionNoise(body) { return nil }
                return (.userPrompt(text: ParserHelpers.capped(body) ?? body), nil)
            }
            if role == "assistant" {
                // 一律 assistantText —— 与 agent_message 同 kind(它俩是 Codex 同段输出双发的两路),
                // buildTurns 相邻同文字才能去重折一条;末句问号的「等用户」由 task_complete 统一出。
                return (.assistantText(text: ParserHelpers.capped(body) ?? body), nil)
            }
            return nil   // developer / system 噪声

        case "function_call", "custom_tool_call":
            return toolUseKind(payload)

        case "function_call_output", "custom_tool_call_output":
            return toolResultKind(payload)

        case "web_search_call":
            let query = ((payload["action"] as? [String: Any])?["query"] as? String) ?? ""
            return (.toolUse(name: "web_search", summary: ParserHelpers.snippet(query, limit: 40)),
                    ParserHelpers.capped(query.isEmpty ? nil : query))

        default:
            return nil   // reasoning 噪声
        }
    }

    // MARK: - 工具调用/结果(新旧 function_call 共用;detail = 完整 arguments / output)

    private func toolUseKind(_ payload: [String: Any]) -> (kind: AgentEventKind, detail: String?) {
        let name = (payload["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "tool"
        return (.toolUse(name: name, summary: argumentsSummary(payload)),
                ParserHelpers.capped(argumentsDetail(payload)))
    }

    private func toolResultKind(_ payload: [String: Any]) -> (kind: AgentEventKind, detail: String?) {
        // call_id → tool 名无状态 parser 解不出,P1 留空;失败判定看 status/error/exit_code。
        return (.toolResult(name: "", isError: outputFailed(payload)),
                ParserHelpers.capped(outputDetail(payload)))
    }

    // MARK: - 字段提取 helpers

    /// 非空字符串字段。
    private func text(_ payload: [String: Any], _ key: String) -> String? {
        (payload[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `command`(数组 `["git","push"]` 或字符串)→ 一句话。
    private func commandSummary(_ payload: [String: Any], limit: Int = 56) -> String {
        if let arr = payload["command"] as? [String] {
            return ParserHelpers.snippet(arr.joined(separator: " "), limit: limit)
        }
        if let s = payload["command"] as? String {
            return ParserHelpers.snippet(s, limit: limit)
        }
        if let s = text(payload, "cmd") { return ParserHelpers.snippet(s, limit: limit) }
        return "命令"
    }

    /// exec_command_end 失败:exit_code≠0 或 status=="failed"/"error"。
    private func execFailed(_ payload: [String: Any]) -> Bool {
        if let code = intValue(payload["exit_code"]) { return code != 0 }
        if let status = (payload["status"] as? String)?.lowercased() {
            return status == "failed" || status == "error"
        }
        return false
    }

    /// function_call_output 失败:有 error / status 失败 / 输出里 exit_code≠0。
    private func outputFailed(_ payload: [String: Any]) -> Bool {
        if payload["error"] != nil, !(payload["error"] is NSNull) { return true }
        if let status = (payload["status"] as? String)?.lowercased() {
            if status == "failed" || status == "error" { return true }
        }
        // output 可能是 JSON 串,带 exit_code / metadata.exit_code。
        if let outStr = payload["output"] as? String,
           let data = outStr.data(using: .utf8),
           let outObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let code = intValue(outObj["exit_code"]), code != 0 { return true }
            if let meta = outObj["metadata"] as? [String: Any],
               let code = intValue(meta["exit_code"]), code != 0 { return true }
        }
        return false
    }

    /// function_call 的 `arguments`/`input`(JSON 串)→ 摘要(命令/路径优先,否则空)。
    private func argumentsSummary(_ payload: [String: Any]) -> String {
        let raw = (payload["arguments"] as? String) ?? (payload["input"] as? String)
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        if let cmd = obj["command"] as? [String] {
            return ParserHelpers.snippet(cmd.joined(separator: " "), limit: 48)
        }
        for key in ["command", "cmd", "file_path", "path", "query"] {
            if let s = obj[key] as? String, !s.isEmpty {
                return key.contains("path") ? (s as NSString).lastPathComponent
                                            : ParserHelpers.snippet(s, limit: 48)
            }
        }
        return ""
    }

    // MARK: - detail 全文抽取(给会话流「展开看详情」P3.7;摘要短、detail 全)

    /// exec_command_begin 的完整命令(不截断 —— 对照 `commandSummary` 截 56)。
    private func fullCommand(_ payload: [String: Any]) -> String? {
        if let arr = payload["command"] as? [String] { return arr.joined(separator: " ") }
        if let s = payload["command"] as? String, !s.isEmpty { return s }
        return text(payload, "cmd")
    }

    /// exec_command_end 的完整输出:聚合输出优先,否则 stdout+stderr,再否则 output。
    private func execOutput(_ payload: [String: Any]) -> String? {
        for key in ["aggregated_output", "formatted_output", "output"] {
            if let s = text(payload, key) { return s }
        }
        let parts = ["stdout", "stderr"].compactMap { text(payload, $0) }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// function_call 的完整 arguments:命令优先(最可读),否则 pretty JSON,非 JSON 串原样。
    private func argumentsDetail(_ payload: [String: Any]) -> String? {
        let raw = (payload["arguments"] as? String) ?? (payload["input"] as? String)
        guard let raw, !raw.isEmpty else { return nil }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return raw }
        if let cmd = obj["command"] as? [String] { return cmd.joined(separator: " ") }
        if let cmd = obj["command"] as? String, !cmd.isEmpty { return cmd }
        return ParserHelpers.prettyJSON(obj) ?? raw
    }

    /// function_call_output 的完整输出文本:JSON 包裹 `{output, metadata}` 时抽内层 output,
    /// 否则原样字符串;output 直接是对象时 pretty JSON。
    private func outputDetail(_ payload: [String: Any]) -> String? {
        guard let out = payload["output"] else { return nil }
        if let s = out as? String {
            if let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let inner = obj["output"] as? String, !inner.isEmpty { return inner }
                return ParserHelpers.prettyJSON(obj) ?? s
            }
            return s.isEmpty ? nil : s
        }
        if let obj = out as? [String: Any] {
            if let inner = obj["output"] as? String, !inner.isEmpty { return inner }
            return ParserHelpers.prettyJSON(obj)
        }
        return nil
    }

    /// mcp_tool_call_begin 的 invocation 详情:arguments 优先,否则整个 invocation。
    private func mcpInvocationDetail(_ payload: [String: Any]) -> String? {
        guard let inv = payload["invocation"] as? [String: Any] else { return nil }
        if let args = inv["arguments"] as? [String: Any] { return ParserHelpers.prettyJSON(args) }
        if let argsStr = inv["arguments"] as? String, !argsStr.isEmpty { return argsStr }
        return ParserHelpers.prettyJSON(inv)
    }

    /// mcp_tool_call_end 的 result 详情:字符串原样,对象 pretty JSON。
    private func mcpResultDetail(_ payload: [String: Any]) -> String? {
        if let s = payload["result"] as? String, !s.isEmpty { return s }
        if let obj = payload["result"] as? [String: Any] { return ParserHelpers.prettyJSON(obj) }
        return nil
    }

    private func mcpToolName(_ payload: [String: Any]) -> String {
        guard let inv = payload["invocation"] as? [String: Any] else { return "mcp" }
        return (inv["tool_name"] as? String) ?? (inv["tool"] as? String)
            ?? (inv["name"] as? String) ?? "mcp"
    }

    private func permissionTool(_ payload: [String: Any]) -> String {
        text(payload, "tool") ?? text(payload, "tool_name") ?? text(payload, "reason") ?? "权限"
    }

    /// request_user_input 的标题 = questions[0].question。
    private func firstCodexQuestion(_ payload: [String: Any]) -> String {
        guard let questions = payload["questions"] as? [[String: Any]],
              let first = questions.first else { return "有个问题要问你" }
        if let q = first["question"] as? String, !q.isEmpty { return ParserHelpers.snippet(q, limit: 48) }
        return "有个问题要问你"
    }

    /// response_item message 的 `content` 数组 → 拼接 text。
    private func messageText(_ payload: [String: Any]) -> String? {
        if let s = text(payload, "message") { return s }
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { block -> String? in
            (block["text"] as? String) ?? (block["output_text"] as? String)
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// exit_code 可能是 Int 或字符串。
    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}
