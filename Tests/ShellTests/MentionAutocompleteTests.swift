import Foundation
import Testing
@testable import Shell

// P5 follow-up:@mention 补全弹层纯逻辑单测 —— query 判定(行首 @ 字母前缀)、
// 前缀过滤(大小写不敏感)、接受补全 draft。弹层可见性 = 过滤结果非空(纯组合,不另测)。

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


// MARK: - P6 resolvedTarget(composer 图标预览)

@Suite("MentionAutocomplete resolvedTarget(P6)")
struct MentionAutocompleteResolvedTargetTests {

    private let options = [
        MentionOption(trigger: "pet", label: "Pet", systemImage: "pawprint.fill", brandLogo: nil, available: true, isSoul: true),
        MentionOption(trigger: "opencode", label: "opencode", systemImage: "terminal.fill", brandLogo: .opencode, available: true),
        MentionOption(trigger: "claude", label: "Claude", systemImage: "bolt.fill", brandLogo: .claude, available: true),
        MentionOption(trigger: "codex", label: "Codex", systemImage: "chevron.left.forwardslash.chevron.right", brandLogo: .codex, available: false),
    ]

    @Test("完整 trigger 即命中(无需空格/内容 —— 预览是「识别成功」反馈)")
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

// MARK: - P6 ComposerTargetResolver(pin 模型状态机)

@Suite("ComposerTargetResolver(P6 pin 模型)")
struct ComposerTargetResolverTests {

    private let options = [
        MentionOption(trigger: "pet", label: "Pet", systemImage: "pawprint.fill", brandLogo: nil, available: true, isSoul: true),
        MentionOption(trigger: "opencode", label: "opencode", systemImage: "terminal.fill", brandLogo: .opencode, available: true),
        MentionOption(trigger: "codex", label: "Codex", systemImage: "chevron.left.forwardslash.chevron.right", brandLogo: .codex, available: true),
    ]

    @Test("无 mention + 未钉 → soul")
    func defaultSoul() {
        #expect(ComposerTargetResolver.resolve(draft: "", options: options, pinnedTrigger: nil) == .soul)
        #expect(ComposerTargetResolver.resolve(draft: "普通一句", options: options, pinnedTrigger: nil) == .soul)
    }

    @Test("无 mention + 已钉 codex → pinned engine")
    func pinnedEngine() {
        let t = ComposerTargetResolver.resolve(draft: "干活", options: options, pinnedTrigger: "codex")
        #expect(t == .engine(options[2], pinned: true))
        #expect(t.isPinnedEngine)
    }

    @Test("draft 含完整 mention → 预览态优先(哪怕 pin 了别的引擎)")
    func previewWins() {
        // pin 的 codex,但 draft 是 @opencode → 预览 opencode(未钉)
        let t = ComposerTargetResolver.resolve(draft: "@opencode 看一眼", options: options, pinnedTrigger: "codex")
        #expect(t == .engine(options[1], pinned: false))
        #expect(!t.isPinnedEngine)
    }

    @Test("mention 与 pin 同引擎 → pinned 预览(图标保持钉住态)")
    func previewSameAsPinned() {
        let t = ComposerTargetResolver.resolve(draft: "@codex 继续", options: options, pinnedTrigger: "codex")
        #expect(t == .engine(options[2], pinned: true))
    }

    @Test("@pet 预览 → soul(钉住时的逃逸预览)")
    func soulPreview() {
        #expect(ComposerTargetResolver.resolve(draft: "@pet 聊聊", options: options, pinnedTrigger: "codex") == .soul)
    }

    @Test("pinned trigger 不在候选里(数据不同步)→ 回 soul 兜底")
    func pinnedMissingFallback() {
        #expect(ComposerTargetResolver.resolve(draft: "", options: options, pinnedTrigger: "gemini") == .soul)
    }

    @Test("helpText / isPinnedEngine 语义")
    func helpAndFlags() {
        let pinned = ComposerTarget.engine(options[2], pinned: true)
        let preview = ComposerTarget.engine(options[1], pinned: false)
        #expect(pinned.isPinnedEngine)
        #expect(!preview.isPinnedEngine)
        #expect(pinned.helpText.contains("取消"))
        #expect(preview.helpText.contains("钉住"))
        #expect(ComposerTarget.soul.helpText.contains("@"))
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

// MARK: - P6.1 ComposerTargetResolver 胶囊选中优先级

@Suite("ComposerTargetResolver P6.1 胶囊选中")
struct ComposerTargetResolverSelectionTests {

    private let options = [
        MentionOption(trigger: "pet", label: "Pet", systemImage: "pawprint.fill", brandLogo: nil, available: true, isSoul: true),
        MentionOption(trigger: "opencode", label: "opencode", systemImage: "terminal.fill", brandLogo: .opencode, available: true),
        MentionOption(trigger: "codex", label: "Codex", systemImage: "chevron.left.forwardslash.chevron.right", brandLogo: .codex, available: true),
    ]

    @Test("胶囊选中(未打字)→ 一次性引擎目标(未钉)")
    func capsuleSelection() {
        let t = ComposerTargetResolver.resolve(draft: "干活", options: options, pinnedTrigger: nil, selectedTrigger: "codex")
        #expect(t == .engine(options[2], pinned: false))
        #expect(!t.isPinnedEngine)
    }

    @Test("打字完整 @ > 胶囊选中(打字党优先,不被胶囊状态覆盖)")
    func typedBeatsSelection() {
        let t = ComposerTargetResolver.resolve(draft: "@opencode 看", options: options, pinnedTrigger: nil, selectedTrigger: "codex")
        #expect(t == .engine(options[1], pinned: false))
    }

    @Test("胶囊选中 > pinned;选中 paw → soul 一次性逃逸")
    func selectionBeatsPinnedAndPawEscape() {
        let t = ComposerTargetResolver.resolve(draft: "干活", options: options, pinnedTrigger: "codex", selectedTrigger: "opencode")
        #expect(t == .engine(options[1], pinned: false))
        #expect(ComposerTargetResolver.resolve(draft: "聊聊", options: options, pinnedTrigger: "codex", selectedTrigger: "pet") == .soul)
    }

    @Test("选中 trigger 不在候选里 → 继续往下判(pinned/soul 兜底)")
    func selectionMissingFallback() {
        #expect(ComposerTargetResolver.resolve(draft: "", options: options, pinnedTrigger: "codex", selectedTrigger: "gemini") == .engine(options[2], pinned: true))
    }
}
