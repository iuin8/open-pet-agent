import Context

/// 主动建议生成器注入边界。`ProactiveSuggestionEngine` 只依赖此协议，
/// 生产用 `CompanionOrchestrator`（no-history `chat`）实现，测试注 mock。
public protocol ProactiveSuggestionGenerating: Sendable {
    /// 给定短 prompt + 当前桌面快照，返回一句主动建议文本（原子，非流式）。
    /// 失败抛错（引擎会静默跳过，不弹错误气泡）。
    func generate(prompt: String, snapshot: DesktopSnapshot?) async throws -> String
}
