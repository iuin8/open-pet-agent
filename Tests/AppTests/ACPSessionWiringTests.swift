import Foundation
import Testing
import AgentMode
import Shell
@testable import App

// ACP-4 会话管理 wiring 纯映射单测(P2):回放 turns → ChatCardRow、session/list 项 →
// ACPSessionItem(标题兜底/isCurrent/时间容错)、ISO 8601 解析。engine 交互部分
// (restore/select/new)走 ACPAgentEngineTests + 真机冒烟,不在此单测。

@Suite("ACPSessionWiring")
struct ACPSessionWiringTests {

    @Test("rows: 回放 turns → ChatCardRow(role/文本逐一映射,顺序保持)")
    func rowsMapping() {
        let rows = MinimalAppDelegate.rows(from: [
            ACPReplayedTurn(role: .user, text: "问"),
            ACPReplayedTurn(role: .assistant, text: "答"),
            ACPReplayedTurn(role: .user, text: "再问"),
        ])
        #expect(rows.map(\.role) == [.user, .assistant, .user])
        #expect(rows.map(\.text) == ["问", "答", "再问"])
    }

    @Test("sessionItem: agent 给标题用标题;缺失兜底 sessionId 前缀 12;isCurrent 按 id 匹配")
    func sessionItemMapping() {
        let current = MinimalAppDelegate.sessionItem(
            from: ACPSessionInfo(sessionId: "ses_abcdefghijklmn", cwd: "/tmp", title: nil, updatedAt: nil),
            currentId: "ses_abcdefghijklmn"
        )
        #expect(current.title == "ses_abcdefgh")
        #expect(current.isCurrent)
        #expect(current.updatedAt == nil)

        let titled = MinimalAppDelegate.sessionItem(
            from: ACPSessionInfo(sessionId: "s2", cwd: "/tmp", title: "修 bug", updatedAt: "bad-date"),
            currentId: "other"
        )
        #expect(titled.title == "修 bug")
        #expect(!titled.isCurrent)
        #expect(titled.updatedAt == nil)   // 坏时间容错 nil 不崩
    }

    @Test("parseACPDate: 带/不带毫秒都解;坏值/空 nil")
    func parseDate() {
        #expect(MinimalAppDelegate.parseACPDate("2026-07-20T10:00:00Z") != nil)
        #expect(MinimalAppDelegate.parseACPDate("2026-07-20T10:00:00.123Z") != nil)
        #expect(MinimalAppDelegate.parseACPDate("nope") == nil)
        #expect(MinimalAppDelegate.parseACPDate(nil) == nil)
    }
}
