import AppKit

extension BondedSession {
    /// 主动建议注入：**一颗暖染色富文本气泡**（pet 主动说的话），count==1 → 8s 倒计时正常。
    ///
    /// 与普通对话路径 `appendUserInputAndSend` 的区别：
    ///   - **不写 conversationStore / 不调 LLM**（主动建议文本已生成，不进对话历史）
    ///   - 单颗 `appendProactiveSuggestion`（暖染色 + accent 橙描边）而非伪造用户输入 + 双气泡
    ///   - 接 `chain.onAutoDismissed` → onDismiss（供主动引擎判 ignore-decay）
    ///
    /// - Parameters:
    ///   - context: 触发原因标签（`TriggerKind.displayName`，如「深夜」「专注中」）。
    ///     本版不渲染，保留供下版 chip 用。
    ///   - reply: LLM 生成的主动建议文本
    ///   - onDismiss: 气泡超时自然消失时回调（参数：是否曾被 hover）
    public func injectProactiveSuggestion(
        context: String,
        reply: String,
        onDismiss: @escaping (Bool) -> Void
    ) {
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else { return }

        // 作废任何 in-flight stream，防串写到刚注入的气泡。
        invalidateInFlightStream()

        // 顺序要紧：先设 onAutoDismissed，再 appendProactiveSuggestion ——
        // append 内部先 clear 掉上一轮旧 timer 再起新 8s timer，归零时 fire 回调。
        chain.onAutoDismissed = { hovered in onDismiss(hovered) }
        chain.appendProactiveSuggestion(context: context, text: trimmedReply)
        // 反应路由 B#2:pet 主动开口 → perk-up 反应(App 注入 → dispatchSignature(.greet),
        // 不支持的形象自动 no-op)。
        onProactiveBubbleShown?()
    }
}
