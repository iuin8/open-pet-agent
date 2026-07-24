import Testing
@testable import AgentMode

// P5 AgentMention 解析单测:行首 @opencode/@claude/@codex(大小写不敏感)→ kind + 剥离
// prompt;无 mention / 行中 @ / 只有 mention 没内容 / 未知名 → kind nil 原文直发。

@Suite("AgentMention 解析")
struct AgentMentionTests {

    @Test("行首 @codex + 内容 → kind codex,prompt 剥离 mention")
    func codexMention() {
        let r = AgentMention.parse("@codex 帮我看下这个 crash")
        #expect(r.kind == .codex)
        #expect(r.prompt == "帮我看下这个 crash")
    }

    @Test("@claude → claudeCode;@opencode → openCode")
    func knownNames() {
        #expect(AgentMention.parse("@claude 写个测试").kind == .claudeCode)
        #expect(AgentMention.parse("@opencode 跑一下构建").kind == .openCode)
    }

    @Test("大小写不敏感:@CODEX / @Claude 都命中")
    func caseInsensitive() {
        #expect(AgentMention.parse("@CODEX hi").kind == .codex)
        #expect(AgentMention.parse("@Claude hi").kind == .claudeCode)
    }

    @Test("无 mention → kind nil,prompt = 原文")
    func noMention() {
        let r = AgentMention.parse("普通一句话")
        #expect(r.kind == nil)
        #expect(r.prompt == "普通一句话")
    }

    @Test("行中 @(找人/邮箱)不触发")
    func midSentenceAtIgnored() {
        let r = AgentMention.parse("帮我找 @codex 的讨论记录")
        #expect(r.kind == nil)
        #expect(r.prompt == "帮我找 @codex 的讨论记录")
    }

    @Test("只有 mention 没内容 → 不触发(原文直发,防误吞消息)")
    func mentionOnlyIgnored() {
        let r = AgentMention.parse("@codex")
        #expect(r.kind == nil)
        #expect(r.prompt == "@codex")
    }

    @Test("未知 mention 名 → 不触发")
    func unknownNameIgnored() {
        let r = AgentMention.parse("@gemini 你好")
        #expect(r.kind == nil)
        #expect(r.prompt == "@gemini 你好")
    }

    @Test("前导空白后行首 mention 仍命中;prompt 前导空白剥净")
    func leadingWhitespace() {
        let r = AgentMention.parse("  @codex   看日志")
        #expect(r.kind == .codex)
        #expect(r.prompt == "看日志")
    }

    @Test("@codexfoo 这类粘连词不触发(整词查表失败)")
    func gluedSuffixIgnored() {
        let r = AgentMention.parse("@codexfoo 内容")
        #expect(r.kind == nil)
        #expect(r.prompt == "@codexfoo 内容")
    }

    @Test("mention 后换行正文 → 命中,正文保留")
    func newlineBody() {
        let r = AgentMention.parse("@claude\n第一行\n第二行")
        #expect(r.kind == .claudeCode)
        #expect(r.prompt == "第一行\n第二行")
    }
}
