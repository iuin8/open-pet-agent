import Foundation

/// 会话流的**轮次**(2026-06-16 用户反馈,借 claude-devtools (https://github.com/matt1398/claude-devtools) 的 AIGroup 模型)。主行只剩两类:
/// **用户消息** + **模型一轮**(最终输出 + 折叠的思考/工具元数据)。中间的思考/工具不再各占一行,
/// 折进轮次元数据栏(`✦ model ⚙N · 🧠N · 8.5s  84.4k ›`),点栏 → 侧卡看本轮时间线(`steps`)。
public struct ConversationTurn: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case user(text: String, attachments: [ImageAttachment] = [])
        case assistant(AssistantTurn)
        case awaiting(AwaitReason)
        /// 中性系统通知(如 team/teammate 跨会话消息)。
        case systemNotice(text: String)
        /// `/compact` 上下文压缩边界 → 会话流一条「上下文已压缩」分割线。
        case compactBoundary
    }
    /// 稳定 id = 该轮**首事件**的 id(`idStart+offset`,prepend 时 idStart 同步下移 → 既有轮 id 恒定)。
    public let id: Int
    public let kind: Kind
    public let timestamp: Date
    /// `/compact` 边界携带的压缩摘要;仅 `kind == .compactBoundary` 使用。
    public let compactSummary: String?

    public init(id: Int, kind: Kind, timestamp: Date, compactSummary: String? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.compactSummary = compactSummary
    }
}

/// 模型一轮:最终文字输出 + 中间步骤(思考/工具/中间叙述,给侧卡时间线)+ 元数据(模型/用量/计数/耗时/状态)。
public struct AssistantTurn: Sendable, Equatable {
    /// 本轮 assistant **全部**文字(所有 text 段按文档序 `\n\n` 拼接)。空 = 轮还在跑且未出任何文字 / 纯工具轮。
    /// (2026-06-19 修「总结被埋」:旧版只取末条 text,中间实质叙述沦为元数据 step;现全部文字归此。)
    public let finalText: String
    /// 轮内步骤(思考 + 工具),给元数据侧卡时间线;**不含** text 段(已全部并入 finalText → 总结/元数据分离)。
    public let steps: [TurnStep]
    public let model: String?
    /// 本轮上下文占用(末条 assistant usage 的 contextTokens);无 → nil。
    public let contextTokens: Int?
    /// 轮首→末耗时(秒);无法算 → nil。
    public let durationSeconds: Double?
    public let toolCount: Int
    public let thinkingCount: Int
    /// 任一工具报错。
    public let hasError: Bool
    /// 还在跑(无最终文字 + 末步是 running 工具)。
    public let isRunning: Bool
    /// 这一轮被用户中断(`[Request interrupted by user…]`,P1-6)→ 会话流标「(已中断)」、不显「正在思考…」。
    public let wasInterrupted: Bool
    /// 本轮收尾在等用户答(Codex 末句问号 → task_complete awaiting **折进本轮**,不另起重复 awaiting 卡)。
    /// 仅驱动 footer/tab badge 的「末轮在等你」信号;live pet 仍由 parser 的 `.awaitingUser` 事件直接驱动。
    public let awaitingReply: Bool

    public init(finalText: String, steps: [TurnStep], model: String?, contextTokens: Int?,
                durationSeconds: Double?, toolCount: Int, thinkingCount: Int,
                hasError: Bool, isRunning: Bool,
                wasInterrupted: Bool = false, awaitingReply: Bool = false) {
        self.finalText = finalText
        self.steps = steps
        self.model = model
        self.contextTokens = contextTokens
        self.durationSeconds = durationSeconds
        self.toolCount = toolCount
        self.thinkingCount = thinkingCount
        self.hasError = hasError
        self.isRunning = isRunning
        self.wasInterrupted = wasInterrupted
        self.awaitingReply = awaitingReply
    }
}

/// 轮内一步(给侧卡时间线)。`id` 沿用事件 id(稳定)。
public enum TurnStep: Sendable, Equatable, Identifiable {
    case thinking(id: Int, text: String)
    case text(id: Int, text: String)
    case tool(id: Int, name: String, summary: String, state: ConversationItem.ToolState,
              input: String?, output: String?, toolUseId: String?)

    public var id: Int {
        switch self {
        case .thinking(let id, _), .text(let id, _): return id
        case .tool(let id, _, _, _, _, _, _): return id
        }
    }
}

extension AssistantTurn {
    /// `claude-opus-4-8` → `opus 4.8`;无法解析 → 去 `claude-` 前缀原样。给元数据栏 + 时间线卡标题(跨模块共用)。
    public var shortModelName: String? { model.map(Self.shortModel) }
    public static func shortModel(_ model: String) -> String {
        let s = model.hasPrefix("claude-") ? String(model.dropFirst(7)) : model
        let parts = s.split(separator: "-")
        if parts.count >= 3, Int(parts[parts.count - 1]) != nil, Int(parts[parts.count - 2]) != nil {
            return "\(parts[0..<(parts.count - 2)].joined(separator: "-")) \(parts[parts.count - 2]).\(parts[parts.count - 1])"
        }
        return s
    }
    /// `0.8s` / `8.5s` / `1m30s`。
    public var durationText: String? { durationSeconds.map(Self.fmtDuration) }
    public static func fmtDuration(_ s: Double) -> String {
        if s < 60 { return String(format: "%.1fs", s) }
        return "\(Int(s) / 60)m\(Int(s) % 60)s"
    }
}

extension TurnStep {
    /// 转成 `ConversationItem` 给**轮次时间线侧卡**(复用现有 row/侧卡渲染)。
    var asConversationItem: ConversationItem {
        let ts = Date(timeIntervalSince1970: TimeInterval(id))
        switch self {
        case .thinking(let id, let text): return ConversationItem(id: id, kind: .thinking(text: text), timestamp: ts)
        case .text(let id, let text):     return ConversationItem(id: id, kind: .assistant(text: text), timestamp: ts)
        case .tool(let id, let n, let s, let st, let i, let o, let tid):
            return ConversationItem(id: id, kind: .tool(name: n, summary: s, state: st, input: i, output: o),
                                    timestamp: ts, toolUseId: tid, workflowRunId: n == "Workflow" ? AgentConversation.extractWorkflowRunId(o) : nil)
        }
    }
}

extension AssistantTurn {
    /// **元数据行**(给元数据栏侧卡,2026-06-16 用户反馈:分离):只 steps(思考/工具),**不含**任何 text
    /// (本轮全部文字走 finalText/「总结详情」侧卡 → 元数据行只展思考/工具,减无关干扰)。
    public func stepsItems() -> [ConversationItem] {
        steps.map(\.asConversationItem)
    }
}

extension AgentConversation {

    /// 把 `[AgentEvent]` 折叠成**轮次** `[ConversationTurn]`(turn 模型,借 claude-devtools AIGroup)。
    /// `idStart` 同 `build`:turn.id = 轮首事件 id(`idStart+offset`),prepend 同步下移 → 既有轮 id 恒定。
    public static func buildTurns(from events: [AgentEvent], idStart: Int = 0) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var steps: [TurnStep] = []
        var firstId: Int?
        var firstTs = Date.distantPast
        var lastTs = Date.distantPast
        var lastUsage: TokenUsage?
        var lastModel: String?

        func note(_ id: Int, _ ts: Date, _ usage: TokenUsage?, _ model: String?) {
            if firstId == nil { firstId = id; firstTs = ts }
            lastTs = ts
            if let usage { lastUsage = usage }
            if let model { lastModel = model }
        }

        func flushAssistant(interrupted: Bool = false, awaitingReply: Bool = false) {
            guard let fid = firstId else { return }
            var s = steps
            // 本轮**全部** text 段(按文档序)拼成 finalText —— 模型这一轮说的所有话都是「输出」,不止末条。
            // 修「总结被埋进元数据」(用户 2026-06-19 反馈):旧版只取末条 text 当 finalText,模型先给实质答案、
            // 末尾补一句「下一步…/已启动」时,实质答案沦为 .text step 进元数据侧卡(实测 62/976 多 text 轮中招)。
            // claude-devtools AIChunk 同样保留**全部** assistant responses(非只末条)。texts 全移出 steps
            // (steps 只留思考/工具)→ 与用户「总结 ↔ 元数据分离」诉求一致:主行显全部叙述,元数据侧卡只显思考/工具。
            var textParts: [String] = []
            s.removeAll { step in
                if case .text(_, let t) = step { textParts.append(t); return true }
                return false
            }
            let finalText = textParts.joined(separator: "\n\n")
            let toolCount = s.reduce(0) { if case .tool = $1 { return $0 + 1 }; return $0 }
            let thinkingCount = s.reduce(0) { if case .thinking = $1 { return $0 + 1 }; return $0 }
            let hasError = s.contains { if case .tool(_, _, _, .error, _, _, _) = $0 { return true }; return false }
            let runningTool = s.contains { if case .tool(_, _, _, .running, _, _, _) = $0 { return true }; return false }
            let duration = lastTs > firstTs ? lastTs.timeIntervalSince(firstTs) : nil
            turns.append(ConversationTurn(id: fid, kind: .assistant(AssistantTurn(
                finalText: finalText, steps: s, model: lastModel, contextTokens: lastUsage?.contextTokens,
                durationSeconds: duration, toolCount: toolCount, thinkingCount: thinkingCount,
                // awaitingReply(task_complete 已触发 = 轮结束)与 wasInterrupted 一样,**互斥于 running**:
                // 收尾在等用户的轮不可能还在跑(Codex 串行模型,task_complete 时工具必已收尾)→ 显式排除,
                // 防未来日志乱序产生「在跑 + 在等你」矛盾态误亮 footer/红点。
                hasError: hasError, isRunning: !interrupted && !awaitingReply && finalText.isEmpty && runningTool,
                wasInterrupted: interrupted, awaitingReply: awaitingReply
            )), timestamp: firstTs))
            steps = []; firstId = nil; lastUsage = nil; lastModel = nil
        }

        var prevMsg: AgentEventKind?   // 上一条相邻可见消息(去 Codex 同段双发)
        for (offset, event) in events.enumerated() {
            let id = idStart + offset
            // Codex 同段 user/assistant 输出**双发**(event_msg 通知流 + response_item 持久 item,文字完全相同、
            // 在事件流相邻;新版 codex 才双发,老版只 response_item)→ **内容判等**去重保一条(老会话单发不受影响,
            // Claude 不双发亦无影响)。id 用原 offset、跳过留空隙(无害,同 toolResult 折叠)。见 lessons §7。
            if let prev = prevMsg, Self.isSameAdjacentMessage(prev, event.kind) { continue }
            switch event.kind {
            case .userPrompt, .assistantText: prevMsg = event.kind
            default:                          prevMsg = nil   // 非消息事件打断相邻性(只去真·相邻重复)
            }
            switch event.kind {
            case .userPrompt(let text):
                // ponytail: `/compact` 有时在 compactBoundary 后被历史窗口再次回放;紧邻边界时仍折进同一结构行。
                if text == "/compact", firstId == nil, turns.last?.kind == .compactBoundary { continue }
                flushAssistant()
                turns.append(ConversationTurn(id: id, kind: .user(text: text, attachments: event.attachments), timestamp: event.timestamp))
            case .systemNotice(let text):
                flushAssistant()
                turns.append(ConversationTurn(id: id, kind: .systemNotice(text: text), timestamp: event.timestamp))
            case .awaitingUser(let reason):
                // Codex 收尾问句(task_complete 末句以 ? 结尾 → 此 awaiting)的标题就是 assistant 自己的末条文字,
                // 已由文字气泡渲染 → **折进进行中的 assistant 轮标 awaitingReply**,不另起重复「在等你回答」卡
                // (实机一句问候渲三遍的根因之一)。仅 Codex + 有进行中轮 + 是问句(非权限请求)才折;
                // Claude 的 AskUserQuestion 是独立结构化问题(非自身收尾)、裸 awaiting 无轮可折 → 仍出独立卡。
                if event.agent == .codex, case .question = reason, firstId != nil {
                    flushAssistant(awaitingReply: true)
                } else {
                    flushAssistant()
                    turns.append(ConversationTurn(id: id, kind: .awaiting(reason), timestamp: event.timestamp))
                }
            case .thinking(let text):
                note(id, event.timestamp, event.usage, event.model)
                steps.append(.thinking(id: id, text: text))
            case .assistantText(let text):
                note(id, event.timestamp, event.usage, event.model)
                steps.append(.text(id: id, text: text))
            case .toolUse(let name, let summary):
                note(id, event.timestamp, event.usage, event.model)
                steps.append(.tool(id: id, name: name, summary: summary, state: .running,
                                   input: event.detail, output: nil, toolUseId: event.toolUseId))
            case .toolResult(_, let isError):
                lastTs = event.timestamp
                closeRunningTool(in: &steps, matching: event.toolUseId, isError: isError, output: event.detail)
            case .interrupted:
                // 用户中断:把**进行中**的轮收尾并标「(已中断)」(不再永远「正在思考…」,P1-6);
                // 无进行中的轮(bare 中断)→ 不造空标记轮,避免连续中断刷屏。
                lastTs = event.timestamp
                if firstId != nil { flushAssistant(interrupted: true) }
            case .compactBoundary:
                // /compact 边界:收尾当前轮,插一条独立「上下文已压缩」分割线行;摘要保留到侧卡。
                // ponytail: 把紧邻的 `/compact` 命令回显折进边界,避免 UI 显两条重复压缩动作;若未来要审计命令历史,在 detail 里加来源即可。
                flushAssistant()
                if turns.last?.kind == .user(text: "/compact") { turns.removeLast() }
                turns.append(ConversationTurn(id: id, kind: .compactBoundary, timestamp: event.timestamp, compactSummary: event.detail))
            case .sessionStart, .done:
                // P1-8:Codex `token_count`(映射为不可见 `.sessionStart`)携本轮 usage → attach 到**进行中**的轮,
                // 统一与 Claude `message.usage` 的 contextTokens 口径。不启新轮(firstId 须已由本轮可见事件置位)、不出项。
                // Claude 的真 sessionStart/done 无 usage → 无影响。
                if let u = event.usage, firstId != nil { lastUsage = u }
            }
        }
        flushAssistant()
        return turns
    }

    /// 主流会话流:`buildTurns` → `[ConversationItem]`(用 `.assistantTurn` 折叠 turn)。
    /// 不动 NSTableView 容器(仍吃 ConversationItem),只把扁平流换成轮次流。turn.id → item.id(稳定)。
    public static func buildTurnItems(from events: [AgentEvent], idStart: Int = 0) -> [ConversationItem] {
        buildTurns(from: events, idStart: idStart).map { turn in
            let kind: ConversationItem.Kind
            var attachments: [ImageAttachment] = []
            switch turn.kind {
            case .user(let t, let atts): kind = .user(text: t); attachments = atts   // P1-5:用户行带图
            case .assistant(let a):      kind = .assistantTurn(a)
            case .awaiting(let r):       kind = .awaiting(r)
            case .systemNotice(let t):   kind = .systemNotice(text: t)
            case .compactBoundary:       kind = .compactBoundary
            }
            return ConversationItem(id: turn.id, kind: kind, timestamp: turn.timestamp, attachments: attachments, compactSummary: turn.compactSummary)
        }
    }

    /// 相邻两条可见消息是否「同段重复」(Codex `event_msg` + `response_item` 双发,文字完全相同)。
    /// 只判 user/assistant 文字相等;其余 kind 一律不算重复(工具/思考/中断各自独立)。
    static func isSameAdjacentMessage(_ a: AgentEventKind, _ b: AgentEventKind) -> Bool {
        switch (a, b) {
        case (.userPrompt(let x), .userPrompt(let y)):       return x == y
        case (.assistantText(let x), .assistantText(let y)): return x == y
        default:                                             return false
        }
    }

    /// 从 Workflow 工具输出抽 `Run ID: wf_…` 的 run id(#9 关联 `subagents/workflows/<runId>/`)。无 → nil。
    static func extractWorkflowRunId(_ output: String?) -> String? {
        guard let output, let range = output.range(of: "Run ID: ") else { return nil }
        let id = output[range.upperBound...].prefix { $0 == "_" || $0 == "-" || $0.isLetter || $0.isNumber }
        return id.hasPrefix("wf_") ? String(id) : nil
    }

    /// 收尾一条 running 工具 → 填 state + output。**优先按 `toolUseId` 精确配对**(并行多工具时 tool_result
    /// FIFO 回传,纯位置 LIFO 会把 output 挂错工具);无 id(Codex 一行一事件、单 running 工具)或没匹配到
    /// → 退**后向扫 LIFO** 关最后一条 running(行为同旧实现,Codex 路径正确性不变)。
    private static func closeRunningTool(in steps: inout [TurnStep], matching toolUseId: String?,
                                         isError: Bool, output: String?) {
        func close(_ i: Int) {
            guard case .tool(let id, let n, let s, .running, let input, _, let tid) = steps[i] else { return }
            steps[i] = .tool(id: id, name: n, summary: s, state: isError ? .error : .ok,
                             input: input, output: output, toolUseId: tid)
        }
        if let toolUseId {
            for i in steps.indices.reversed() {
                if case .tool(_, _, _, .running, _, _, let tid) = steps[i], tid == toolUseId { close(i); return }
            }
        }
        for i in steps.indices.reversed() {
            if case .tool(_, _, _, .running, _, _, _) = steps[i] { close(i); return }
        }
    }
}
