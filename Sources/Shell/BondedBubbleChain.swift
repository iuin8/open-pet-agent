import AppKit

/// 管理 Bonded 陪伴模式下**一轮对话**的两颗 `BondedBubble`（详见
/// `docs/chat-input-redesign.md` §2.2）。
///
/// **A.5.3 phase 3 v2 设计**（用户拍板 — 同列垂直堆叠）：
///   - 每轮只有 user 气泡 + assistant 气泡，**同一列垂直堆叠在 pet 头顶**。
///   - user 紧贴 pet 头顶（offsetY = 0），assistant 在 user 上方
///     （offsetY = userPanelHeight + gap）。
///   - 只用 tail 朝向区分语义：user tail 偏右 (0.80) / assistant tail 偏左
///     (0.20)，详见 `BondedBubble.userTailPercent` / `assistantTailPercent`。
///   - `appendUserMessage` 自动 clear 上一轮，开启新一轮。
///   - **8 秒自动消失 + cursor hover 暂停**：assistant 一旦出现就启动
///     8s 倒计时；cursor 在任一气泡 panel 内时暂停（用户拍板"hover 不消失"），
///     离开继续倒数。倒数归零整轮 clear。
///   - 索引 0 = user，索引 1 = assistant。
///
/// 旧 `appendUserInput` API 保留作为 `appendUserMessage` 的别名。
@MainActor
public final class BondedBubbleChain {

    // MARK: - Layout constants

    /// 链长上限。一轮 user + assistant = 2 颗。
    public static let maxBubbles: Int = 2

    /// 上下气泡间的垂直 gap（pt）。assistant.panel.minY = user.panel.maxY + gap。
    static let bubbleVerticalGap: CGFloat = 4

    /// 自动消失倒计时（秒）。assistant 出现后开始数。
    public static let autoDismissSeconds: TimeInterval = 8.0

    /// hover-pause / 倒计时检查的 tick 频率（秒）。0.25s 是 cursor 跟踪与
    /// 续命响应感的折中。
    private static let dismissTickInterval: TimeInterval = 0.25

    // MARK: - Stored

    private weak var parentWindow: NSWindow?

    /// 当前轮的气泡 (顺序: 索引 0 = user `BondedBubble`, 索引 1 = assistant
    /// `BondedMarkdownBubble`)。两种类型都 conform `BondedBubblePresenting`,
    /// chain 内部统一以 protocol 类型存放。
    private var currentRound: [any BondedBubblePresenting] = []

    /// 倒计时剩余秒数（None 表示未启动 / 已停）。
    private var dismissRemaining: TimeInterval?
    /// 周期性 tick timer（0.25s 步长，检查 hover + 递减剩余时间）。
    private var dismissTimer: Timer?

    /// 用户点击 assistant 富文本气泡 ChoiceCard 时的 callback。BondedSession 在
    /// init 时注入(通常 wire 到当前 input field 的"填入但不发送"路径)。
    private let onChoiceSelected: ((String) -> Void)?

    /// 主动建议气泡因「8s 倒计时自然归零」消失时 fire（参数：消失时是否曾被 hover）。
    /// **仅**超时归零路径触发——用户主动 `clear()` / 新一轮 `appendUserMessage` 触发的
    /// clear **不** fire。主动引擎据此判 ignore-decay（超时未互动 = 被忽略）。
    public var onAutoDismissed: ((_ wasHovered: Bool) -> Void)?

    /// 当前轮是否曾被 hover 暂停过（dismissTick 命中 hover 时置 true）。
    private var roundWasHovered = false

    // MARK: - Init

    public init(
        attachedTo parent: NSWindow,
        onChoiceSelected: ((String) -> Void)? = nil
    ) {
        self.parentWindow = parent
        self.onChoiceSelected = onChoiceSelected
    }

    deinit {
        dismissTimer?.invalidate()
    }

    // MARK: - Public API

    /// 当前轮中气泡数 (0 / 1 / 2)。
    public var bubbleCount: Int { currentRound.count }

    /// 测试访问器。索引 0 = user(BondedBubble), 索引 1 = assistant(BondedMarkdownBubble)。
    /// 返回 protocol 类型,统一 user / assistant 两种实现。
    public func bubble(at index: Int) -> (any BondedBubblePresenting)? {
        guard currentRound.indices.contains(index) else { return nil }
        return currentRound[index]
    }

    /// 当前是否正在倒计时（测试访问器）。
    public var isDismissCountdownActive: Bool { dismissTimer != nil }

    /// 当前倒计时剩余秒数（测试访问器，未启动时 nil）。
    public var dismissRemainingForTest: TimeInterval? { dismissRemaining }

    /// 追加一颗用户消息气泡（新一轮的开始）。
    /// 自动 clear 上一轮的两颗气泡 + 取消上一轮的倒计时。
    /// 新设计中 user 气泡也参与自动消失 → assistant 一出现就启动 8s 倒计时
    /// 一起消（用户最新拍板"用户气泡参与自动消失"）。
    public func appendUserMessage(_ text: String) {
        guard let parent = parentWindow else { return }
        clear()
        roundWasHovered = false
        let bubble = BondedBubble(kind: .userMessage, text: text, attachedTo: parent)
        currentRound.append(bubble)
        bubble.repositionRelativeTo(parent, offsetY: 0)
        bubble.show()
    }

    /// 旧 API 别名：调用 `appendUserMessage` 走新逻辑。
    public func appendUserInput(_ text: String) {
        appendUserMessage(text)
    }

    /// 主动建议专用：追加**一颗**暖染色富文本气泡（pet 主动说的话）作为新一轮唯一气泡。
    /// 与 `appendUserMessage` 的区别是**暖染色 + accent 橙描边**（`isProactive: true`），
    /// 让用户一眼分辨「这是 pet 主动说的」而非「我问的」。单颗即贴 pet 头顶（offsetY = 0）。
    /// append 后直接启动 8s 自动消失倒计时（hover-pause），归零走 `clear()` + fire `onAutoDismissed`。
    ///
    /// - Parameters:
    ///   - context: 触发原因标签（如「深夜」「专注中」）。本版**不渲染**，保留供下版 chip 用。
    ///   - text: 主动建议正文（短句，1-2 行）。
    public func appendProactiveSuggestion(context: String, text: String) {
        guard let parent = parentWindow else { return }
        _ = context  // 本版不渲染触发原因，保留参数供下版 chip+设置项使用。
        clear()
        roundWasHovered = false
        let bubble = BondedMarkdownBubble(
            text: text,
            attachedTo: parent,
            onChoiceSelected: onChoiceSelected,
            isProactive: true
        )
        currentRound.append(bubble)
        bubble.repositionRelativeTo(parent, offsetY: 0)
        bubble.show()
        // 自适应修正：init 时 hostingView 还没进视图层级，多行 wrap 文本的
        // fittingSize 算不准（高度偏小 → 文字截断）。show() 后 hostingView 已挂上，
        // 再 setText 一次触发 resizePanelToContent 用准确 fittingSize 重算 panel 尺寸。
        // 与 streaming 助手气泡靠反复 setText 收敛尺寸同理。
        bubble.setText(text)
        // 单颗也启 8s 倒计时；dismissTick 超时归零对 count==1 同样工作。
        startDismissCountdown()
    }

    /// 追加一颗助手回答气泡（当前轮的第二颗，叠在 user 气泡上方）。
    /// 创建 `BondedMarkdownBubble`(SwiftUI 富文本) — 跟 user 的 `BondedBubble`
    /// (单行 label) 通过 `BondedBubblePresenting` protocol 统一。
    /// 同时启动 8s 自动消失倒计时（hover-pause）。
    public func appendAssistantReply(_ text: String) {
        guard let parent = parentWindow else { return }
        // 防御：若当前轮已有 2 颗，把旧 assistant 拆掉再追加新的。streaming
        // 正常路径只调一次 appendAssistantReply + 多次 setText。
        while currentRound.count >= 2 {
            let stale = currentRound.removeLast()
            stale.hide()
            stale.panel.parent?.removeChildWindow(stale.panel)
            stale.panel.orderOut(nil)
        }
        let userOffset = currentRound.first?.panel.frame.height ?? 0
        let bubble = BondedMarkdownBubble(
            text: text,
            attachedTo: parent,
            onChoiceSelected: onChoiceSelected
        )
        currentRound.append(bubble)
        bubble.repositionRelativeTo(parent, offsetY: userOffset + Self.bubbleVerticalGap)
        bubble.show()
        startDismissCountdown()
    }

    /// 重置自动消失倒计时（从 8s 重新数）。streaming 完成时由 `BondedSession`
    /// 调一次 —— 否则 8s 从 stream 第一个 token 开始数，长回复用户实际读到的
    /// 时间被压缩。需要 chain 当前还有 assistant 气泡才生效。
    public func restartDismissCountdown() {
        guard currentRound.count >= 2 else { return }
        startDismissCountdown()
    }

    /// 清空当前轮：两颗气泡淡出 + 从 child window 摘除 + 取消倒计时。
    public func clear() {
        cancelDismissCountdown()
        roundWasHovered = false  // 防御：清屏即归零 hover 状态，新一轮绝不携带上轮残留。
        for bubble in currentRound {
            bubble.hide()
            bubble.panel.parent?.removeChildWindow(bubble.panel)
            bubble.panel.orderOut(nil)
        }
        currentRound.removeAll()
    }

    // MARK: - Auto dismiss + hover pause

    private func startDismissCountdown() {
        cancelDismissCountdown()
        dismissRemaining = Self.autoDismissSeconds
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.dismissTickInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissTick()
            }
        }
        // common modes 让 timer 在 tracking / modal 期间也跑。
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    private func cancelDismissCountdown() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissRemaining = nil
    }

    private func dismissTick() {
        // cursor 在任一气泡 panel 内 → 暂停（不递减），等用户读完移开。
        if cursorIsInsideAnyBubble() {
            roundWasHovered = true
            return
        }
        guard var remaining = dismissRemaining else {
            cancelDismissCountdown()
            return
        }
        remaining -= Self.dismissTickInterval
        if remaining <= 0 {
            // 超时归零自然消失 → 通知订阅者（主动引擎据此判 ignore-decay）。
            // 用户主动 clear() / 新一轮 append 触发的 clear 不走这里，故不会误判忽略。
            let hovered = roundWasHovered
            onAutoDismissed?(hovered)
            clear()
            return
        }
        dismissRemaining = remaining
    }

    /// cursor 是否在任一当前气泡 panel 内（screen 坐标比对）。
    private func cursorIsInsideAnyBubble() -> Bool {
        let cursor = NSEvent.mouseLocation
        for bubble in currentRound where bubble.panel.isVisible {
            if bubble.panel.frame.contains(cursor) { return true }
        }
        return false
    }
}
