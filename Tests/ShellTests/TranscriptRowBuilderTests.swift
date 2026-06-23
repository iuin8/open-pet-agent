import Testing
import Foundation
import AgentSensing
@testable import Shell

@Suite("TranscriptRowBuilder — 行序列组装(NSTableView 容器的纯逻辑)")
struct TranscriptRowBuilderTests {

    func item(_ id: Int, _ kind: ConversationItem.Kind = .user(text: "x")) -> ConversationItem {
        ConversationItem(id: id, kind: kind, timestamp: Date(timeIntervalSince1970: TimeInterval(id)))
    }

    @Test("基本组装:[加载更早] + items + 顺序保留")
    func basicComposition() {
        let rows = TranscriptRowBuilder.rows(
            items: [item(0), item(1)], highlightedItemId: nil,
            canLoadEarlier: true, isLoadingEarlier: false, showCodexHint: false
        )
        #expect(rows.count == 3)                 // loadEarlier + 2 items
        #expect(rows[0].id == -1)                // 顶部加载更早哨兵
        #expect(rows[1].id == 0)
        #expect(rows[2].id == 1)
    }

    @Test("canLoadEarlier=false → 无加载更早行")
    func noLoadEarlierRow() {
        let rows = TranscriptRowBuilder.rows(
            items: [item(0)], highlightedItemId: nil,
            canLoadEarlier: false, isLoadingEarlier: false, showCodexHint: false
        )
        #expect(rows.count == 1)
        #expect(rows[0].id == 0)
    }

    @Test("高亮标志按 id 落到对应行")
    func highlightedFlag() {
        let rows = TranscriptRowBuilder.rows(
            items: [item(0), item(1), item(2)], highlightedItemId: 2,
            canLoadEarlier: false, isLoadingEarlier: false, showCodexHint: false
        )
        #expect(rows[0].highlighted == false)
        #expect(rows[1].highlighted == false)
        #expect(rows[2].highlighted == true)
    }

    @Test("loading 态传到加载更早行")
    func loadingFlagOnLoadEarlierRow() {
        let rows = TranscriptRowBuilder.rows(
            items: [item(0)], highlightedItemId: nil,
            canLoadEarlier: true, isLoadingEarlier: true, showCodexHint: false
        )
        #expect(rows[0].loading == true)
    }

    @Test("codexHint 追加在末尾(待答之后)")
    func codexHintAppended() {
        let rows = TranscriptRowBuilder.rows(
            items: [item(0)], highlightedItemId: nil,
            canLoadEarlier: false, isLoadingEarlier: false, showCodexHint: true
        )
        #expect(rows.count == 2)
        #expect(rows.last?.id == -3)             // codexHint 哨兵
    }

    @Test("heightSignature:item 内容变 → 签名变(触发重测高度)")
    func heightSignatureChangesOnContent() {
        let short = TranscriptRow(kind: .item(item(5, .user(text: "hi"))), highlightRegion: nil, loading: false, subagent: nil)
        let long = TranscriptRow(kind: .item(item(5, .user(text: "much longer text"))), highlightRegion: nil, loading: false, subagent: nil)
        #expect(short.heightSignature != long.heightSignature)
    }

    @Test("heightSignature:仅高亮变 → 签名不变(halo 是 overlay,高度一致)")
    func heightSignatureStableOnHighlight() {
        let plain = TranscriptRow(kind: .item(item(5)), highlightRegion: nil, loading: false, subagent: nil)
        let lit = TranscriptRow(kind: .item(item(5)), highlightRegion: .primary, loading: false, subagent: nil)
        #expect(plain.heightSignature == lit.heightSignature)
    }

    @Test("renderSignature:子区变(primary↔metadata↔无)→ 签名变(否则切子区 NSTableView 不重画该行)")
    func renderSignatureTracksRegion() {
        let none = TranscriptRow(kind: .item(item(5)), highlightRegion: nil, loading: false, subagent: nil)
        let primary = TranscriptRow(kind: .item(item(5)), highlightRegion: .primary, loading: false, subagent: nil)
        let metadata = TranscriptRow(kind: .item(item(5)), highlightRegion: .metadata, loading: false, subagent: nil)
        #expect(none.renderSignature != primary.renderSignature)
        #expect(primary.renderSignature != metadata.renderSignature)
        #expect(none.renderSignature != metadata.renderSignature)
        // 高度签名仍一致(halo 是 overlay,不影响行高)
        #expect(none.heightSignature == metadata.heightSignature)
    }

    @Test("高亮子区按 highlightedRegion 落到命中行")
    func highlightRegionRouted() {
        let rows = TranscriptRowBuilder.rows(
            items: [item(0), item(1)], highlightedItemId: 1, highlightedRegion: .metadata,
            canLoadEarlier: false, isLoadingEarlier: false, showCodexHint: false
        )
        #expect(rows[0].highlightRegion == nil)
        #expect(rows[1].highlightRegion == .metadata)
    }

    @Test("D2:子 agent 命中 → 行挂 subagent + heightSignature 变(行变高)")
    func subagentAttachedAndHeight() {
        let ref = SubagentRef(toolUseId: "toolu_1", agentType: "code-reviewer", description: "审", transcriptURL: URL(fileURLWithPath: "/x/agent-1.jsonl"))
        let rows = TranscriptRowBuilder.rows(
            items: [item(0), item(1)], highlightedItemId: nil,
            canLoadEarlier: false, isLoadingEarlier: false, showCodexHint: false,
            subagentByItemId: [1: ref]
        )
        #expect(rows[0].subagent == nil)
        #expect(rows[1].subagent?.agentType == "code-reviewer")
        let plain = TranscriptRow(kind: .item(item(1)), highlightRegion: nil, loading: false, subagent: nil)
        #expect(rows[1].heightSignature != plain.heightSignature)   // 挂入口 → 行高签名变
    }
}
