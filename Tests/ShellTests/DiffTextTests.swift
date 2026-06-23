import Testing
import SwiftUI
@testable import Shell

@Suite("DiffText — 工具详情 diff 着色判定")
struct DiffTextTests {

    @Test("整块都是 - / + 行 → isDiff true")
    func allDiffLines() {
        #expect(DiffText.isDiff("- let x = 1\n+ let x = 2"))
        #expect(DiffText.isDiff("- a\n- b\n+ c"))
    }

    @Test("含非 diff 行 → isDiff false(不误染命令/JSON)")
    func notDiff() {
        #expect(!DiffText.isDiff("git commit -m x"))            // 命令
        #expect(!DiffText.isDiff("{\n  \"a\": 1\n}"))            // JSON
        #expect(!DiffText.isDiff("- a\nplain line\n+ b"))        // 混入普通行
    }

    @Test("空行被忽略,空串非 diff")
    func emptyHandling() {
        #expect(DiffText.isDiff("- a\n\n+ b"))                   // 中间空行不破坏
        #expect(!DiffText.isDiff(""))                            // 空串无 diff 行
        #expect(!DiffText.isDiff("\n\n"))                        // 全空
    }

    @Test("attributed 给 - 行红、+ 行绿,非 diff 整块 base 色")
    func coloring() {
        let diff = DiffText.attributed("- old\n+ new", base: .black)
        // 找到 "old" 段是 removed 红、"new" 段是 added 绿。
        let runs = diff.runs.map { ($0.foregroundColor, String(diff[$0.range].characters)) }
        #expect(runs.contains { $0.0 == DiffText.removed && $0.1.contains("old") })
        #expect(runs.contains { $0.0 == DiffText.added && $0.1.contains("new") })

        let plain = DiffText.attributed("echo hi", base: .black)
        #expect(plain.runs.allSatisfy { $0.foregroundColor == .black })
    }
}
