import Testing
@testable import AgentMode

// P5 AgentMention 解析单测;P6 升三态:行首 @opencode/@claude/@codex(大小写不敏感)→
// .engine(kind);@pet/@聊天/@宠物 → .soul;无 mention / 行中 @ / 只有 mention 没内容 /
// 未知名 → target nil 原文直发。

@Suite("AgentMention 解析")
struct AgentMentionTests {

    @Test("行首 @codex + 内容 → .engine(.codex),prompt 剥离 mention")
    func codexMention() {
        let r = AgentMention.parse("@codex 帮我看下这个 crash")
        #expect(r.target == .engine(.codex))
        #expect(r.prompt == "帮我看下这个 crash")
    }

    @Test("@claude → .engine(.claudeCode);@opencode → .engine(.openCode)")
    func knownNames() {
        #expect(AgentMention.parse("@claude 写个测试").target == .engine(.claudeCode))
        #expect(AgentMention.parse("@opencode 跑一下构建").target == .engine(.openCode))
    }

    @Test("大小写不敏感:@CODEX / @Claude 都命中")
    func caseInsensitive() {
        #expect(AgentMention.parse("@CODEX hi").target == .engine(.codex))
        #expect(AgentMention.parse("@Claude hi").target == .engine(.claudeCode))
    }

    @Test("P6:@pet / @聊天 / @宠物 → .soul(强制灵魂层)")
    func soulTriggers() {
        #expect(AgentMention.parse("@pet 聊两句").target == .soul)
        #expect(AgentMention.parse("@聊天 聊两句").target == .soul)
        #expect(AgentMention.parse("@宠物 聊两句").target == .soul)
        #expect(AgentMention.parse("@PET 聊两句").target == .soul)
        let r = AgentMention.parse("@pet 今天怎么样")
        #expect(r.prompt == "今天怎么样")
    }

    @Test("P6:@pet 单独成句(没内容)→ 不触发,原文直发")
    func soulBareIgnored() {
        let r = AgentMention.parse("@pet")
        #expect(r.target == nil)
        #expect(r.prompt == "@pet")
    }

    @Test("无 mention → target nil,prompt = 原文")
    func noMention() {
        let r = AgentMention.parse("普通一句话")
        #expect(r.target == nil)
        #expect(r.prompt == "普通一句话")
    }

    @Test("行中 @(找人/邮箱)不触发")
    func midSentenceAtIgnored() {
        let r = AgentMention.parse("帮我找 @codex 的讨论记录")
        #expect(r.target == nil)
        #expect(r.prompt == "帮我找 @codex 的讨论记录")
    }

    @Test("只有 mention 没内容 → 不触发(原文直发,防误吞消息)")
    func mentionOnlyIgnored() {
        let r = AgentMention.parse("@codex")
        #expect(r.target == nil)
        #expect(r.prompt == "@codex")
    }

    @Test("未知 mention 名 → 不触发")
    func unknownNameIgnored() {
        let r = AgentMention.parse("@gemini 你好")
        #expect(r.target == nil)
        #expect(r.prompt == "@gemini 你好")
    }

    @Test("前导空白后行首 mention 仍命中;prompt 前导空白剥净")
    func leadingWhitespace() {
        let r = AgentMention.parse("  @codex   看日志")
        #expect(r.target == .engine(.codex))
        #expect(r.prompt == "看日志")
    }

    @Test("@codexfoo 这类粘连词不触发(整词查表失败)")
    func gluedSuffixIgnored() {
        let r = AgentMention.parse("@codexfoo 内容")
        #expect(r.target == nil)
        #expect(r.prompt == "@codexfoo 内容")
    }

    @Test("mention 后换行正文 → 命中,正文保留")
    func newlineBody() {
        let r = AgentMention.parse("@claude\n第一行\n第二行")
        #expect(r.target == .engine(.claudeCode))
        #expect(r.prompt == "第一行\n第二行")
    }
}

// MARK: - candidates 表一致性

@Suite("AgentMention candidates")
struct AgentMentionCandidatesTests {
    @Test("engineCandidates 与解析同一份表:每个 trigger 都能解析出对应 kind(防 UI/解析漂移)")
    func candidatesConsistentWithParse() {
        for (trigger, kind) in AgentMention.engineCandidates {
            let r = AgentMention.parse("@\(trigger) 内容")
            #expect(r.target == .engine(kind))
            #expect(r.prompt == "内容")
        }
        #expect(AgentMention.engineCandidates.map(\.trigger) == ["opencode", "claude", "codex"])
    }

    @Test("soulTriggers 全部可解析为 .soul;规范词在集合内")
    func soulTriggersParse() {
        for trigger in AgentMention.soulTriggers {
            #expect(AgentMention.parse("@\(trigger) 内容").target == .soul)
        }
        #expect(AgentMention.soulTriggers.contains(AgentMention.soulCanonicalTrigger))
    }
}
