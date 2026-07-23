import Foundation

/// 把 Claude Code transcript(`~/.claude/projects/<编码cwd>/<session>.jsonl`)的
/// **一行 JSON** 解析成 `AgentEvent`;噪声行(attachment / mode / file-history /
/// ai-title / system / last-prompt 等)返回 `nil`。
///
/// 实测 schema:顶层 `type` / `cwd` / `sessionId` / `timestamp` + `message{role, content}`。
/// `content` 可能是 `String`(user prompt)或 `[block]`(assistant 的 text/tool_use,
/// user 的 tool_result)。思路参考 claude-devtools (https://github.com/matt1398/claude-devtools)
/// 的 jsonl 解析(只学 schema 处理)。
///
/// 纯函数、无副作用、Foundation only → 好无头单测。
public struct ClaudeTranscriptParser: TranscriptParser {

    public init() {}

    public let agent: AgentKind = .claudeCode

    /// 便捷重载(**测试用**):取首事件;完整多事件(text+tool_use 共存)走 3-arg `parse` / `parse(object:)`。
    public func parse(line: String) -> AgentEvent? {
        parse(line: line, fallbackSessionId: "", fallbackCwd: nil).first
    }

    public func parse(line: String, fallbackSessionId: String, fallbackCwd: String?) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return parse(object: obj, fallbackSessionId: fallbackSessionId, fallbackCwd: fallbackCwd)
    }

    /// 解析**子 agent 自身** transcript(`agent-*.jsonl`/`subagents/*.jsonl`)的一行 → 0..N 事件。
    /// 这类文件**每行都是 `isSidechain: true`**(子 agent 相对主会话是子链)——读它自身时必须**保留** sidechain,
    /// 否则全被主流过滤器滤掉、子 agent 侧卡 body 全空(2026-06-19 修)。子链关系仅在主流解析时才需排除。
    public func parseSubagentLine(_ line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return parse(object: obj, fallbackSessionId: "subagent", fallbackCwd: nil, includeSidechain: true)
    }

    /// 解析已反序列化的 JSON 对象 → **0..N 个事件**(供测试直接喂 dict)。
    /// 一条 assistant 消息的每个 content 块(thinking/text/tool_use)各产一个事件,按文档顺序;
    /// 全部事件共享同条消息的 sessionId/cwd/timestamp/usage/model(usage 在 `buildTurns` 里 last-wins,
    /// 重复携带不会重复计 → 见 `ConversationTurn.note`)。
    public func parse(
        object obj: [String: Any],
        fallbackSessionId: String = "",
        fallbackCwd: String? = nil,
        includeSidechain: Bool = false
    ) -> [AgentEvent] {
        // 子 agent(sidechain)消息不混入**主**会话流 —— 它们的内容经子 agent 侧卡(D2)从独立
        // `agent-*.jsonl` 看;inline 混入会污染主流(对照 claude-devtools SessionContentFilter)。
        // **但读子 agent 自身 transcript 时**(`includeSidechain: true`):整文件都是 isSidechain,
        // 它就是子 agent 的全部内容,**必须保留**,否则子 agent 侧卡 body 全空(见 parseSubagentLine)。
        if !includeSidechain, (obj["isSidechain"] as? Bool) == true { return [] }
        guard let type = obj["type"] as? String else { return [] }
        let parsed = parseKinds(type: type, obj: obj)
        guard !parsed.isEmpty else { return [] }
        let sid = (obj["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackSessionId
        let message = obj["message"] as? [String: Any]
        let cwd = obj["cwd"] as? String ?? fallbackCwd
        let ts = ParserHelpers.parseTimestamp(obj["timestamp"] as? String)
        let usage = Self.parseUsage(message?["usage"] as? [String: Any])   // 轮次元数据栏用量(消息级)
        let model = (message?["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let attachments = (type == "user") ? Self.imageAttachments(in: message) : []   // P1-5:user 图片块 → 缩略图
        return parsed.compactMap { p in
            // 纯图片但图解不出(空 source)→ 空文本 userPrompt 且无附件 = 没内容可显 → 丢(免空行)。
            if case .userPrompt(let t) = p.kind, t.isEmpty, attachments.isEmpty { return nil }
            return AgentEvent(
                agent: .claudeCode,
                sessionId: sid,
                cwd: cwd,
                kind: p.kind,
                timestamp: ts,
                detail: p.detail,
                toolUseId: p.toolUseId,
                usage: usage,
                model: model,
                attachments: attachments
            )
        }
    }

    /// 从 user message 的 content 数组抽 image 块 → 解码 base64 成 `ImageAttachment`(P1-5)。
    /// 兼容两种实测格式:`source.{type:base64,data,media_type}` 与 `file.{base64,media_type}`。解不出 → 跳过。
    static func imageAttachments(in message: [String: Any]?) -> [ImageAttachment] {
        guard let blocks = message?["content"] as? [[String: Any]] else { return [] }
        var out: [ImageAttachment] = []
        for block in blocks where (block["type"] as? String) == "image" {
            let b64: String?
            let media: String
            if let source = block["source"] as? [String: Any] {
                b64 = source["data"] as? String
                media = (source["media_type"] as? String) ?? ""
            } else if let file = block["file"] as? [String: Any] {
                b64 = file["base64"] as? String
                media = (file["media_type"] as? String) ?? ""
            } else {
                b64 = nil; media = ""
            }
            if let b64, !b64.isEmpty,
               let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !data.isEmpty {
                out.append(ImageAttachment(id: out.count, data: data, mediaType: media))
            }
        }
        return out
    }

    /// `message.usage` → `TokenUsage`。全 0 / 缺 → nil。
    static func parseUsage(_ u: [String: Any]?) -> TokenUsage? {
        guard let u else { return nil }
        func n(_ k: String) -> Int { (u[k] as? Int) ?? 0 }
        let usage = TokenUsage(input: n("input_tokens"), output: n("output_tokens"),
                               cacheRead: n("cache_read_input_tokens"), cacheCreation: n("cache_creation_input_tokens"))
        return (usage.input | usage.output | usage.cacheRead | usage.cacheCreation) == 0 ? nil : usage
    }

    // MARK: - Kind 解析(连同详情展开用的完整 input/output + tool_use id)

    private typealias ParsedKind = (kind: AgentEventKind, detail: String?, toolUseId: String?)

    /// 一行 → **0..N 个** kind。`assistant` 遍历所有 content 块各产一个(按文档顺序:思考/叙述/工具,
    /// P0-2 弃旧 `first(where:)` 优先级,根治 text+tool_use 共存时 narration 被吞);`user` 产 0 或 1。
    private func parseKinds(type: String, obj: [String: Any]) -> [ParsedKind] {
        let message = obj["message"] as? [String: Any]
        switch type {
        case "assistant":
            guard let content = message?["content"] as? [[String: Any]] else { return [] }
            var out: [ParsedKind] = []
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    out.append(toolKind(block))
                case "thinking":
                    guard let think = block["thinking"] as? String else { continue }
                    let trimmed = think.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 思考全文(capped)给轮次侧卡;折进元数据栏「🧠N」,不出 pet 气泡(bubbleText 返回 nil)。
                    if !trimmed.isEmpty { out.append((.thinking(text: ParserHelpers.capped(trimmed) ?? trimmed), nil, nil)) }
                case "text":
                    guard let text = block["text"] as? String else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // P3.8 G2:存**全文**(capped 16KB,保留换行)给会话流展示/展开;pet 气泡不消费此文本
                    // (`bubbleText` 对 userPrompt/assistantText 返回 nil)、tracker 只看 kind 变体 → 安全。
                    if !trimmed.isEmpty { out.append((.assistantText(text: ParserHelpers.capped(trimmed) ?? trimmed), nil, nil)) }
                default:
                    continue   // redacted_thinking / 未知块类型 → 跳过
                }
            }
            return out

        case "user":
            // `type:"user"` 双用途:真实用户 prompt + 大量 harness 注入。分类 + 过滤(对照 claude-devtools)。
            return parseUserKind(obj: obj, message: message).map { [$0] } ?? []

        default:
            return []   // attachment / mode / permission-mode / file-history-snapshot / ...
        }
    }

    /// `type:"user"` 一行 → 0 或 1 个 kind(真实 prompt / tool_result / 图文,过滤 harness 注入)。
    private func parseUserKind(obj: [String: Any], message: [String: Any]?) -> ParsedKind? {
        let isMeta = (obj["isMeta"] as? Bool) ?? false
        let content = message?["content"]
        // /compact 后写一条超长 isCompactSummary user 摘要 → 不当用户消息整屏显示,改发 .compactBoundary
        // 在会话流插「上下文已压缩」分割线(对照 claude-devtools CompactChunk),摘要放 detail 供展开查看。
        if (obj["isCompactSummary"] as? Bool) == true { return (.compactBoundary, Self.compactSummary(content), nil) }
        if let str = content as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if ParserHelpers.isInterruption(trimmed) { return (.interrupted, nil, nil) }   // P1-6:中断 → 标记轮,不丢
            if let notice = ParserHelpers.teammateNoticeText(trimmed) { return (.systemNotice(text: notice), trimmed, nil) }
            if ParserHelpers.isClaudeHardNoise(trimmed) { return nil }   // caveat / 提醒 / 命令输出 / bash io
            if let slash = ParserHelpers.extractSlashCommand(trimmed) {  // slash 命令 → 清洗成可读 /cmd
                return (.userPrompt(text: slash), nil, nil)
            }
            return (.userPrompt(text: ParserHelpers.capped(trimmed) ?? trimmed), nil, nil)
        }
        if let blocks = content as? [[String: Any]] {
            // tool_result(工具回传,user 行双用途)→ 保留。不带工具名,但**带 `tool_use_id`** —— 必须透传:
            // 一条 assistant 消息可并行多个 tool_use(P0-2 后各产一 running 步),结果按 id 精确配对才不张冠李戴
            // (FIFO 回传时纯 LIFO 位置配对会把 output 挂错工具,见 `buildTurns.closeRunningTool`)。
            if let result = blocks.first(where: { ($0["type"] as? String) == "tool_result" }) {
                let isError = (result["is_error"] as? Bool) ?? false
                let tuid = (result["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return (.toolResult(name: "", isError: isError),
                        ParserHelpers.capped(Self.toolResultOutput(result)), tuid)
            }
            // **真实「图+文」prompt**:content 是 [{image},{text}] 无 tool_result(修 #31 漏显:旧分支只认
            // tool_result → 整条被丢)。isMeta=true 是内部注入(skill base-dir / Continue / [Image:source])→ 丢。
            if isMeta { return nil }
            let texts = blocks.compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }
            let hasImage = blocks.contains { ($0["type"] as? String) == "image" }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // P1-5:图片走 `attachments` 真渲染缩略图(由 parse(object:) 抽),**不再** `[图片]` 占位文字。
            // 纯图片(无文字)→ 空文本 userPrompt(行只渲缩略图);图文 → 仅文字(图另渲)。
            if joined.isEmpty { return hasImage ? (.userPrompt(text: ""), nil, nil) : nil }
            if ParserHelpers.isInterruption(joined) { return (.interrupted, nil, nil) }   // P1-6:array 形态中断标也升标记
            if let notice = ParserHelpers.teammateNoticeText(joined) { return (.systemNotice(text: notice), joined, nil) }
            if ParserHelpers.isClaudeHardNoise(joined) { return nil }
            return (.userPrompt(text: ParserHelpers.capped(joined) ?? joined), nil, nil)
        }
        return nil
    }

    /// compact summary 的正文:`message.content` 可能是 String 或 text blocks。空 → nil。
    static func compactSummary(_ content: Any?) -> String? {
        if let text = content as? String { return ParserHelpers.capped(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let blocks = content as? [[String: Any]] {
            let text = blocks.compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ParserHelpers.capped(text)
        }
        return nil
    }

    private func toolKind(_ block: [String: Any]) -> (AgentEventKind, String?, String?) {
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let toolUseId = (block["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }   // Task/Agent 行据此关联子 agent
        if name == "AskUserQuestion" {
            return (.awaitingUser(reason: .question(title: Self.firstQuestionTitle(input))),
                    ParserHelpers.capped(Self.askUserQuestionDetail(input)), toolUseId)
        }
        return (.toolUse(name: name, summary: Self.toolSummary(name: name, input: input)),
                ParserHelpers.capped(Self.toolInputDetail(name: name, input: input)), toolUseId)
    }

    // MARK: - 详情全文抽取(给会话流「展开看详情」)

    /// 工具完整输入:Bash→命令、Edit→old/new 前后对照、Write→content、Read→路径、其余→pretty JSON。
    static func toolInputDetail(name: String, input: [String: Any]) -> String? {
        func str(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "Bash":
            return str("command")
        case "Edit":
            if let old = str("old_string"), let new = str("new_string") {
                let oldLines = "- " + old.replacingOccurrences(of: "\n", with: "\n- ")
                let newLines = "+ " + new.replacingOccurrences(of: "\n", with: "\n+ ")
                return oldLines + "\n" + newLines
            }
            return ParserHelpers.prettyJSON(input)
        case "Write":
            return str("content")
        case "Read":
            return str("file_path")
        default:
            return ParserHelpers.prettyJSON(input)
        }
    }

    /// tool_result 的输出文本:`content` 可能是 String 或 `[{type:text, text}]`。
    static func toolResultOutput(_ result: [String: Any]) -> String? {
        if let text = result["content"] as? String { return text }
        if let blocks = result["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    // MARK: - 人话摘要

    /// 把工具输入压成一句人话:Bash→命令、Edit/Write/Read→文件名、Grep→pattern…
    static func toolSummary(name: String, input: [String: Any]) -> String {
        func str(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        switch name {
        case "Bash":
            return ParserHelpers.snippet(str("description") ?? str("command") ?? "命令", limit: 56)
        case "Edit", "Write", "Read", "NotebookEdit":
            return str("file_path").map { ($0 as NSString).lastPathComponent } ?? name
        case "Grep", "Glob":
            return str("pattern").map { ParserHelpers.snippet($0, limit: 40) } ?? name
        case "Task", "Agent":
            return ParserHelpers.snippet(str("description") ?? str("subagent_type") ?? name, limit: 40)
        case "WebFetch", "WebSearch":
            return ParserHelpers.snippet(str("url") ?? str("query") ?? name, limit: 48)
        default:
            return name
        }
    }

    /// AskUserQuestion 完整详情:问题、选项、描述。用于 awaiting 行侧卡,不走通用 JSON 噪声。
    static func askUserQuestionDetail(_ input: [String: Any]) -> String? {
        guard let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else { return nil }
        let parts = questions.enumerated().compactMap { idx, q -> String? in
            guard let text = (q["question"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
            var lines: [String] = []
            if let header = (q["header"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                lines.append("标题：\(header)")
            }
            lines.append("问题：\(text)")
            if (q["multiSelect"] as? Bool) == true { lines.append("可多选：是") }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { opt -> String? in
                guard let label = (opt["label"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
                if let desc = (opt["description"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                    return "- \(label)：\(desc)"
                }
                return "- \(label)"
            }
            if !options.isEmpty {
                lines.append("选项：")
                lines.append(contentsOf: options)
            }
            return (questions.count > 1 ? "# 问题 \(idx + 1)\n" : "") + lines.joined(separator: "\n")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// AskUserQuestion 的标题 = 第一个问题的 header / question。
    static func firstQuestionTitle(_ input: [String: Any]) -> String {
        guard let questions = input["questions"] as? [[String: Any]],
              let first = questions.first else { return "有个问题要问你" }
        if let header = first["header"] as? String, !header.isEmpty { return header }
        if let q = first["question"] as? String, !q.isEmpty { return ParserHelpers.snippet(q, limit: 48) }
        return "有个问题要问你"
    }
}
