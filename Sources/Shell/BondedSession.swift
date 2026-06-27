import AppKit

/// `BondedSession` 把 chat reply / streamingReply 业务层接到桌宠原位的
/// `BondedBubbleChain` 上 —— 是 phase A.5.3 phase 2 的 driver layer。
///
/// 职责：
///   - 持有挂在桌宠窗口上的 `BondedBubbleChain`（链状气泡管理）。
///   - 把"用户输入 + 助手回答"业务调用转成 chain 的 append 序列。
///   - 兼容 atomic 与 streaming 两条回复路径，行为与 `ChatShellView` /
///     `StageInputView` 一致（同一个 `replyHandler` / `streamingReplyHandler`
///     contract）。
///   - 用 monotonically increasing send identifier 防止旧 stream 写到新一轮
///     的助手气泡上（"stale stream guard"，镜像 `ChatShellView.sendCurrentMessage`
///     的护栏）。
///
/// **MVP 范围**：
///   - ✅ append 用户气泡 + assistant 气泡，streaming tokens 累积进 assistant 气泡
///   - ✅ atomic 回复路径一次性 setText
///   - ✅ stale stream guard
///   - ❌ 不暴露 `NSTextField` —— 输入捕获 UI 由调用方（`MinimalAppDelegate` 加
///        快捷键 / pet 双击触发）提供，BondedSession 接受字符串调用即可
///   - ❌ 不接 `ChatBehaviorStateMachine` —— 那一层 main agent 在 wiring 处包
///        ：与 stage wire 的模式一致，handler 闭包在外面已经 emit `.chatSendBegan`
///        / `.chatReplyBegan` / `.chatReplyReceived`
///   - ❌ 没"打字时气泡随字数扩张"动画 —— phase 3 视觉打磨
@MainActor
public final class BondedSession {

    // MARK: - Public typealiases (mirror ChatShellView / StageInputView)

    public typealias ReplyHandler = @MainActor (String) async -> String
    public typealias StreamingReplyHandler =
        @MainActor (String) -> AsyncThrowingStream<String, Error>

    // MARK: - Public surface

    /// 暴露 chain 给测试与 main agent 调用方做底层 inspection / clear。
    public let chain: BondedBubbleChain

    /// 当前是否处于 streaming 状态（首 token 已开始累积、最后一个 token 还没到）。
    /// `false` 表示 idle 或 atomic 回复路径正在 await（atomic 走完一次 setText
    /// 才标记完成 —— atomic 路径的 isStreaming 仅在 await 期间为 true）。
    public private(set) var isStreaming: Bool = false

    // MARK: - Init

    /// - Parameters:
    ///   - petWindow: 桌宠窗口 —— 链作为 child window 挂在上面，跟随桌宠移动。
    ///   - replyHandler: atomic 回复路径。`streamingReplyHandler` 为 nil 时走这条。
    ///   - streamingReplyHandler: 可选 streaming 路径。非 nil 时优先走 streaming。
    ///   - onChoiceSelected: 用户点击 assistant 富文本气泡里的 ChoiceCard 时
    ///     callback,通常 wire 到当前 input field 的"填入但不发送"路径
    ///     (HermesPet 决策 #17 防误触)。nil 时 ChoiceCard 退化为普通编号列表。
    ///   - onErrorSignal: N3.3 — streaming 出错时 callback (chain 已 surface
    ///     error 气泡之后再调)。MinimalAppDelegate 注入 → 触发
    ///     `dispatchSignature(.refuse)` 让 pet 形象做"拒绝"反应。nil 时不
    ///     dispatch (但 chain 错误气泡仍显示)。
    public init(
        attachedToPet petWindow: NSWindow,
        replyHandler: @escaping ReplyHandler,
        streamingReplyHandler: StreamingReplyHandler? = nil,
        onChoiceSelected: ((String) -> Void)? = nil,
        onErrorSignal: ((Error) -> Void)? = nil,
        onProactiveBubbleShown: (() -> Void)? = nil
    ) {
        self.chain = BondedBubbleChain(
            attachedTo: petWindow,
            onChoiceSelected: onChoiceSelected
        )
        self.replyHandler = replyHandler
        self.streamingReplyHandler = streamingReplyHandler
        self.onErrorSignal = onErrorSignal
        self.onProactiveBubbleShown = onProactiveBubbleShown
    }

    // MARK: - Handler hot-swap (mirrors Stage / ChatShellView)

    /// 替换 atomic handler。允许 session 在 orchestrator wire 之前构造、
    /// wire 之后再绑定具体回复实现。
    public func setReplyHandler(_ handler: @escaping ReplyHandler) {
        self.replyHandler = handler
    }

    /// 替换 streaming handler。非 nil 时 `appendUserInputAndSend` 优先走
    /// streaming，否则走 atomic。
    public func setStreamingHandler(_ handler: StreamingReplyHandler?) {
        self.streamingReplyHandler = handler
    }

    // MARK: - Send pipeline

    /// 触发一轮对话：append 用户输入气泡 → append assistant 气泡 → 走
    /// streaming（如有）或 atomic 回复，把回答写入 assistant 气泡。
    ///
    /// 与 `StageInputView.sendCurrentMessage` 一致：空白字符串直接 return，
    /// 不创建任何气泡；stale stream 用 sendIdentifier 护栏丢弃。
    ///
    /// - Parameter message: 用户要发送的文本。会先 trim whitespace。
    public func appendUserInputAndSend(_ message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        // 1) 当前轮的 user bubble (右侧). 自动 clear 上一轮的两颗气泡.
        //    assistant bubble 留到第一个 token 到达才 append, 避免用户看到
        //    一颗空白 placeholder 气泡 (用户反馈 "发完后弹出了个空白的气泡
        //    加个有文字的气泡" 的根因)。
        chain.appendUserMessage(trimmed)

        latestSendIdentifier += 1
        let sendIdentifier = latestSendIdentifier
        isStreaming = true
        defer {
            // 仅当本次还是"最新的一次"时才把 isStreaming 复位 —— 否则别人
            // 已经把它复位过 / 抢占过了，保留对方的状态。
            if sendIdentifier == latestSendIdentifier {
                isStreaming = false
            }
        }

        if let streamHandler = streamingReplyHandler {
            var accumulated = ""
            var assistantAppended = false
            do {
                for try await delta in streamHandler(trimmed) {
                    guard !delta.isEmpty else { continue }
                    accumulated += delta
                    guard sendIdentifier == latestSendIdentifier else {
                        // 已经被更新的一轮覆盖，丢弃 stale 输出。
                        return
                    }
                    if !assistantAppended {
                        chain.appendAssistantReply(accumulated)
                        assistantAppended = true
                    } else {
                        // 新设计中 assistant 在索引 1 (user 在索引 0)。
                        chain.bubble(at: 1)?.setText(accumulated)
                    }
                }
            } catch {
                // S2: streaming 出错。之前完全 swallow 让用户看不到原因
                // (silent failure / "发完没反应")。现在把 error 翻译为 Markdown
                // 友好文案显示在 assistant 气泡里:
                //   - 若已有累积内容: 在尾部追加错误提示, 保留用户已读到的部分
                //   - 若一字未出: append 一颗只含错误提示的 assistant 气泡
                // stale stream 仍丢弃 (sendIdentifier 已变)。
                guard sendIdentifier == latestSendIdentifier else { return }
                let friendly = LLMErrorMessages.friendly(for: error)
                if assistantAppended {
                    let combined = accumulated + "\n\n" + friendly
                    chain.bubble(at: 1)?.setText(combined)
                } else {
                    chain.appendAssistantReply(friendly)
                    assistantAppended = true
                }
                // N3.3: 告知调用方有错误发生, 由其触发 pet 形象 .refuse 反应
                // (Orb 默认 no-op; 角色化形象可表现"摇头/流汗"等)。
                onErrorSignal?(error)
            }
            // Stream done: restart 8s 倒计时让用户读时间从内容齐全开始算
            // (而不是从第一个 token —— 长回复会把 8s 压缩成读 3s)。
            // 只在本轮仍是最新一轮时 restart，避免被新一轮 stale stream 重置。
            if assistantAppended, sendIdentifier == latestSendIdentifier {
                chain.restartDismissCountdown()
            }
        } else {
            let reply = await replyHandler(trimmed)
            guard sendIdentifier == latestSendIdentifier else { return }
            chain.appendAssistantReply(reply)
        }
    }

    /// 清空链。等价于 `chain.clear()`，但同时把 isStreaming 复位 —— 调用方
    /// 一行就能"打断会话 + 清屏 + 重置"。
    public func clear() {
        latestSendIdentifier += 1  // 让所有 in-flight stream 立刻变 stale
        isStreaming = false
        chain.clear()
    }

    /// 作废任何 in-flight stream：+1 send id 让正在跑的 stream 在下一次 yield 时
    /// 丢弃自己（防串写到刚注入的气泡），并复位 isStreaming。`latestSendIdentifier`
    /// 是 `private`，跨文件扩展（`BondedSession+Proactive`）访问不到 → 本体提供 `internal` helper。
    func invalidateInFlightStream() {
        latestSendIdentifier += 1
        isStreaming = false
    }

    // MARK: - Private state

    private var replyHandler: ReplyHandler
    private var streamingReplyHandler: StreamingReplyHandler?
    /// N3.3 — streaming 错误时通知 callback (chain 错误气泡 surface 之后调,
    /// 用来让 MinimalAppDelegate 触发 `dispatchSignature(.refuse)`)。
    private let onErrorSignal: ((Error) -> Void)?
    /// 反应路由 B#2 — 主动建议/碎碎念气泡冒出时通知 callback,让 MinimalAppDelegate
    /// 触发 `dispatchSignature(.greet)`(pet 对自己主动开口 perk-up 反应)。`internal` 供
    /// 跨文件扩展 `BondedSession+Proactive` 访问。
    let onProactiveBubbleShown: (() -> Void)?
    /// 单调递增的 send 编号。每次 `appendUserInputAndSend` 都 +1，stream
    /// 循环里比对当前值即可判定是否已被新一轮覆盖。`clear()` 也会 +1，
    /// 让所有 in-flight stream 在下一次 yield 时丢弃自己。
    private var latestSendIdentifier: Int = 0
}
