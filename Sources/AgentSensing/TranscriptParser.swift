import Foundation

/// 把一行 transcript jsonl 解析成 **0..N 个** `AgentEvent` 的统一接口 —— Claude 与 Codex 各一实现,
/// 让 `AgentSensingService` 不关心是哪种 agent,只管喂行、收事件。
///
/// **为何返数组**(P0-2,2026-06-17):一条 Claude `assistant` 消息的 `content` 可同时含
/// `text`(叙述「让我跑下测试」)+ `tool_use`(真去跑)。旧 `first(where:)` 一行只产一个事件 →
/// narration text 被工具吞掉(实测 75 处轮次时间线看不到中间叙述)。现遍历所有块、各产一个事件,
/// 按文档顺序返回(思考 → 叙述 → 工具)。Codex 一行一事件 → 返 0 或 1。空行/噪声 → 空数组。
///
/// `fallbackSessionId` / `fallbackCwd` 由 service 从**文件**推得(Codex 多数行不带 sessionId,
/// 靠文件名 uuid 兜底;Claude 行自带 sessionId,但缺失时也用兜底)。
public protocol TranscriptParser: Sendable {
    var agent: AgentKind { get }
    func parse(line: String, fallbackSessionId: String, fallbackCwd: String?) -> [AgentEvent]
}
