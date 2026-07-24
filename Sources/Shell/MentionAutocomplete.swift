import Foundation

/// P5 follow-up:@mention 补全弹层的纯逻辑(可单测)。composer 的 draft 变化时:
/// `query(in:)` 判定是否处于「行首 mention 输入中」并取出已键入的触发前缀;
/// `filter(_:query:)` 按前缀过滤候选;`acceptedDraft(_:trigger:)` 产出补全后的 draft。
///
/// 判定规则与 `AgentMention.parse`(AgentMode)的行首语义对齐:
/// - draft 必须以 `@` 开头;
/// - `@` 后只有字母(出现空白/其它字符 = mention 已结束或不是 mention → 不弹);
/// - 整条 draft 都只是 mention 前缀(补全发生在输入 mention 名的阶段)。
public enum MentionAutocomplete {

    /// draft 是否处于行首 mention 输入中;是 → 返回 `@` 后已键入的字母前缀(可能为空串)。
    public static func query(in draft: String) -> String? {
        guard draft.hasPrefix("@") else { return nil }
        let rest = draft.dropFirst()
        guard rest.allSatisfy(\.isLetter) else { return nil }
        return String(rest)
    }

    /// 按触发名前缀过滤(大小写不敏感)。query 为空串 → 全量候选。
    public static func filter(_ options: [MentionOption], query: String) -> [MentionOption] {
        let lower = query.lowercased()
        return options.filter { $0.trigger.hasPrefix(lower) }
    }

    /// 补全接受:`@trigger `(带尾随空格,光标落在空格后可直接写正文)。
    public static func acceptedDraft(trigger: String) -> String {
        "@\(trigger) "
    }
}

/// 补全弹层一行候选。App 从 `AgentMention.candidates` × registry 展示名/logo × CLI
/// 可用性派生注入(Shell 不依赖 AgentMode,纯展示数据)。
public struct MentionOption: Equatable, Sendable, Identifiable {
    /// mention 触发词(小写,如 "codex")。
    public let trigger: String
    /// 展示名(如 "Codex")。
    public let label: String
    /// SF Symbol(无品牌 logo 时 fallback)。
    public let systemImage: String
    /// 品牌 logo(优先于 `systemImage` 渲染;同 `ReplyOption.brandLogo`)。
    public let brandLogo: BrandLogo?
    /// CLI 是否可用(不可用 → 置灰 +「未安装」;仍可选,发送后走友好不可用文案)。
    public let available: Bool

    public var id: String { trigger }

    public init(trigger: String, label: String, systemImage: String, brandLogo: BrandLogo?, available: Bool) {
        self.trigger = trigger
        self.label = label
        self.systemImage = systemImage
        self.brandLogo = brandLogo
        self.available = available
    }
}
