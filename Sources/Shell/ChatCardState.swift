import Foundation

/// 对话卡片里的一条消息行（user 或 assistant）。`Identifiable` 供 SwiftUI ForEach 稳定身份；
/// `text` 可变以承接流式 delta 覆写。App 层从 `ConversationStore` 历史映射成它（开卡片恢复）。
public struct ChatCardRow: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public var text: String
    public let timestamp: Date

    public init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
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

    /// 回复来源（灵魂层 vs Agent 层 engine）—— Composer 上方 segmented 的当前选中。
    /// App 注入（开卡时从 UserDefaults 派生）；用户切换经 `commitReplyTarget` 触发持久化。
    @Published public var replyTarget: ReplyTarget = .soul
    /// 可选回复来源列表（App 从 `AgentEngineRegistry.all` 派生注入）。空 → 不渲染 `ReplySourceBar`。
    @Published public var replyOptions: [ReplyOption] = []
    /// 切换回复来源回调（App 注入：写 UserDefaults + `router.setEngine` 即时生效）。nil → 仅改本地（测试/preview）。
    public var onCommitReplyTarget: (@MainActor (ReplyTarget) -> Void)?

    /// 设置回复来源 + 触发 `onCommitReplyTarget`（持久化 + 即时切 engine）。
    public func commitReplyTarget(_ target: ReplyTarget) {
        replyTarget = target
        onCommitReplyTarget?(target)
    }

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

    /// 当前 in-flight stream task，cancel 用。非 @Published（不直接驱动 UI）。
    public var streamTask: Task<Void, Never>?

    public init() {}

    /// 乐观追加：一条 user + 一条空 assistant（占位，供流式覆写）。返回 assistant row 的 id。
    public func appendExchangePlaceholder(userText: String, now: Date = Date()) -> UUID {
        messages.append(ChatCardRow(role: .user, text: userText, timestamp: now))
        let assistant = ChatCardRow(role: .assistant, text: "", timestamp: now)
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
