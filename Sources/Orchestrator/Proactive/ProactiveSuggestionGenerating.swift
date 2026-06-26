import Context

/// 主动建议生成器注入边界。`ProactiveSuggestionEngine` 只依赖此协议，
/// 生产用 `CompanionOrchestrator`（no-history `chat`）实现，测试注 mock。
public protocol ProactiveSuggestionGenerating: Sendable {
    /// 给定 system prompt（含 pet persona + 可选用户 persona）+ 短 user prompt（场景）+ 当前桌面
    /// 快照，返回一句主动建议文本（原子，非流式）。`systemPrompt` 由引擎用 `ProactivePromptComposer`
    /// 按当前 settings.personaText 组好传入。失败抛错（引擎会静默跳过，不弹错误气泡）。
    func generate(systemPrompt: String, prompt: String, snapshot: DesktopSnapshot?) async throws -> String
}
