import Foundation

/// P5 @mention 路由解析:消息**行首**的 `@opencode` / `@claude` / `@codex`
/// (大小写不敏感)→ 路由到对应 engine;无 mention → `kind == nil`(走当前默认 engine)。
///
/// 契约:
/// - `ConversationStore` 记**用户原文**(带 @,时间线可见);engine 收到的是剥离
///   mention 后的 `prompt`。
/// - mention 必须是消息开头(允许前导空白)且后面有实际内容;`"@codex"` 单独成句 /
///   行中 `@`(如 "找 @小明")不触发,原文直发默认 engine。
/// - v1 只认三个全名,无别名(避免别名漂移;要加往 `table` 加一行)。
public enum AgentMention {

    /// mention 候选(与解析同一份表,防漂移):(trigger 小写, kind)。顺序即补全弹层展示序。
    /// v1 只三个全名,无别名(要加往这里加一行,解析与 UI 同时生效)。
    public static let candidates: [(trigger: String, kind: AgentEngineKind)] = [
        (trigger: "opencode", kind: .openCode),
        (trigger: "claude", kind: .claudeCode),
        (trigger: "codex", kind: .codex),
    ]

    /// mention 名(小写)→ engine kind(由 `candidates` 派生)。
    private static let table: [String: AgentEngineKind] = Dictionary(
        uniqueKeysWithValues: candidates.map { ($0.trigger, $0.kind) }
    )

    /// 解析结果。`kind` = mention 目标(nil = 无 mention);`prompt` = 剥离 mention 后
    /// 的实际内容(无 mention 时 = 原文)。
    public static func parse(_ text: String) -> (kind: AgentEngineKind?, prompt: String) {
        let head = text.drop(while: \.isWhitespace)
        guard head.first == "@" else { return (nil, text) }
        let afterAt = head.dropFirst()
        let name = afterAt.prefix(while: \.isLetter)
        guard let kind = table[name.lowercased()] else { return (nil, text) }
        // "@codex" 单独成句(没实际内容)→ 不当 mention,原文直发(防误吞消息)。
        let prompt = afterAt.dropFirst(name.count).drop(while: \.isWhitespace)
        guard !prompt.isEmpty else { return (nil, text) }
        return (kind, String(prompt))
    }
}
