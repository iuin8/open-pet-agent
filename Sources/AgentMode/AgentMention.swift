import Foundation

/// P5 @mention 路由解析;P6 升**三态**:消息**行首**的 `@opencode` / `@claude` / `@codex`
/// (大小写不敏感)→ `.engine(kind)`;`@pet` / `@聊天` / `@宠物` → `.soul`
/// (强制本条灵魂层 —— 钉住引擎时的单条逃逸口);无 mention → `target == nil`。
///
/// 契约:
/// - `ConversationStore` 记**用户原文**(带 @,时间线可见);engine / LLM 收到的是剥离
///   mention 后的 `prompt`。
/// - mention 必须是消息开头(允许前导空白)且后面有实际内容;`"@codex"` 单独成句 /
///   行中 `@`(如 "找 @小明")不触发,原文直发。
/// - v1 引擎只认三个全名,无别名(避免别名漂移;要加往 `engineCandidates` 加一行)。
public enum AgentMention {

    /// mention 路由目标。
    public enum Target: Sendable, Equatable {
        /// 路由到对应 agent engine(引擎池,各自私有 session)。
        case engine(AgentEngineKind)
        /// 强制本条走灵魂层(pet 人格聊天)—— 钉住引擎时的单条逃逸口(P6)。
        case soul
    }

    /// 解析结果:`target` = mention 目标(nil = 无 mention);`prompt` = 剥离 mention 后
    /// 的实际内容(无 mention 时 = 原文)。
    public struct Result: Sendable, Equatable {
        public let target: Target?
        public let prompt: String

        public init(target: Target?, prompt: String) {
            self.target = target
            self.prompt = prompt
        }
    }

    /// 引擎 mention 候选(与解析同一份表,防漂移):(trigger 小写, kind)。顺序即补全弹层展示序。
    public static let engineCandidates: [(trigger: String, kind: AgentEngineKind)] = [
        (trigger: "opencode", kind: .openCode),
        (trigger: "claude", kind: .claudeCode),
        (trigger: "codex", kind: .codex),
    ]

    /// 灵魂层 mention 触发词(P6;伪目标,不进引擎候选)。
    public static let soulTriggers: Set<String> = ["pet", "聊天", "宠物"]
    /// 灵魂层规范触发词(补全弹层 / 图标预览展示用;其余别名只解析不展示)。
    public static let soulCanonicalTrigger = "pet"

    /// 引擎 mention 名(小写)→ kind(由 `engineCandidates` 派生)。
    private static let engineTable: [String: AgentEngineKind] = Dictionary(
        uniqueKeysWithValues: engineCandidates.map { ($0.trigger, $0.kind) }
    )

    public static func parse(_ text: String) -> Result {
        let head = text.drop(while: \.isWhitespace)
        guard head.first == "@" else { return Result(target: nil, prompt: text) }
        let afterAt = head.dropFirst()
        let name = afterAt.prefix(while: \.isLetter)
        let lowered = name.lowercased()
        let target: Target?
        if let kind = engineTable[lowered] {
            target = .engine(kind)
        } else if soulTriggers.contains(lowered) {
            target = .soul
        } else {
            target = nil
        }
        guard let target else { return Result(target: nil, prompt: text) }
        // "@codex" 单独成句(没实际内容)→ 不当 mention,原文直发(防误吞消息)。
        let prompt = afterAt.dropFirst(name.count).drop(while: \.isWhitespace)
        guard !prompt.isEmpty else { return Result(target: nil, prompt: text) }
        return Result(target: target, prompt: String(prompt))
    }
}
