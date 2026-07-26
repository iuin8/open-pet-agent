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

    /// draft 以完整 `@trigger`(词边界:后续为空白或结尾)开头 → 命中的候选(composer
    /// 目标图标**预览**用)。词边界与 `AgentMention.parse` 一致("@codexfoo" 不算),
    /// 但**不要求 trigger 后有内容** —— 预览是「mention 识别成功」的即时反馈;
    /// 真路由仍按 parse 规则(无内容不触发,预览只是提示)。
    public static func resolvedTarget(in draft: String, options: [MentionOption]) -> MentionOption? {
        guard draft.hasPrefix("@") else { return nil }
        let rest = draft.dropFirst()
        let name = rest.prefix(while: \.isLetter).lowercased()
        guard !name.isEmpty,
              let option = options.first(where: { $0.trigger.lowercased() == name }) else { return nil }
        let after = rest.dropFirst(name.count)
        guard after.isEmpty || after.first?.isWhitespace == true else { return nil }
        return option
    }

    /// 补全接受:`@trigger `(带尾随空格,光标落在空格后可直接写正文)。
    public static func acceptedDraft(trigger: String) -> String {
        "@\(trigger) "
    }

    // MARK: - P6.1 一次性目标烘焙 / 历史 chip 解析

    /// 发送前烘焙:有选中目标且文本**不**已含完整行首 mention → 补 `@trigger ` 前缀
    /// (交给既有路由管线,落盘保真原文);已有完整 mention(打字党)或 nil trigger → 原样。
    public static func withMentionPrefix(_ text: String, trigger: String?, options: [MentionOption]) -> String {
        guard let trigger, !trigger.isEmpty else { return text }
        if resolvedTarget(in: text, options: options) != nil { return text }
        return "@\(trigger) \(text)"
    }

    /// 用户行渲染数据:文本以完整 `@trigger `(词边界)开头 → 返回该候选;否则 nil。
    /// 与 `resolvedTarget` 同规则但**要求 trigger 后有内容或正好结尾**(历史行总是完整消息)。
    public static func leadingMention(in text: String, options: [MentionOption]) -> MentionOption? {
        resolvedTarget(in: text, options: options)
    }

    /// 剥除行首 `@trigger ` 前缀后的展示正文(无 mention → 原文)。
    public static func strippingLeadingMention(_ text: String, options: [MentionOption]) -> String {
        guard leadingMention(in: text, options: options) != nil else { return text }
        let rest = text.dropFirst()
        let name = rest.prefix(while: \.isLetter)
        return String(rest.dropFirst(name.count).drop(while: \.isWhitespace))
    }

    /// 胶囊选中时清理 draft:剥掉已键入的 `@片段`(连同后续空白),留下已写正文。
    /// draft 不含行首 @ → 原样("@co" + 选 codex → "" + 目标,防"@co"残留进正文)。
    public static func strippingDraftMention(_ draft: String) -> String {
        guard draft.hasPrefix("@") else { return draft }
        let rest = draft.dropFirst()
        let name = rest.prefix(while: \.isLetter)
        return String(rest.dropFirst(name.count).drop(while: \.isWhitespace))
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
    /// 品牌 logo(优先于 `systemImage` 渲染;与 composer 目标图标同款)。
    public let brandLogo: BrandLogo?
    /// CLI 是否可用(不可用 → 置灰 +「未安装」;仍可选,发送后走友好不可用文案)。
    public let available: Bool
    /// 灵魂层伪目标(P6 `@pet`;补全弹层展示 + 图标预览用,不参与引擎池路由)。
    public let isSoul: Bool

    public var id: String { trigger }

    public init(trigger: String, label: String, systemImage: String, brandLogo: BrandLogo?, available: Bool, isSoul: Bool = false) {
        self.trigger = trigger
        self.label = label
        self.systemImage = systemImage
        self.brandLogo = brandLogo
        self.available = available
        self.isSoul = isSoul
    }
}

// MARK: - composer 目标图标状态机(P6 pin 模型)

/// composer 目标图标的有效目标(soul / pinned engine / @ 预览 engine)。
public enum ComposerTarget: Equatable, Sendable {
    /// 灵魂层(pet 人格聊天,默认)。
    case soul
    /// 引擎目标;pinned = true → 钉住态(实色 + pin badge),false → @ 输入中的预览态。
    case engine(MentionOption, pinned: Bool)
}

/// `ComposerTarget` 纯解析(可单测)。优先级:**打字完整 @ > 胶囊选中 > pinned > soul**
/// (打字党不被胶囊状态覆盖);胶囊 paw(isSoul)→ soul 一次性逃逸预览。
public enum ComposerTargetResolver {
    public static func resolve(
        draft: String,
        options: [MentionOption],
        pinnedTrigger: String?,
        selectedTrigger: String? = nil
    ) -> ComposerTarget {
        if let preview = MentionAutocomplete.resolvedTarget(in: draft, options: options) {
            if preview.isSoul { return .soul }
            return .engine(preview, pinned: preview.trigger == pinnedTrigger)
        }
        if let selectedTrigger,
           let selected = options.first(where: { $0.trigger == selectedTrigger }) {
            if selected.isSoul { return .soul }
            return .engine(selected, pinned: selected.trigger == pinnedTrigger)
        }
        if let pinnedTrigger,
           let pinned = options.first(where: { $0.trigger == pinnedTrigger && !$0.isSoul }) {
            return .engine(pinned, pinned: true)
        }
        return .soul
    }
}

public extension ComposerTarget {
    /// 是否 pinned 引擎态(实色 + pin badge)。
    var isPinnedEngine: Bool {
        if case .engine(_, pinned: true) = self { return true }
        return false
    }

    /// 图标 tooltip(当前状态 + 可执行动作)。
    var helpText: String {
        switch self {
        case .soul:
            return "当前:Pet 聊天 · 输入 @ 点名引擎"
        case .engine(let option, let pinned):
            return pinned
                ? "已钉住 @\(option.trigger)(点击取消,回到 Pet 聊天)"
                : "本条将由 @\(option.trigger) 回复(点击钉住,之后不用每条 @)"
        }
    }
}
