import Foundation
import Testing
@testable import Shell

// P5 follow-up:@mention 补全弹层纯逻辑单测 —— query 判定(行首 @ 字母前缀)、
// 前缀过滤(大小写不敏感)、接受补全 draft。picker 可见性 = 过滤结果非空(纯组合,不另测)。

@Suite("MentionAutocomplete 补全纯逻辑")
struct MentionAutocompleteTests {

    private let options = [
        MentionOption(trigger: "opencode", label: "opencode", systemImage: "terminal.fill", brandLogo: .opencode, available: true),
        MentionOption(trigger: "claude", label: "Claude", systemImage: "bolt.fill", brandLogo: .claude, available: true),
        MentionOption(trigger: "codex", label: "Codex", systemImage: "chevron.left.forwardslash.chevron.right", brandLogo: .codex, available: false),
    ]

    @Test("query: 行首 @ 后只有字母 → 返回前缀;其它形态一律 nil(不弹)")
    func queryRules() {
        #expect(MentionAutocomplete.query(in: "@") == "")
        #expect(MentionAutocomplete.query(in: "@co") == "co")
        #expect(MentionAutocomplete.query(in: "@CODEX") == "CODEX")
        #expect(MentionAutocomplete.query(in: "") == nil)
        #expect(MentionAutocomplete.query(in: "普通一句") == nil)
        #expect(MentionAutocomplete.query(in: "@codex 内容") == nil)   // 含空白 → mention 输入阶段结束
        #expect(MentionAutocomplete.query(in: "找 @codex") == nil)      // 行中 @
        #expect(MentionAutocomplete.query(in: "@co dex") == nil)
        #expect(MentionAutocomplete.query(in: "@c0") == nil)            // 非字母
    }

    @Test("filter: 前缀过滤大小写不敏感;空前缀全量;无匹配 → 空(弹层隐藏)")
    func filterRules() {
        #expect(MentionAutocomplete.filter(options, query: "").map(\.trigger) == ["opencode", "claude", "codex"])
        #expect(MentionAutocomplete.filter(options, query: "c").map(\.trigger) == ["claude", "codex"])
        #expect(MentionAutocomplete.filter(options, query: "co").map(\.trigger) == ["codex"])
        #expect(MentionAutocomplete.filter(options, query: "CO").map(\.trigger) == ["codex"])
        #expect(MentionAutocomplete.filter(options, query: "claude").map(\.trigger) == ["claude"])
        #expect(MentionAutocomplete.filter(options, query: "xyz").isEmpty)
    }

    @Test("acceptedDraft: '@trigger ' 带尾随空格(光标落空格后直接写正文)")
    func accepted() {
        #expect(MentionAutocomplete.acceptedDraft(trigger: "codex") == "@codex ")
    }
}

// MARK: - P6 resolvedTarget(完整 trigger 词边界判定)

@Suite("MentionAutocomplete resolvedTarget(P6)")
struct MentionAutocompleteResolvedTargetTests {

    private let options = [
        MentionOption(trigger: "pet", label: "Pet", systemImage: "pawprint.fill", brandLogo: nil, available: true, isSoul: true),
        MentionOption(trigger: "opencode", label: "opencode", systemImage: "terminal.fill", brandLogo: .opencode, available: true),
        MentionOption(trigger: "claude", label: "Claude", systemImage: "bolt.fill", brandLogo: .claude, available: true),
        MentionOption(trigger: "codex", label: "Codex", systemImage: "chevron.left.forwardslash.chevron.right", brandLogo: .codex, available: false),
    ]

    @Test("完整 trigger 即命中(无需空格/内容 —— 落 token 判定)")
    func completeTriggerResolves() {
        #expect(MentionAutocomplete.resolvedTarget(in: "@codex", options: options)?.trigger == "codex")
        #expect(MentionAutocomplete.resolvedTarget(in: "@codex ", options: options)?.trigger == "codex")
        #expect(MentionAutocomplete.resolvedTarget(in: "@codex 看日志", options: options)?.trigger == "codex")
        #expect(MentionAutocomplete.resolvedTarget(in: "@claude 写测试", options: options)?.trigger == "claude")
    }

    @Test("大小写不敏感;soul trigger 也命中")
    func caseAndSoul() {
        #expect(MentionAutocomplete.resolvedTarget(in: "@CODEX x", options: options)?.trigger == "codex")
        #expect(MentionAutocomplete.resolvedTarget(in: "@pet 聊聊", options: options)?.isSoul == true)
    }

    @Test("词边界:@codexfoo / 行中 @ / 未知词 / 半截词 → nil")
    func wordBoundary() {
        #expect(MentionAutocomplete.resolvedTarget(in: "@codexfoo 内容", options: options) == nil)
        #expect(MentionAutocomplete.resolvedTarget(in: "找 @codex", options: options) == nil)
        #expect(MentionAutocomplete.resolvedTarget(in: "@gemini 你好", options: options) == nil)
        #expect(MentionAutocomplete.resolvedTarget(in: "@co", options: options) == nil)
        #expect(MentionAutocomplete.resolvedTarget(in: "", options: options) == nil)
    }
}

// MARK: - P6.1 烘焙 / 历史 chip 解析 / draft 清理

@Suite("MentionAutocomplete P6.1 烘焙与解析")
struct MentionAutocompleteBakeTests {

    private let options = [
        MentionOption(trigger: "pet", label: "Pet", systemImage: "pawprint.fill", brandLogo: nil, available: true, isSoul: true),
        MentionOption(trigger: "opencode", label: "opencode", systemImage: "terminal.fill", brandLogo: .opencode, available: true),
        MentionOption(trigger: "claude", label: "Claude", systemImage: "bolt.fill", brandLogo: .claude, available: true),
        MentionOption(trigger: "codex", label: "Codex", systemImage: "chevron.left.forwardslash.chevron.right", brandLogo: .codex, available: true),
    ]

    @Test("withMentionPrefix:有选中且无行首 mention → 补前缀;nil trigger → 原样")
    func prefixBake() {
        #expect(MentionAutocomplete.withMentionPrefix("看日志", trigger: "codex", options: options) == "@codex 看日志")
        #expect(MentionAutocomplete.withMentionPrefix("看日志", trigger: nil, options: options) == "看日志")
    }

    @Test("withMentionPrefix:已含完整行首 mention(打字党)→ 不重复补")
    func prefixNoDouble() {
        #expect(MentionAutocomplete.withMentionPrefix("@claude 写测试", trigger: "codex", options: options) == "@claude 写测试")
    }

    @Test("leadingMention / strippingLeadingMention:chip 数据与展示正文(落盘原文不动)")
    func leadingParse() {
        #expect(MentionAutocomplete.leadingMention(in: "@codex 看日志", options: options)?.trigger == "codex")
        #expect(MentionAutocomplete.leadingMention(in: "@pet 聊聊", options: options)?.isSoul == true)
        #expect(MentionAutocomplete.leadingMention(in: "普通消息", options: options) == nil)
        #expect(MentionAutocomplete.strippingLeadingMention("@codex 看日志", options: options) == "看日志")
        #expect(MentionAutocomplete.strippingLeadingMention("普通消息", options: options) == "普通消息")
    }

    @Test("strippingDraftMention:剥掉已键入的 @ 片段,保留正文")
    func draftStrip() {
        #expect(MentionAutocomplete.strippingDraftMention("@co") == "")
        #expect(MentionAutocomplete.strippingDraftMention("@codex ") == "")
        #expect(MentionAutocomplete.strippingDraftMention("@codex 已写的正文") == "已写的正文")
        #expect(MentionAutocomplete.strippingDraftMention("没有@") == "没有@")
    }
}

// MARK: - P6.2 trayToken(tray 标签纯逻辑)

@Suite("MentionAutocomplete trayToken(P6.2)")
struct MentionTrayTokenTests {

    private let options = [
        MentionOption(trigger: "pet", label: "Pet", systemImage: "pawprint.fill", brandLogo: nil, available: true, isSoul: true),
        MentionOption(trigger: "opencode", label: "opencode", systemImage: "terminal.fill", brandLogo: .opencode, available: true),
        MentionOption(trigger: "codex", label: "Codex", systemImage: "chevron.left.forwardslash.chevron.right", brandLogo: .codex, available: true),
    ]

    @Test("无选中无 pinned → nil(composer 无 chrome)")
    func noneNil() {
        #expect(MentionAutocomplete.trayToken(selectedTrigger: nil, pinnedTrigger: nil, options: options) == nil)
    }

    @Test("选中一次性引擎 → token(未钉);选中 == pinned → 钉住态")
    func selectionToken() {
        let oneOff = MentionAutocomplete.trayToken(selectedTrigger: "codex", pinnedTrigger: nil, options: options)
        #expect(oneOff?.option.trigger == "codex")
        #expect(oneOff?.isPinned == false)

        let pinned = MentionAutocomplete.trayToken(selectedTrigger: "codex", pinnedTrigger: "codex", options: options)
        #expect(pinned?.isPinned == true)
    }

    @Test("仅 pinned → 钉住 token 常驻")
    func pinnedOnly() {
        let t = MentionAutocomplete.trayToken(selectedTrigger: nil, pinnedTrigger: "codex", options: options)
        #expect(t?.option.trigger == "codex")
        #expect(t?.isPinned == true)
    }

    @Test("选中 paw → soul token(一次性逃逸);选中查不到候选 → pinned 兜底")
    func pawAndFallback() {
        let paw = MentionAutocomplete.trayToken(selectedTrigger: "pet", pinnedTrigger: "codex", options: options)
        #expect(paw?.option.isSoul == true)
        #expect(paw?.isPinned == false)

        let fallback = MentionAutocomplete.trayToken(selectedTrigger: "gemini", pinnedTrigger: "codex", options: options)
        #expect(fallback?.option.trigger == "codex")
        #expect(fallback?.isPinned == true)
    }
}
