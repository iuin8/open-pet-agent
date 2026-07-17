import Foundation

/// 一条可渲染的会话项 —— `AgentSessionTabView` 据此画外部会话流。
/// 纯值类型、Foundation only(渲染在 Shell 层)。
public struct ConversationItem: Sendable, Equatable, Identifiable {

    public enum ToolState: Sendable, Equatable { case running, ok, error }

    public enum Kind: Sendable, Equatable {
        case user(text: String)
        case assistant(text: String)
        /// 工具调用:`toolUse` 起一条 `.running`,紧随的 `toolResult` 把它收尾成 `.ok`/`.error`。
        /// `input` = 完整输入(命令/diff/参数,来自 toolUse 事件 detail),`output` = 完整输出
        /// (来自 toolResult 事件 detail)—— 给会话流「展开看详情」(P3.7);摘要短、详情全。
        case tool(name: String, summary: String, state: ToolState, input: String?, output: String?)
        case awaiting(AwaitReason)
        /// 助手「思考」(extended thinking)—— 仅出现在**轮次时间线侧卡**(主流被折进元数据栏);`text` 全文。
        case thinking(text: String)
        /// **模型一轮**(2026-06-16 turn 模型):主流的 assistant 行 = 最终输出 + 折叠的思考/工具元数据。
        /// 携 `AssistantTurn`(finalText + steps + 模型/用量/计数/状态)→ 渲染元数据栏 + 最终文字,点 → 时间线侧卡。
        case assistantTurn(AssistantTurn)
        /// `/compact` 上下文压缩边界 → 渲染一条「上下文已压缩」分割线(不可点)。
        case compactBoundary
    }

    /// 稳定序号(按构建顺序递增),供 SwiftUI `Identifiable` / 滚动定位。
    public let id: Int
    public let kind: Kind
    public let timestamp: Date
    /// `.tool` 行的 tool_use id(Task/Agent 行据此关联子 agent transcript,D2)。其余 nil。
    public let toolUseId: String?
    /// 内联图片(用户粘贴截图);`.user` 行渲染缩略图、点击开图片侧卡(P1-5)。其余空。
    public let attachments: [ImageAttachment]
    /// `.tool(name: "Workflow")` 行的 run id。作为存储字段缓存，避免行高/Equatable 热路径反复扫描完整 output。
    public let workflowRunId: String?

    public init(id: Int, kind: Kind, timestamp: Date, toolUseId: String? = nil, attachments: [ImageAttachment] = [], workflowRunId: String? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.toolUseId = toolUseId
        self.attachments = attachments
        self.workflowRunId = workflowRunId
    }
}

// MARK: - 详情展开方式(P3.7)

extension ConversationItem {
    /// tool 项的详情(input/output)该用哪种方式展开 —— 纯数据语义,渲染层(`AgentConversationRow`)据此分发。
    ///
    /// **2026-06-16 用户反馈「所有看详情展开功能都统一放到侧卡中去」**:取消内联 accordion(`.inline` 退役),
    /// 凡有可看详情一律弹侧卡 —— 渲染只剩 `.none`(无详情,普通行)/`.sideCard`(有详情,点行弹侧卡)两态。
    public enum DetailAffordance: Sendable, Equatable {
        case none       // 无可看详情 → 普通行,不可展开
        case sideCard   // 有详情(工具 input/output / 长文本)→ 点行弹侧卡看全文
    }

    /// 文本消息(user / 模型总结)折叠 + 弹侧卡的阈值 —— **最多 3 行**(2026-06-16 用户反馈:主流只留精简,
    /// 超 3 行截断 + 点击看详情,减无关信息干扰)。行数或字符任一超即走侧卡(折叠态视觉再 `lineLimit(3)` 钉死)。
    /// 字符阈值按窄卡(360)中文为主调:≈3 中文行(60-70 字)。跨语种字宽差异 → 偏宽即视觉 ≤3 行(安全:宁可多显不截断无入口)。
    public static let textSideCardLineLimit = 3
    public static let textSideCardCharLimit = 70

    /// 此项是否「在等用户」—— 独立 `.awaiting` 卡(Claude AskUserQuestion / 裸 awaiting)或 Codex 收尾问句
    /// 折进 assistant 轮的 `awaitingReply`。供 `isAwaitingLast`(footer)/ `tabBadge`(红点)共用,免两处 switch 漂移。
    public var isAwaiting: Bool {
        switch kind {
        case .awaiting: return true
        case .assistantTurn(let a): return a.awaitingReply
        default: return false
        }
    }

    /// 此项的详情展开方式。
    /// - `.tool`:带非空 input/output → `.sideCard`(无论长短,统一弹侧卡);全空 → `.none`。
    /// - `.user`/`.assistant`:超文本阈值(很长)→ `.sideCard`(折叠 + 弹侧卡看全文);否则 `.none`(全宽直接展示)。
    public var detailAffordance: DetailAffordance {
        switch kind {
        case .tool(_, _, _, let input, let output):
            let details = [input, output].compactMap { $0 }.filter { !$0.isEmpty }
            return details.isEmpty ? .none : .sideCard
        case .user(let text), .assistant(let text), .thinking(let text):
            return Self.textExceedsSideCardBudget(text) ? .sideCard : .none
        case .assistantTurn(let a):
            // 有思考/工具(时间线可看)或最终文字很长 → 点开侧卡;纯短文字轮 → 内联直显。
            return (a.toolCount + a.thinkingCount > 0 || Self.textExceedsSideCardBudget(a.finalText)) ? .sideCard : .none
        case .awaiting, .compactBoundary:
            return .none
        }
    }

    /// 文本消息是否长到该折叠 + 弹侧卡(行数或字符任一超文本阈值)。
    private static func textExceedsSideCardBudget(_ text: String) -> Bool {
        if text.count > textSideCardCharLimit { return true }
        let lineCount = text.reduce(into: 1) { acc, ch in if ch == "\n" { acc += 1 } }
        return lineCount > textSideCardLineLimit
    }
}

/// 把 `[AgentEvent]` 折叠成 `[ConversationItem]`:`toolUse` + 紧随**同会话**的 `toolResult`
/// 合成一条带成败的 `.tool`;`userPrompt`/`assistantText`/`awaitingUser` 直出;
/// `sessionStart`/`done` 不产可见项。纯函数、无副作用 → 好无头单测。
public enum AgentConversation {

    /// `idStart` = 第一条事件对应的 id 基准(P3.8 G4 增量加载用)。**id = `idStart + 事件下标`** ——
    /// 这样 prepend 更早窗口时调用方把 `idStart` 同步下移 P,既有 item 的 id **恒定不漂**(滚动锚定 /
    /// 展开集 / 高亮引用都稳)。折叠掉的 toolResult 留下 id 空隙(无害:id 只用于 diff/定位,从不显示)。
    /// 默认 0 → 旧行为(单次构建,无增量)。
    public static func build(from events: [AgentEvent], idStart: Int = 0) -> [ConversationItem] {
        var items: [ConversationItem] = []

        for (offset, event) in events.enumerated() {
            let id = idStart + offset
            switch event.kind {
            case .userPrompt(let text):
                items.append(ConversationItem(id: id, kind: .user(text: text), timestamp: event.timestamp, attachments: event.attachments))
            case .assistantText(let text):
                items.append(ConversationItem(id: id, kind: .assistant(text: text), timestamp: event.timestamp))
            case .toolUse(let name, let summary):
                // input = toolUse 事件的完整详情(命令/diff/参数);output 待紧随的 toolResult 填。
                // toolUseId 透传 → Task/Agent 行据此关联子 agent transcript(D2)。
                items.append(ConversationItem(id: id, kind: .tool(name: name, summary: summary, state: .running, input: event.detail, output: nil), timestamp: event.timestamp, toolUseId: event.toolUseId))
            case .toolResult(_, let isError):
                // 收尾一条 still-running 的 tool 项。**优先按 tool_use_id 精确配对**(同条消息并行多工具时
                // tool_result 常 FIFO 回传,纯位置 LIFO 会把 output 挂错工具,见 lessons §5.14);无 id 退 LIFO。
                // output = toolResult 事件的完整详情(工具输出),input 保留 toolUse 已存的。
                if let idx = runningToolIndex(in: items, matching: event.toolUseId) {
                    let old = items[idx]
                    if case .tool(let n, let s, _, let input, _) = old.kind {
                        items[idx] = ConversationItem(
                            id: old.id,
                            kind: .tool(name: n, summary: s, state: isError ? .error : .ok, input: input, output: event.detail),
                            timestamp: old.timestamp, toolUseId: old.toolUseId,
                            workflowRunId: n == "Workflow" ? extractWorkflowRunId(event.detail) : old.workflowRunId
                        )
                    }
                }
                // 孤立 toolResult(无匹配 running tool)忽略,不产项。
            case .awaitingUser(let reason):
                items.append(ConversationItem(id: id, kind: .awaiting(reason), timestamp: event.timestamp))
            case .compactBoundary:
                items.append(ConversationItem(id: id, kind: .compactBoundary, timestamp: event.timestamp))
            case .sessionStart, .done, .thinking, .interrupted:
                break   // 不产**扁平**可见项(thinking 折进轮次;中断标只在轮次流 buildTurns 显,扁平子 agent 流不显)
            }
        }
        return items
    }

    /// 一条 running tool 的下标:**优先按 toolUseId 精确配对**(并行多工具 FIFO 回传时不张冠李戴),
    /// 无 id(Codex / 旧行)或没匹配到 → 退后向扫 LIFO(行为同旧实现)。
    private static func runningToolIndex(in items: [ConversationItem], matching toolUseId: String?) -> Int? {
        if let toolUseId {
            for idx in items.indices.reversed() {
                if case .tool(_, _, .running, _, _) = items[idx].kind, items[idx].toolUseId == toolUseId { return idx }
            }
        }
        for idx in items.indices.reversed() {
            if case .tool(_, _, .running, _, _) = items[idx].kind { return idx }
        }
        return nil
    }
}
