import Foundation
import Testing
import Orchestrator
@testable import App

// P4 交接摘要(AppBootstrap.handoffTranscript)单测:role 行拼装 / 跳 system /
// 截断保最新 / 时间序 / 空 → nil。

@Suite("AppBootstrap handoffTranscript")
struct AppBootstrapHandoffTests {

    private func msg(_ role: LLMRole, _ content: String) -> ConversationMessage {
        ConversationMessage(role: role, content: content)
    }

    @Test("user/assistant 拼 role 行,时间序(旧→新),跳 system")
    func basicTranscript() {
        let text = AppBootstrap.handoffTranscript(from: [
            msg(.user, "问1"),
            msg(.assistant, "答1"),
            msg(.system, "系统提示"),
            msg(.user, "问2"),
        ])
        #expect(text == "user: 问1\nassistant: 答1\nuser: 问2")
    }

    @Test("空/全 system → nil(不交接)")
    func emptyTranscript() {
        #expect(AppBootstrap.handoffTranscript(from: []) == nil)
        #expect(AppBootstrap.handoffTranscript(from: [msg(.system, "s")]) == nil)
    }

    @Test("超 maxChars:从最新往回装,弃最旧保最新")
    func truncationKeepsNewest() {
        let longOld = String(repeating: "旧", count: 1500)
        let longNew = String(repeating: "新", count: 1200)
        let text = AppBootstrap.handoffTranscript(from: [
            msg(.user, longOld),
            msg(.assistant, longNew),
        ], maxChars: 2000)
        // 2000 装不下两条(1500+1200+role 前缀),弃「旧」保「新」
        #expect(text?.contains("旧") == false)
        #expect(text?.contains("新") == true)
        #expect(text?.hasPrefix("assistant: ") == true)
    }

    @Test("单条超 maxChars 也保留(至少有一条可交,防全丢)")
    func singleOversizedKept() {
        let huge = String(repeating: "长", count: 5000)
        let text = AppBootstrap.handoffTranscript(from: [msg(.user, huge)], maxChars: 2000)
        #expect(text == "user: \(huge)")
    }
}
