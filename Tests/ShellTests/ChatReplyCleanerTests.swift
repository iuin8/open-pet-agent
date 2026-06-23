import Testing
@testable import Shell

@Suite("ChatReplyCleaner")
struct ChatReplyCleanerTests {
    @Test("裸英文推理前言 + 中文答案 → 只留中文答案（Image #1 真实 case）")
    func stripsBareReasoningPreamble() {
        let raw = """
        User asks: "\\u4f60\\u73b0\\u5728\\u662f\\u4ec0\\u4e48\\u6a21\\u578b" (What model are you?). \
        The assistant should answer. According to system, respond in Chinese. Provide concise answer.\
        我基于 OpenAI 的 GPT-4 架构，是一个大规模的语言模型。
        """
        #expect(ChatReplyCleaner.clean(raw) == "我基于 OpenAI 的 GPT-4 架构，是一个大规模的语言模型。")
    }

    @Test("<think> 闭合块被整段剥掉")
    func stripsClosedThinkBlock() {
        let raw = "<think>let me reason about this</think>你好呀，今天想聊点啥？"
        #expect(ChatReplyCleaner.clean(raw) == "你好呀，今天想聊点啥？")
    }

    @Test("未闭合 <think>（流式中段）→ 从开标签删到末尾")
    func stripsUnclosedThinkTail() {
        let raw = "前面的答案<think>the assistant should keep thinking"
        #expect(ChatReplyCleaner.clean(raw) == "前面的答案")
    }

    @Test("纯推理阶段（有标志词、还没中文）→ 返回空（UI 显示打点）")
    func pureReasoningReturnsEmpty() {
        let raw = "User asks something. The assistant should think about it first"
        #expect(ChatReplyCleaner.clean(raw) == "")
    }

    @Test("正常中文回答（无推理标志）→ 原样保留")
    func normalChineseUntouched() {
        let raw = "又在写代码啦，记得喝口水~"
        #expect(ChatReplyCleaner.clean(raw) == "又在写代码啦，记得喝口水~")
    }

    @Test("正常含英文 app 名的中文答案（无推理标志）→ 不误伤")
    func chineseWithEnglishUntouched() {
        let raw = "看你在用 Xcode 写 Swift，需要我帮你看看吗？"
        #expect(ChatReplyCleaner.clean(raw) == "看你在用 Xcode 写 Swift，需要我帮你看看吗？")
    }
}
