import Testing
@testable import Orchestrator

@Suite("ProactiveReplyTrimmer")
struct ProactiveReplyTrimmerTests {
    @Test("未超限 → 原样（仅 flatten 空白）")
    func underLimit() {
        #expect(ProactiveReplyTrimmer.trim("看你在写代码", toCharLimit: 60) == "看你在写代码")
    }

    @Test("多行折成单行")
    func flattenNewlines() {
        #expect(ProactiveReplyTrimmer.trim("第一行\n  第二行  \n\n第三行", toCharLimit: 60) == "第一行 第二行 第三行")
    }

    @Test("超限且后半有句末标点 → 在标点处优雅截断（保留标点）")
    func cutAtSentenceBoundary() {
        // limit 12：前 12 字 "写了挺久了。还需要我" → 最后句末标点「。」在 index 5（>=6? minKeep=6）
        let r = ProactiveReplyTrimmer.trim("写了挺久了。还需要我帮你查文档吗？要的话说一声", toCharLimit: 12)
        #expect(r == "写了挺久了。")
    }

    @Test("超限且无合适句界 → 硬截 + 省略号")
    func hardCutWithEllipsis() {
        // 全程无句末标点，limit 6 → 截 5 字 + …
        let r = ProactiveReplyTrimmer.trim("看你在写一个很长的没有标点的句子继续继续", toCharLimit: 6)
        #expect(r == "看你在写一…")
        #expect(r.count == 6)
    }

    @Test("limit<=0 → 不限制")
    func noLimit() {
        let long = String(repeating: "字", count: 200)
        #expect(ProactiveReplyTrimmer.trim(long, toCharLimit: 0) == long)
    }

    @Test("句界过靠前（不足 minKeep）→ 不在那截，走硬截")
    func enderTooEarlyFallsBackToHardCut() {
        // "好。" 的句末标点在 index 1，limit 10 → minKeep=5，1+1<5 → 不采纳 → 硬截 9 字 + …
        let r = ProactiveReplyTrimmer.trim("好。我看你在写代码要不要帮忙看看", toCharLimit: 10)
        #expect(r.hasSuffix("…"))
        #expect(r.count == 10)
    }

    // MARK: - meta-echo 兜底

    @Test("纯英文要求复述 → 判为 meta-echo")
    func detectsEnglishMetaEcho() {
        // Image #9 的真实 case：模型把要求当正文用英文吐出来。
        let echo = "We need to produce a single Chinese sentence, less than 80 characters, no bullets."
        #expect(ProactiveReplyTrimmer.isLikelyMetaEcho(echo))
    }

    @Test("中英混杂但含要求标志词 → 判为 meta-echo")
    func detectsMixedMetaEcho() {
        #expect(ProactiveReplyTrimmer.isLikelyMetaEcho("好的，输出一句话 under 80 characters"))
    }

    @Test("空串 → 判为 meta-echo（无可用内容）")
    func emptyIsMetaEcho() {
        #expect(ProactiveReplyTrimmer.isLikelyMetaEcho("   \n  "))
    }

    @Test("正常中文 pet 句 → 不判 meta-echo")
    func normalChineseNotMetaEcho() {
        #expect(!ProactiveReplyTrimmer.isLikelyMetaEcho("又在写代码啦，记得喝口水~"))
    }

    @Test("含英文 app 名的正常中文句 → 不误伤")
    func chineseWithAppNameNotMetaEcho() {
        // 有中文主体 + 拉丁 app 名，既非零中文、也不含要求标志词 → 应放行。
        #expect(!ProactiveReplyTrimmer.isLikelyMetaEcho("看你在用 Chrome 摸鱼呢"))
        #expect(!ProactiveReplyTrimmer.isLikelyMetaEcho("Xcode 又报错啦？别急"))
    }

    @Test("中文复述 prompt 指令 → 判为 meta-echo")
    func detectsChineseInstructionEcho() {
        // 模型用中文把 prompt 要求吐出来（英文 marker 抓不到、又有中文故 cjk!=0 也漏）。
        #expect(ProactiveReplyTrimmer.isLikelyMetaEcho("这个提示要求我用一句不超过60个字的中文口语随口说"))
        #expect(ProactiveReplyTrimmer.isLikelyMetaEcho("好的，我直接说那句话"))
        #expect(ProactiveReplyTrimmer.isLikelyMetaEcho("作为一只桌面小宠物，我想对你说"))
    }

    @Test("含相近孤词的正常中文句 → 不误杀（保守词表守卫）")
    func chineseLookalikesNotMetaEcho() {
        // 这些含「提示/最多/作为」等孤词但非复述指令 —— 词表刻意不收孤词,应全部放行。
        #expect(!ProactiveReplyTrimmer.isLikelyMetaEcho("这个报错提示挺烦的吧，喝口水再战"))
        #expect(!ProactiveReplyTrimmer.isLikelyMetaEcho("最多再忍十分钟就能下班啦"))
        #expect(!ProactiveReplyTrimmer.isLikelyMetaEcho("就当作为自己放个小假吧"))
    }
}
