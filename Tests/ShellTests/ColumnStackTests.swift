import Testing
import Foundation
import AgentSensing
@testable import Shell

@Suite("ColumnStack — 列栈 drill-in 纯逻辑")
struct ColumnStackTests {
    func detail(_ id: Int) -> ColumnKind {
        .detail(item: ConversationItem(id: id, kind: .assistant(text: "t\(id)"), timestamp: Date(timeIntervalSince1970: 0)))
    }

    @Test("openRoot:清栈置单列 + 记 sourceKey")
    func openRootSingleColumn() {
        var s = ColumnStack()
        #expect(s.openRoot(detail(1), sourceKey: "row:1") == true)
        #expect(s.columns.count == 1)
        #expect(s.rootSourceKey == "row:1")
    }

    @Test("openRoot:同 sourceKey 再开 → toggle 关(空栈)")
    func openRootToggleCloses() {
        var s = ColumnStack()
        _ = s.openRoot(detail(1), sourceKey: "row:1")
        #expect(s.openRoot(detail(1), sourceKey: "row:1") == false)
        #expect(s.isEmpty)
        #expect(s.rootSourceKey == nil)
    }

    @Test("openRoot:异 sourceKey → 重置为新单列(不 toggle)")
    func openRootDifferentSourceResets() {
        var s = ColumnStack()
        _ = s.openRoot(detail(1), sourceKey: "row:1")
        #expect(s.openRoot(detail(2), sourceKey: "row:2") == true)
        #expect(s.columns.count == 1)
        #expect(s.rootSourceKey == "row:2")
    }

    @MainActor
    @Test("openRoot:项目能力管理可作为 root 列")
    func openRootProjectCapabilityManager() {
        let model = ProjectCapabilityColumnState(card: ProjectCapabilityCardState(selectedTab: .skills, items: []))
        var s = ColumnStack()

        #expect(s.openRoot(.projectCapabilityManager(model), sourceKey: "project-capability") == true)

        #expect(s.columns.count == 1)
        if case .projectCapabilityManager(let stored) = s.columns[0].kind {
            #expect(stored === model)
        } else {
            Issue.record("应是项目能力管理列")
        }
    }

    @Test("drillIn:点第 0 列某行 → 截断后 + 设 selectedRowId + 追加新列")
    func drillInAppends() {
        var s = ColumnStack()
        _ = s.openRoot(detail(1), sourceKey: "row:1")
        s.drillIn(fromColumnIndex: 0, rowId: 7, into: detail(2))
        #expect(s.columns.count == 2)
        #expect(s.columns[0].selectedRowId == 7)
        if case .detail(let it) = s.columns[1].kind { #expect(it.id == 2) } else { Issue.record("应是 detail 列") }
    }

    @Test("drillIn:点第 i 列另一行 → 截断 i 后旧列 + 换新追加(换 drill-in 路径)")
    func drillInDifferentRowTruncates() {
        var s = ColumnStack()
        _ = s.openRoot(detail(1), sourceKey: "row:1")
        s.drillIn(fromColumnIndex: 0, rowId: 7, into: detail(2))    // [col0(sel7), col1]
        s.drillIn(fromColumnIndex: 0, rowId: 9, into: detail(3))    // 换行 → 截到 col0 + 追加新
        #expect(s.columns.count == 2)
        #expect(s.columns[0].selectedRowId == 9)
        if case .detail(let it) = s.columns[1].kind { #expect(it.id == 3) } else { Issue.record("应是新 detail") }
    }

    @Test("drillIn:点第 i 列同一行(其下已有列)→ toggle 收回(截到 i,不追加,清 selected)")
    func drillInSameRowToggles() {
        var s = ColumnStack()
        _ = s.openRoot(detail(1), sourceKey: "row:1")
        s.drillIn(fromColumnIndex: 0, rowId: 7, into: detail(2))    // [col0(sel7), col1]
        s.drillIn(fromColumnIndex: 0, rowId: 7, into: detail(2))    // 同行再点 → 收回
        #expect(s.columns.count == 1)
        #expect(s.columns[0].selectedRowId == nil)
    }

    @Test("drillIn:越界索引 → 不动")
    func drillInOutOfBounds() {
        var s = ColumnStack()
        _ = s.openRoot(detail(1), sourceKey: "row:1")
        s.drillIn(fromColumnIndex: 5, rowId: 1, into: detail(2))
        #expect(s.columns.count == 1)
    }

    @Test("drillIn:三级 — col0→col1→col2,再点 col0 行 → 截到 col0 + 追加(col1/col2 全清)")
    func drillInDeepTruncate() {
        var s = ColumnStack()
        _ = s.openRoot(detail(1), sourceKey: "row:1")
        s.drillIn(fromColumnIndex: 0, rowId: 7, into: detail(2))
        s.drillIn(fromColumnIndex: 1, rowId: 8, into: detail(3))    // [col0(7), col1(8), col2]
        #expect(s.columns.count == 3)
        s.drillIn(fromColumnIndex: 0, rowId: 9, into: detail(4))    // 截到 col0 + 追加
        #expect(s.columns.count == 2)
        #expect(s.columns[0].selectedRowId == 9)
    }

    @Test("close:清空")
    func closeClears() {
        var s = ColumnStack()
        _ = s.openRoot(detail(1), sourceKey: "row:1")
        s.close()
        #expect(s.isEmpty)
        #expect(s.rootSourceKey == nil)
    }

    @Test("id 稳定递增(SwiftUI ForEach 用)")
    func idsAreStableIncreasing() {
        var s = ColumnStack()
        _ = s.openRoot(detail(1), sourceKey: "a")
        s.drillIn(fromColumnIndex: 0, rowId: 1, into: detail(2))
        #expect(s.columns[0].id != s.columns[1].id)
    }
}
