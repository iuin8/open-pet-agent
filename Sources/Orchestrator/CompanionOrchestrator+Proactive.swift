import Context
import Foundation

extension CompanionOrchestrator {
    /// 主动建议专用 no-history 入口（**流式累积**为一句完整文本）。
    ///
    /// 与 `replyStream` / `replyStreamOneShot` 的本质区别：
    ///   - **不读 conversationStore**（无历史）
    ///   - **不调 liveContextBox.observe**（不侧写 lastNonSelfApplicationName，
    ///     不污染用户主动 chat 的「最近活跃应用」记忆）
    ///   - **不发 ChatBehaviorStateMachine 事件**、**不走 toolMode**
    ///   - **不复用 chat 的 `buildSystemPrompt`**：那是助手 persona + 大段桌面上下文，
    ///     正是让模型把字数/格式要求当任务、用英文复述出来的根源（见 Image #9 反馈 +
    ///     docs/lessons-learned.md）。改用 `ProactivePromptComposer` 的专用 pet persona
    ///     system prompt + few-shot 示例「示范」格式（借鉴 AccountyCat），user 只给场景。
    ///   - `snapshot` 参数保留以满足 `ProactiveSuggestionGenerating` 协议，但场景里已含
    ///     app 名（composer 用 signal 组好），故本路径不再二次注入桌面上下文。
    ///
    /// **走 `streamChat` 而非 `chat`**：很多 OpenAI 兼容网关（含本地代理）只接受
    /// `stream:true` 的请求，非流式 `chat` 会直接挂（连接无响应）。全 app 其它聊天
    /// 路径都走 streamChat，主动建议对齐——把增量累积成一句完整文本再返回（气泡一次性
    /// 显示，无需逐字）。hang 由 URLSession 请求超时（默认 60s）兜底 → 抛错 → 引擎静默跳过。
    ///
    /// 失败抛错（引擎静默跳过，不弹错误气泡——不给用户没要的东西弹错误）。
    public func proactiveSuggestion(
        for prompt: String,
        snapshot: DesktopSnapshot?
    ) async throws -> String {
        guard let provider = await llmProviderBox.current else {
            throw LLMProviderError.missingAPIKey
        }
        // 三段式：专用 persona system → few-shot（场景→pet 一句话）示范格式 → 真实场景。
        var messages: [LLMMessage] = [
            LLMMessage(role: .system, content: ProactivePromptComposer.systemPrompt)
        ]
        for example in ProactivePromptComposer.fewShotExamples {
            messages.append(LLMMessage(role: .user, content: example.scene))
            messages.append(LLMMessage(role: .assistant, content: example.line))
        }
        messages.append(LLMMessage(role: .user, content: prompt))
        var accumulated = ""
        for try await delta in provider.streamChat(messages) {
            accumulated += delta
        }
        guard !accumulated.isEmpty else { throw LLMProviderError.emptyResponse }
        return accumulated
    }
}

/// `CompanionOrchestrator` 作为主动建议生成器：调上面的 no-history 入口。
extension CompanionOrchestrator: ProactiveSuggestionGenerating {
    public func generate(prompt: String, snapshot: DesktopSnapshot?) async throws -> String {
        try await proactiveSuggestion(for: prompt, snapshot: snapshot)
    }
}
