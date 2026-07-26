import Foundation

/// 对话卡片里的一条消息行（user 或 assistant）。`Identifiable` 供 SwiftUI ForEach 稳定身份；
/// `text` 可变以承接流式 delta 覆写。App 层从 `ConversationStore` 历史映射成它（开卡片恢复）。
public struct ChatCardRow: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public var text: String
    public let timestamp: Date
    /// P5:assistant 消息的来源 engine 短标签(@mention 多引擎署名 chip;nil = 不显示)。
    public let source: String?

    public init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date(), source: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.source = source
    }
}

/// ACP 会话列表项(P2,App 从 `ACPSessionInfo` 映射;Shell 不依赖 AgentMode)。
public struct ACPSessionItem: Identifiable, Equatable, Sendable {
    /// ACP sessionId。
    public let id: String
    /// 展示标题(agent 未给时 App 兜底为 sessionId 前缀)。
    public let title: String
    /// 最近活动时间(解析自 agent 的 ISO 8601;nil = 未报)。
    public let updatedAt: Date?
    /// 是否当前会话(列表里打勾)。
    public let isCurrent: Bool

    public init(id: String, title: String, updatedAt: Date? = nil, isCurrent: Bool = false) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.isCurrent = isCurrent
    }
}

/// 对话卡片的 observable 状态。SwiftUI view 经 `@ObservedObject` 读写。
///
/// 用 `ObservableObject + @Published`（沿用历史;target 已升 macOS 15,可换 `@Observable` 但够用未迁）。
/// **store 是写权威**（流式经 orchestrator `replyStream` 写 `ConversationStore`），本类的
/// `messages` 只是渲染缓存：发送时乐观追加，流式把 delta 覆写进占位 assistant row，开卡片时
/// 由 `load(history:)` 从 store 快照重填。不反向写 store，避免双写打架。
@MainActor
public final class ChatCardState: ObservableObject {
    /// 渲染用的消息列表（user/assistant 交替）。
    @Published public var messages: [ChatCardRow] = []
    /// composer 输入草稿（双向绑定）。
    @Published public var draft: String = ""
    /// 是否有一轮回答正在流式中（禁发送 + 显示打点）。
    @Published public var isSending: Bool = false
    /// agent 思考中(ACP `agent_thought_chunk` 来时 true;流式 message 来时 false)。
    /// ACP engine 专属(灵魂层无 thought);`isSending` 期间子状态,UI 显示「思考中」替代打点。
    @Published public var isThinking: Bool = false
    /// ACP `usage_update` 直报的上下文已用 token。nil = 尚无用量数据(composer 上方占用条不显示)。
    @Published public var contextUsed: Int?
    /// ACP `usage_update` 直报的上下文窗口总大小(token)。
    @Published public var contextSize: Int?
    /// ACP `usage_update` 的累计费用(App 预格式化展示串,如 "$0.0123";nil = agent 未报)。
    @Published public var contextCost: String?
    /// 该轮 token 明细(App 预格式化,如 "in 2.5k · cache 52.1k · out 0.3k";占用条 tooltip;
    /// nil = agent 未报明细 —— codex 路径)。
    @Published public var contextDetail: String?

    // MARK: - ACP 会话管理(P2)

    /// ACP 会话列表(session/list 结果,App 映射注入;按 agent 返回序,opencode 最近优先)。
    /// 空 = 尚未拉取或无会话;`acpSessionUIEnabled` 为 false 时 UI 整体不显示。
    @Published public var acpSessions: [ACPSessionItem] = []
    /// ACP 会话 UI 总开关(App 能力探测后注入:loadSession + list 都支持才 true)。
    @Published public var acpSessionUIEnabled: Bool = false
    /// 会话列表拉取/切换/恢复在途(popover 里显 spinner)。
    @Published public var isLoadingACPSessions: Bool = false
    /// 选中会话回调(App 注入:loadSession 回放重建消息 + 持久化指针 + 刷列表)。
    public var onSelectACPSession: (@MainActor (String) -> Void)?
    /// 新会话回调(App 注入:newSession + 清时间线 + 持久化指针 + 刷列表)。
    public var onRequestNewACPSession: (@MainActor () -> Void)?
    /// 刷新列表回调(App 注入:popover 打开时重新 session/list)。
    public var onRefreshACPSessions: (@MainActor () -> Void)?
    /// 进场缩放锚点对应的边（由锚定结果驱动 spring transition）。
    @Published public var entranceEdge: ChatCardEdge = .above
    /// 是否已"放大就位"。controller 每次 show 先置 false 再 `withAnimation` 置 true →
    /// spring 进场每次都重播（不靠 SwiftUI onAppear，那个 orderOut/orderFront 复用窗口时不重触发）。
    @Published public var isShown: Bool = false
    /// 尖角指向 pet 的边 + 在该边上的相对位置（controller 按锚定结果 + pet 实时位置算，pet 移动时更新 → 尖角跟随）。
    @Published public var tailSide: SpeechBubbleTailSide = .bottom
    @Published public var tailPercent: CGFloat = 0.5
    /// 当前选中的 tab（Pet Chat / Claude Code / Codex）。提到 state 而非 view `@State`，
    /// 让 controller / App 能**程序化切 tab**（权限来了自动切到 Claude Code tab）。
    @Published public var selectedTab: CompanionTab = .petChat
    /// 主卡钉住态（#3）。**默认钉住**=floating+1+.stationary 常驻浮顶（保唤起可见 + 跨 Space 不被隐藏，
    /// 避 accessory activate 闪 Dock）；取消钉住 → .normal+.transient 可被其他 app 盖住（标准切应用行为）。
    @Published public var isPinned: Bool = true

    /// 当前 agent 工作项目(Composer 上方 `ProjectMenu` 的当前选中)。
    /// App 注入(开卡时从 `ProjectStore.current()` 派生);切换经 `commitProject` 触发持久化 + 重 apply engine。
    @Published public var currentProject: ProjectOption?
    /// 可选项目列表(App 从 `ProjectStore.list()` 派生注入)。
    @Published public var projects: [ProjectOption] = []
    /// 最近一次项目配置显式同步结果，仅用于当前卡片反馈。
    @Published public var codexProjectionSyncMessage: String?
    /// 切换项目回调(App 注入:写 UD `tool.project.id` + `applySelectedAgentEngine` 重 apply 即时生效)。
    public var onCommitProject: (@MainActor (String) -> Void)?
    /// 请求创建项目回调(App 注入:弹 NSAlert 收名字 + `ProjectStore.create` + 刷新)。
    public var onRequestCreateProject: (@MainActor () -> Void)?

    /// 切换项目 + 触发 `onCommitProject`(本地先更新 currentProject 乐观刷新 UI)。
    public func commitProject(_ id: String) {
        if let opt = projects.first(where: { $0.id == id }) {
            currentProject = opt
        }
        codexProjectionSyncMessage = nil
        onCommitProject?(id)
    }
    /// 请求创建项目(触发 `onRequestCreateProject`)。
    public func requestCreateProject() {
        onRequestCreateProject?()
    }
    /// 请求添加外部项目(NSOpenPanel,触发 `onRequestCreateExternal`)。
    public var onRequestCreateExternal: (@MainActor () -> Void)?
    /// 请求重命名当前项目(NSAlert 收新名,触发 `onRequestRenameCurrent`)。
    public var onRequestRenameCurrent: (@MainActor () -> Void)?
    /// 请求删除当前项目(NSAlert 确认,触发 `onRequestDeleteCurrent`)。
    public var onRequestDeleteCurrent: (@MainActor () -> Void)?
    /// 请求显式同步当前项目的 Codex projection（App 层执行落盘 + 返回提示文案）。
    public var onRequestSyncCodexProjection: (@MainActor () -> String)?
    /// 请求显式同步当前项目的 Claude Code projection（App 层执行落盘 + 返回提示文案）。
    public var onRequestSyncClaudeCodeProjection: (@MainActor () -> String)?
    /// 请求显式同步当前项目的 opencode projection（App 层执行落盘 + 返回提示文案）。
    public var onRequestSyncOpencodeProjection: (@MainActor () -> String)?
    /// 请求显示独立项目能力管理卡片（App 层负责窗口和写入）。
    public var onRequestShowProjectCapabilityManager: (@MainActor () -> Void)?

    public func requestCreateExternal() { onRequestCreateExternal?() }
    public func requestRenameCurrent() { onRequestRenameCurrent?() }
    public func requestDeleteCurrent() { onRequestDeleteCurrent?() }
    public func requestSyncCodexProjection() {
        codexProjectionSyncMessage = onRequestSyncCodexProjection?()
    }
    public func requestSyncClaudeCodeProjection() {
        codexProjectionSyncMessage = onRequestSyncClaudeCodeProjection?()
    }
    public func requestSyncOpencodeProjection() {
        codexProjectionSyncMessage = onRequestSyncOpencodeProjection?()
    }
    public func requestShowProjectCapabilityManager() {
        codexProjectionSyncMessage = nil
        onRequestShowProjectCapabilityManager?()
    }
    public func dismissProjectCapabilityPanel() {
    }

    /// 当前 in-flight stream task，cancel 用。非 @Published（不直接驱动 UI）。
    public var streamTask: Task<Void, Never>?

    // MARK: - @mention 补全弹层 + P6 pin 模型

    /// 补全候选(App 开卡时注入:`AgentMention` 引擎候选 + soul 行 × registry 展示/logo ×
    /// CLI 可用性)。空 → 不弹补全。
    @Published public var mentionOptions: [MentionOption] = []
    /// P6:当前钉住的引擎 trigger(nil = 未钉,默认灵魂层)。App 注入/刷新;
    /// composer 目标图标按它 + draft 解析有效目标(`ComposerTargetResolver`)。
    @Published public var pinnedMentionTrigger: String?
    /// P6:composer 钉住回调(App 注入:UD enabled+kind 写入 + engine 装配 + 配置刷新)。
    public var onPinMentionTrigger: (@MainActor (String) -> Void)?
    /// P6:composer 取消钉住回调(App 注入:UD enabled=false + engine 释放 + 配置刷新)。
    public var onUnpinMention: (@MainActor () -> Void)?

    public init() {}

    /// 乐观追加：一条 user + 一条空 assistant（占位，供流式覆写）。返回 assistant row 的 id。
    /// P5:`assistantSource` = 目标 engine 短标签(@mention 署名 chip,App 注入解析;nil 无 chip)。
    public func appendExchangePlaceholder(userText: String, now: Date = Date(), assistantSource: String? = nil) -> UUID {
        messages.append(ChatCardRow(role: .user, text: userText, timestamp: now))
        let assistant = ChatCardRow(role: .assistant, text: "", timestamp: now, source: assistantSource)
        messages.append(assistant)
        return assistant.id
    }

    /// 流式 delta：定位 assistant row 覆写文本（覆写语义，传入累积全文）。
    public func updateAssistant(id: UUID, text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
    }

    /// 用历史快照重填（开卡片时从 `ConversationStore` 恢复）。
    public func load(history rows: [ChatCardRow]) {
        messages = rows
    }

    /// 取消 in-flight stream（隐藏卡片时调）。保留 messages（重开仍在），只停流。
    public func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isSending = false
        isThinking = false
    }
}
