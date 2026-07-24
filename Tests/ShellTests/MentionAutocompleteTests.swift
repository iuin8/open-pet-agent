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
