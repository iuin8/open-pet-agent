import Foundation

/// 被感知的外部编码 agent 种类。
public enum AgentKind: String, Sendable, Equatable, Codable {
    case claudeCode
    case codex
}

/// agent 在等用户的原因 —— 决定桌宠「抬头看你」的语气。
public enum AwaitReason: Sendable, Equatable {
    /// Notification hook / 通知:agent 需要你的注意(泛化提醒)。
    case notification(message: String)
    /// AskUserQuestion:agent 抛了个选择题等你选。
    case question(title: String)
    /// 工具权限确认:agent 想跑某工具,等你批。
    case permission(tool: String)
}

/// 从 transcript 解析出的一条「agent 此刻在做什么」事件(P1 只读感知)。
///
/// 设计为**纯值类型 + Foundation only** —— 不绑 AppKit / Rendering / pet 类型,
/// 映射成桌宠情绪在 App/Shell 接线层做(见 `AgentActivityState`)。
public enum AgentEventKind: Sendable, Equatable {
    /// 一个会话开场(transcript 首行 / session_meta)。
    case sessionStart
    /// 用户向 agent 发了一轮 prompt。
    case userPrompt(text: String)
    /// 助手在产出文字(在「说话」/ 解释)。
    case assistantText(text: String)
    /// 助手在「思考」(extended thinking block);`text` 是思考全文(可截断)。会话流折进轮次元数据栏,侧卡看全文。
    case thinking(text: String)
    /// 助手在调一个工具。`summary` 是人话摘要(Bash「npm test」/ Edit「Foo.swift」)。
    case toolUse(name: String, summary: String)
    /// 一个工具跑完(成功 / 出错)。
    case toolResult(name: String, isError: Bool)
    /// 助手停下来等用户(问题 / 权限 / 通知)。
    case awaitingUser(reason: AwaitReason)
    /// 用户中断了当前这一轮(`[Request interrupted by user…]`)。给会话流标「(已中断)」、
    /// 让被打断的轮不再显示「正在思考…」(P1-6)。不出 pet 气泡、不改活动状态。
    case interrupted
    /// 一轮收尾 / 会话静默。
    case done
    /// `/compact` 上下文压缩边界(transcript 里 `isCompactSummary:true` 的 user 行)。不显摘要全文,
    /// 只在会话流插一条「上下文已压缩」分割线(对照 claude-devtools CompactChunk),提示此处往上是被压缩的旧上下文。
    case compactBoundary
}

/// 一条 assistant 消息的 token 用量(transcript `message.usage`)。给会话流轮次元数据栏显「上下文占用」。
public struct TokenUsage: Sendable, Equatable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheCreation: Int

    public init(input: Int, output: Int, cacheRead: Int, cacheCreation: Int) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
    }

    /// 当前上下文窗口占用 ≈ input + cache_read + cache_creation(= 这条消息「看到」的总输入,
    /// 对齐 `SessionMetadataScanner.extractLatestContextTokens` 口径)。
    public var contextTokens: Int { input + cacheRead + cacheCreation }
}

/// 一条感知事件:哪个 agent、哪个会话、在哪个目录、此刻在干嘛、什么时候。
public struct AgentEvent: Sendable, Equatable {
    public let agent: AgentKind
    public let sessionId: String
    /// 会话的工作目录(从 transcript 的 `cwd` 拿;用来在气泡里标项目)。
    public let cwd: String?
    public let kind: AgentEventKind
    public let timestamp: Date
    /// **完整详情**(给会话流的「展开看详情」用):`toolUse` 事件 = 完整 input(命令/diff/参数),
    /// `toolResult` 事件 = 完整 output。`kind` 里只有短摘要,这里存全文(parser 抓,可截断)。
    /// 不改 `AgentEventKind`(43 处 churn)→ 全文挂在事件上,折叠时带进 `ConversationItem.tool`。
    public let detail: String?
    /// tool_use 的 `id`(如 `toolu_01…`)—— Task/Agent 工具行据此关联子 agent transcript
    /// (`{sid}/subagents/agent-*.meta.json` 的 `toolUseId`,D2)。非工具事件 / 无 id → nil。
    public let toolUseId: String?
    /// 这条 assistant 消息的 token 用量(`message.usage`);非 assistant / 无 → nil。给轮次元数据栏显上下文占用。
    public let usage: TokenUsage?
    /// 模型名(`message.model`,如 `claude-opus-4-8`);非 assistant / 无 → nil。给轮次元数据栏显模型徽标。
    public let model: String?
    /// 内联图片(用户粘贴截图 / image 内容块);无 → 空。会话流行渲染缩略图、点击开图片侧卡(P1-5)。
    public let attachments: [ImageAttachment]

    public init(
        agent: AgentKind,
        sessionId: String,
        cwd: String?,
        kind: AgentEventKind,
        timestamp: Date,
        detail: String? = nil,
        toolUseId: String? = nil,
        usage: TokenUsage? = nil,
        model: String? = nil,
        attachments: [ImageAttachment] = []
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.cwd = cwd
        self.kind = kind
        self.timestamp = timestamp
        self.detail = detail
        self.toolUseId = toolUseId
        self.usage = usage
        self.model = model
        self.attachments = attachments
    }

    /// 本事件携带的图片**总字节**(给会话内存预算核算)。
    public var imageByteCount: Int { attachments.reduce(0) { $0 + $1.data.count } }

    /// 丢掉图片字节、只留占位(超会话图片内存预算时,最老的图这样瘦身)→ 缩略图退兜底 photo 图标、
    /// 全图卡显「解码失败」(用户已滚过的老图;要看回去 reset 重读)。kind/文字/元数据全保留。
    public func strippingImageData() -> AgentEvent {
        guard attachments.contains(where: { !$0.data.isEmpty }) else { return self }
        return AgentEvent(
            agent: agent, sessionId: sessionId, cwd: cwd, kind: kind, timestamp: timestamp,
            detail: detail, toolUseId: toolUseId, usage: usage, model: model,
            attachments: attachments.map { ImageAttachment(id: $0.id, data: Data(), mediaType: $0.mediaType) }
        )
    }

    /// cwd 的末段(项目名),供气泡显示。`/Users/me/projects/sample → `pet-agent`。
    public var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
